import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { createEdgeHandler, jsonResponse } from "../_shared/edge-middleware.ts";
import type { EdgeContext } from "../_shared/edge-middleware.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

// ── Types ──

interface Evidence {
  source_type: "course" | "activity" | "award" | "survey" | "test_score";
  source_id: string;
  excerpt: string;
  relevance: string;
}

interface Throughline {
  key: string;
  title: string;
  narrative: string;
  evidence: Evidence[];
  school_type_notes: string;
}

interface Contradiction {
  key: string;
  title: string;
  description: string;
  between: string[];
  strategic_note: string;
  evidence: Evidence[];
}

interface Gap {
  key: string;
  title: string;
  description: string;
  expected_from: string;
  suggestions: string[];
  evidence: Evidence[];
}

interface IdentityFrame {
  key: string;
  title: string;
  pitch: string;
  best_for: string[];
  throughline_keys: string[];
  risks: string;
}

interface NarrativeArc {
  stage: string;
  data_sources: string[];
  counselor_brief: string;
  throughlines: Throughline[];
  contradictions: Contradiction[];
  gaps: Gap[];
  identity_frames: IdentityFrame[];
}

type NarrativeStage = "academic" | "activities" | "full";

// ── Survey field keys ──

const SURVEY_FIELD_KEYS = [
  "friendWords",
  "reachFor",
  "energy",
  "proud",
  "selfTaught",
  "talkAbout",
  "unexpected",
  "googled",
  "ruleBreak",
  "selectedMoments",
  "momentResponses",
  "songs",
  "photo",
  "insideJoke",
  "room",
  "assumption",
  "figuringOut",
  "oneHour",
  "freewrite",
];

// ── System prompt ──

const BASE_SYSTEM_PROMPT = `You are an expert college admissions strategist analyzing a student's profile to identify narrative throughlines, contradictions, gaps, and identity frames.

You must output ONLY valid JSON matching this exact structure:
{
  "stage": "<stage>",
  "data_sources": [...],
  "counselor_brief": "2-3 paragraphs summarizing what's distinctive about this student",
  "throughlines": [{
    "key": "lowercase_underscored_slug",
    "title": "Short evocative title showing growth/evolution",
    "narrative": "2-3 sentences describing the arc",
    "evidence": [{ "source_type": "course|activity|award|survey|test_score", "source_id": "exact id from data", "excerpt": "specific detail", "relevance": "why this supports the throughline" }],
    "school_type_notes": "Strategic framing per school type"
  }],
  "contradictions": [{
    "key": "slug", "title": "...", "description": "...",
    "between": ["throughline_key_1", "throughline_key_2"],
    "strategic_note": "How to address",
    "evidence": [...]
  }],
  "gaps": [{
    "key": "slug", "title": "...", "description": "...",
    "expected_from": "which throughline",
    "suggestions": ["action 1", "action 2"],
    "evidence": [...]
  }],
  "identity_frames": [{
    "key": "slug", "title": "e.g. The Systems Thinker",
    "pitch": "2-3 sentence positioning statement",
    "best_for": ["Research Universities", "LACs"],
    "throughline_keys": ["supporting throughline keys"],
    "risks": "what could undermine this framing"
  }]
}

RULES:
- Never assign numeric scores or rankings
- Frame everything as qualitative narrative
- Throughlines should show GROWTH or EVOLUTION, not just "student does X"
- Contradictions are not necessarily bad — they can show range
- Gaps should be actionable, not judgmental
- Identity frames must be school-type-aware
- Reference ONLY the exact IDs provided in the data
- Generate stable, descriptive keys (lowercase, underscored)
- Aim for 3-5 throughlines, 1-3 contradictions, 1-3 gaps, 2-3 identity frames
- Each throughline should have evidence from MULTIPLE source types (courses + activities, activities + awards, etc.) — diverse evidence makes throughlines more compelling
- A throughline supported only by courses or only by activities is weaker than one crossing domains`;

const STAGE_INSTRUCTIONS: Record<NarrativeStage, string> = {
  academic:
    "STAGE NOTE: Only academic data is available. Throughlines should be limited to academic themes. Identity frames should be flagged as preliminary.",
  activities:
    "STAGE NOTE: Academic and activity data is available. Perform full cross-domain analysis. Identity frames are draft.",
  full: "STAGE NOTE: Full data including student survey responses is available. Layer in personal voice from survey. Use student's own language in identity frames where possible.",
};

// ── Helpers ──

function determineStage(
  courses: unknown[],
  activities: unknown[],
  surveyCompletedAt: string | null,
): NarrativeStage | null {
  if (courses.length === 0 && activities.length === 0) return null;
  if (courses.length > 0 && activities.length > 0 && surveyCompletedAt)
    return "full";
  if (courses.length > 0 && activities.length > 0) return "activities";
  return "academic";
}

function buildDataSources(
  courses: unknown[],
  activities: unknown[],
  awards: unknown[],
  surveyCompletedAt: string | null,
  testScores: Record<string, unknown>,
): string[] {
  const sources: string[] = [];
  if (courses.length > 0) sources.push("transcript");
  if (activities.length > 0) sources.push("resume");
  if (awards.length > 0) sources.push("awards");
  if (surveyCompletedAt) sources.push("survey");
  if (testScores && Object.keys(testScores).length > 0)
    sources.push("test_scores");
  return sources;
}

function validateEvidence(
  evidence: Evidence[],
  validIds: Set<string>,
): Evidence[] {
  return evidence.filter((e) => validIds.has(e.source_id));
}

// ── Handler ──

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx: EdgeContext) => {
      const { student_id } = ctx.body as { student_id: string };
      if (!student_id) {
        return jsonResponse({ error: "student_id is required" }, 400);
      }

      // ── 1. Atomic concurrency guard ──

      // Check if a row already exists
      const { data: existingArc } = await ctx.supabase
        .from("narrative_arcs")
        .select("id, status")
        .eq("student_id", student_id)
        .maybeSingle();

      let arcId: string;

      if (existingArc) {
        if (existingArc.status === "generating") {
          return jsonResponse(
            { error: "Narrative arc generation already in progress" },
            409,
          );
        }

        // Atomically claim the lock: only succeeds if status is idle or failed
        const { data: updated, error: updateError } = await ctx.supabase
          .from("narrative_arcs")
          .update({ status: "generating" })
          .eq("student_id", student_id)
          .in("status", ["idle", "failed"])
          .select("id")
          .maybeSingle();

        if (updateError || !updated) {
          return jsonResponse(
            { error: "Narrative arc generation already in progress" },
            409,
          );
        }

        arcId = updated.id;
      } else {
        // Insert new row with generating status
        const { data: inserted, error: insertError } = await ctx.supabase
          .from("narrative_arcs")
          .insert({
            student_id,
            arc: {},
            stage: "academic",
            status: "generating",
          })
          .select("id")
          .single();

        if (insertError || !inserted) {
          return jsonResponse(
            { error: "Failed to initialize narrative arc" },
            500,
          );
        }

        arcId = inserted.id;
      }

      // From here on, any error must reset status to 'failed'
      try {
        // ── 2. Fetch all student data in parallel ──

        const [
          studentRes,
          coursesRes,
          activitiesRes,
          awardsRes,
          annotationsRes,
        ] = await Promise.all([
          ctx.supabase
            .from("students")
            .select("*")
            .eq("id", student_id)
            .single(),
          ctx.supabase
            .from("courses")
            .select("*")
            .eq("student_id", student_id)
            .order("year"),
          ctx.supabase
            .from("activities")
            .select("*")
            .eq("student_id", student_id)
            .order("name"),
          ctx.supabase
            .from("awards")
            .select("*")
            .eq("student_id", student_id)
            .order("sort_order"),
          ctx.supabase
            .from("narrative_annotations")
            .select("*")
            .eq("student_id", student_id)
            .order("created_at"),
        ]);

        if (studentRes.error || !studentRes.data) {
          await resetStatus(ctx, arcId);
          return jsonResponse({ error: "Student not found" }, 404);
        }

        const student = studentRes.data;
        const courses = coursesRes.data || [];
        const activities = activitiesRes.data || [];
        const awards = awardsRes.data || [];
        const annotations = annotationsRes.data || [];

        // ── 3. Determine stage ──

        const stage = determineStage(
          courses,
          activities,
          student.survey_completed_at,
        );

        if (!stage) {
          await resetStatus(ctx, arcId);
          return jsonResponse(
            {
              error:
                "Insufficient data to generate narrative arc. At least courses are required.",
            },
            400,
          );
        }

        // ── 4. Build valid ID sets for evidence validation ──

        const validIds = new Set<string>();

        for (const c of courses) validIds.add(c.id);
        for (const a of activities) validIds.add(a.id);
        for (const aw of awards) validIds.add(aw.id);

        // Survey field keys are valid source_ids too
        const surveyResponses =
          (student.survey_responses as Record<string, unknown>) || {};
        for (const key of SURVEY_FIELD_KEYS) {
          if (surveyResponses[key] !== undefined && surveyResponses[key] !== null) {
            validIds.add(key);
          }
        }

        // Test score keys
        const testScores =
          (student.test_scores as Record<string, unknown>) || {};
        for (const key of Object.keys(testScores)) {
          validIds.add(`test_${key}`);
        }

        // ── 5. Build context string with explicit UUIDs ──

        const dataSources = buildDataSources(
          courses,
          activities,
          awards,
          student.survey_completed_at,
          testScores,
        );

        let contextStr = `Student: ${student.full_name}
High School: ${student.high_school || "Unknown"}
Graduation Year: ${student.grad_year || "Unknown"}
GPA (Unweighted): ${student.gpa_unweighted ?? "N/A"}
GPA (Weighted): ${student.gpa_weighted ?? "N/A"}`;

        // Test scores
        if (Object.keys(testScores).length > 0) {
          contextStr += `\n\nTEST SCORES (reference by "test_<key>" in evidence):`;
          for (const [key, value] of Object.entries(testScores)) {
            contextStr += `\n- id:"test_${key}" | ${key}: ${JSON.stringify(value)}`;
          }
        }

        // Courses
        if (courses.length > 0) {
          contextStr += `\n\nCOURSES (reference by id in evidence):`;
          for (const c of courses) {
            contextStr += `\n- id:"${c.id}" | ${c.name} | ${c.level || "regular"} | Grade: ${c.grade || "N/A"} | Year: ${c.year || "N/A"} | ${c.subject_area || "other"}`;
          }
        }

        // Activities
        if (activities.length > 0) {
          contextStr += `\n\nACTIVITIES (reference by id in evidence):`;
          for (const a of activities) {
            contextStr += `\n- id:"${a.id}" | ${a.name} | ${a.role || "Member"} | Years: ${a.years_active?.join(",") || "N/A"} | ${a.hours_per_week || "N/A"} hrs/wk | ${a.depth_tier || "N/A"}`;
            if (a.impact_description) {
              contextStr += `\n  Impact: ${a.impact_description}`;
            }
          }
        }

        // Awards
        if (awards.length > 0) {
          contextStr += `\n\nAWARDS (reference by id in evidence):`;
          for (const aw of awards) {
            contextStr += `\n- id:"${aw.id}" | ${aw.title} | ${aw.level || "N/A"} | ${aw.category || "N/A"} | Grade: ${aw.grade_year || "N/A"}`;
            if (aw.description) {
              contextStr += `\n  Description: ${aw.description}`;
            }
          }
        }

        // Survey responses
        if (student.survey_completed_at && surveyResponses) {
          contextStr += `\n\nSURVEY RESPONSES (reference by key in evidence):`;
          for (const key of SURVEY_FIELD_KEYS) {
            const value = surveyResponses[key];
            if (value !== undefined && value !== null) {
              const display =
                typeof value === "string" ? value : JSON.stringify(value);
              contextStr += `\n- key:"${key}" | ${display}`;
            }
          }
        }

        // ── 6. Build annotation context (counselor feedback loop) ──

        if (annotations.length > 0) {
          contextStr += `\n\nCOUNSELOR ANNOTATIONS (incorporate this feedback — adjust your analysis accordingly):`;
          for (const ann of annotations) {
            contextStr += `\n- [${ann.target_type}:${ann.target_key}] ${ann.body}`;
          }
        }

        // ── 7. Build system prompt ──

        const systemPrompt = [
          BASE_SYSTEM_PROMPT,
          STAGE_INSTRUCTIONS[stage],
          annotations.length > 0
            ? "ANNOTATION FEEDBACK: The counselor has left annotations on a previous arc. Incorporate their feedback into this generation — adjust, add, or remove throughlines/contradictions/gaps/frames as the annotations suggest."
            : "",
        ]
          .filter(Boolean)
          .join("\n\n");

        // ── 8. Call Claude ──

        const result = await callClaude(systemPrompt, contextStr, 8192);
        const parsed = parseJsonResponse<NarrativeArc>(result.text);

        // ── 9. Validate evidence source_ids (filter hallucinations) ──

        for (const tl of parsed.throughlines || []) {
          tl.evidence = validateEvidence(tl.evidence || [], validIds);
        }
        for (const c of parsed.contradictions || []) {
          c.evidence = validateEvidence(c.evidence || [], validIds);
        }
        for (const g of parsed.gaps || []) {
          g.evidence = validateEvidence(g.evidence || [], validIds);
        }

        // Ensure stage and data_sources are correct (don't trust Claude for metadata)
        parsed.stage = stage;
        parsed.data_sources = dataSources;

        // ── 10. Track usage ──

        await trackAIUsage(ctx.supabase, {
          function_name: "generate-narrative-arc",
          result,
          student_id: student_id as string,
          caller_id: ctx.callerId,
        });

        // ── 11. Save arc with status idle ──

        const { error: saveError } = await ctx.supabase
          .from("narrative_arcs")
          .update({
            arc: parsed,
            stage,
            status: "idle",
            generated_at: new Date().toISOString(),
          })
          .eq("id", arcId);

        if (saveError) {
          console.error("Failed to save narrative arc:", saveError);
          await resetStatus(ctx, arcId);
          return jsonResponse(
            { error: "Failed to save narrative arc" },
            500,
          );
        }

        return {
          message: "Narrative arc generated successfully",
          stage,
          data_sources: dataSources,
          throughlines: parsed.throughlines.length,
          contradictions: parsed.contradictions.length,
          gaps: parsed.gaps.length,
          identity_frames: parsed.identity_frames.length,
        };
      } catch (err) {
        console.error("Narrative arc generation error:", err);
        await resetStatus(ctx, arcId);
        throw err;
      }
    },
  }),
);

/** Reset narrative_arcs status to 'failed' on error. */
async function resetStatus(ctx: EdgeContext, arcId: string): Promise<void> {
  const { error } = await ctx.supabase
    .from("narrative_arcs")
    .update({ status: "failed" })
    .eq("id", arcId);

  if (error) {
    console.error("Failed to reset narrative arc status:", error);
  }
}
