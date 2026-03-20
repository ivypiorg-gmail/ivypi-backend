import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { createEdgeHandler, jsonResponse } from "../_shared/edge-middleware.ts";
import type { EdgeContext } from "../_shared/edge-middleware.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

// ── Types ──

interface MemberAssessment {
  role: string;
  lean: "admit" | "waitlist" | "deny";
  conviction: number;
  assessment: string;
  strengths: string[];
  concerns: string[];
  question_for_committee: string;
}

interface SynthesisResult {
  final_lean: "admit" | "waitlist" | "deny";
  verdict: string;
  consensus_points: string[];
  friction_points: string[];
  tip_factors: string[];
  what_would_change: string[];
}

interface EssayAnalysisItem {
  prompt_text: string;
  risk_level: "high" | "medium" | "low";
  risk_analysis: string;
  suggested_angle: string;
  improvement_suggestions: string[];
  avoid: string[];
}

interface PanelMember {
  role: string;
  display_title: string;
  template_version: number;
  profile_version: number | null;
}

// deno-lint-ignore no-explicit-any
type AnyRecord = Record<string, any>;

// ── Constants ──

const BASE_ROLES = [
  "first_reader",
  "senior_officer",
  "regional_reader",
  "mission_advocate",
  "department_rep",
] as const;

const LEAN_RANK: Record<string, number> = {
  deny: 3,
  waitlist: 2,
  admit: 1,
};

const ROLE_DISPLAY_TITLES: Record<string, string> = {
  first_reader: "First Reader",
  senior_officer: "Senior Admissions Officer",
  regional_reader: "Regional Reader",
  mission_advocate: "Mission/Values Advocate",
  department_rep: "Department Representative",
  interdisciplinary: "Interdisciplinary Reader",
};

const MEMBER_RESPONSE_SCHEMA = `You must respond with a JSON object in this exact format:
{
  "lean": "admit" | "waitlist" | "deny",
  "conviction": <integer 1-5>,
  "assessment": "<2-3 paragraphs in your voice>",
  "strengths": ["<specific strength>", ...],
  "concerns": ["<specific concern>", ...],
  "question_for_committee": "<one question you would raise in discussion>"
}`;

// ── Helpers ──

function formatTestScores(testScores: AnyRecord): string {
  if (!testScores || Object.keys(testScores).length === 0) return "N/A";
  const parts: string[] = [];
  if (testScores.sat_total) parts.push(`SAT: ${testScores.sat_total}`);
  if (testScores.sat_math) parts.push(`SAT Math: ${testScores.sat_math}`);
  if (testScores.sat_reading)
    parts.push(`SAT Reading: ${testScores.sat_reading}`);
  if (testScores.act_composite)
    parts.push(`ACT: ${testScores.act_composite}`);
  // Include any other scores
  for (const [key, value] of Object.entries(testScores)) {
    if (!key.startsWith("sat_") && !key.startsWith("act_")) {
      parts.push(`${key}: ${value}`);
    }
  }
  return parts.join(" | ") || "N/A";
}

function buildSharedContext(
  student: AnyRecord,
  courses: AnyRecord[],
  activities: AnyRecord[],
  awards: AnyRecord[],
  arc: AnyRecord,
  collegeList: AnyRecord[],
  schoolName: string,
  essayTexts?: Record<string, string>,
): string {
  const testScores = (student.test_scores as AnyRecord) || {};
  const profileInsights = (student.profile_insights as AnyRecord) || {};

  let ctx = `STUDENT: ${student.full_name}, Class of ${student.grad_year || "N/A"}, ${student.high_school || "Unknown"}, ${student.state || "N/A"}
GPA: ${student.gpa_unweighted ?? "N/A"} UW / ${student.gpa_weighted ?? "N/A"} W | Class Rank: ${profileInsights.class_rank || "N/A"}
Test Scores: ${formatTestScores(testScores)}`;

  // Courses
  if (courses.length > 0) {
    ctx += `\n\nCOURSES:`;
    for (const c of courses) {
      ctx += `\n- ${c.name} (${c.level || "regular"}, ${c.subject_area || "other"}) — Grade: ${c.grade || "N/A"}, Year: ${c.year || "N/A"}`;
    }
  }

  // Activities
  if (activities.length > 0) {
    ctx += `\n\nACTIVITIES:`;
    for (const a of activities) {
      ctx += `\n- ${a.name} (${a.category || "other"}, ${a.depth_tier || "N/A"}): ${a.role || "Member"}, ${a.hours_per_week || "N/A"} hrs/wk, Years ${a.years_active?.join(",") || "N/A"}`;
      if (a.impact_description) {
        ctx += `\n  Impact: ${a.impact_description}`;
      }
    }
  }

  // Awards
  if (awards.length > 0) {
    ctx += `\n\nAWARDS:`;
    for (const aw of awards) {
      ctx += `\n- ${aw.title} (${aw.level || "N/A"}, ${aw.category || "N/A"}) — Grade ${aw.grade_year || "N/A"}`;
    }
  }

  // Narrative Arc
  ctx += `\n\nNARRATIVE ARC — COUNSELOR BRIEF:\n${arc.counselor_brief || "No counselor brief available."}`;

  // Throughlines
  if (arc.throughlines?.length > 0) {
    ctx += `\n\nTHROUGHLINES:`;
    for (const tl of arc.throughlines) {
      ctx += `\n- ${tl.title}: ${tl.narrative}`;
      if (tl.evidence?.length > 0) {
        for (const e of tl.evidence.slice(0, 3)) {
          ctx += `\n  Evidence: ${e.excerpt}`;
        }
      }
    }
  }

  // Contradictions
  if (arc.contradictions?.length > 0) {
    ctx += `\n\nCONTRADICTIONS:`;
    for (const c of arc.contradictions) {
      ctx += `\n- ${c.title}: ${c.description}`;
      if (c.strategic_note) ctx += `\n  Strategic note: ${c.strategic_note}`;
    }
  }

  // Gaps
  if (arc.gaps?.length > 0) {
    ctx += `\n\nGAPS:`;
    for (const g of arc.gaps) {
      ctx += `\n- ${g.title}: ${g.description}`;
      if (g.suggestions?.length > 0) {
        ctx += `\n  Suggestions: ${g.suggestions.join("; ")}`;
      }
    }
  }

  // Identity Frames
  if (arc.identity_frames?.length > 0) {
    ctx += `\n\nIDENTITY FRAMES:`;
    for (const f of arc.identity_frames) {
      ctx += `\n- ${f.title}: ${f.pitch}`;
      if (f.best_for?.length > 0) ctx += `\n  Best for: ${f.best_for.join(", ")}`;
      if (f.risks) ctx += `\n  Risks: ${f.risks}`;
    }
  }

  // Profile Insights (6 Dimensions)
  if (profileInsights.dimensions) {
    ctx += `\n\nPROFILE INSIGHTS (6 Dimensions):`;
    for (const dim of profileInsights.dimensions) {
      ctx += `\n- ${dim.name} — ${dim.tier || "N/A"} — ${dim.narrative || "N/A"}`;
    }
  }

  // College List
  if (collegeList.length > 0) {
    ctx += `\n\nCOLLEGE LIST:`;
    for (const entry of collegeList) {
      ctx += `\n- ${entry.school_name} (${entry.app_status || "considering"})`;
    }
  }

  // Affinity Report
  const affinityEntry = collegeList.find(
    (e) => e.school_name === schoolName,
  );
  const affinity = affinityEntry?.affinity_report;
  if (affinity && Object.keys(affinity).length > 0) {
    ctx += `\n\nAFFINITY REPORT for ${schoolName}:`;
    if (affinity.strengths?.length > 0)
      ctx += `\nStrengths: ${affinity.strengths.join("; ")}`;
    if (affinity.distinctive)
      ctx += `\nDistinctive: ${affinity.distinctive}`;
    if (affinity.growth_areas?.length > 0)
      ctx += `\nGrowth areas: ${affinity.growth_areas.join("; ")}`;
    if (affinity.narrative) ctx += `\nNarrative: ${affinity.narrative}`;
  } else {
    ctx += `\n\nAFFINITY REPORT for ${schoolName}:\nNo affinity report generated yet.`;
  }

  // Essays (post-essay mode)
  if (essayTexts && Object.keys(essayTexts).length > 0) {
    ctx += `\n\nESSAYS:`;
    for (const [prompt, text] of Object.entries(essayTexts)) {
      ctx += `\n\nPrompt: ${prompt}\n${text}`;
    }
  }

  return ctx;
}

function buildRoleContext(
  role: string,
  sharedContext: string,
  student: AnyRecord,
  university: AnyRecord,
  memberProfiles: AnyRecord[],
  courses: AnyRecord[],
  activities: AnyRecord[],
  targetMajor: string,
): string {
  let ctx = sharedContext;

  // Find the school-specific profile for this role to get institutional_context
  const profile = memberProfiles.find((p) => p.role === role);
  const instCtx = (profile?.institutional_context as AnyRecord) || {};

  switch (role) {
    case "first_reader":
      // Shared context is sufficient
      break;

    case "senior_officer": {
      ctx += `\n\n--- SENIOR OFFICER CONTEXT ---`;
      ctx += `\nAcceptance Rates: ${JSON.stringify(university.acceptance_rates || {})}`;
      ctx += `\nUndergraduate Size: ${university.undergraduate_size || "N/A"}`;
      ctx += `\nInstitution Type: ${university.institution_type || "N/A"}`;
      if (instCtx.cds_priorities) {
        ctx += `\nCDS Priorities: ${JSON.stringify(instCtx.cds_priorities)}`;
      }
      if (student.profile_insights?.ability_to_pay) {
        ctx += `\nStudent Ability to Pay: ${student.profile_insights.ability_to_pay}`;
      }
      break;
    }

    case "regional_reader": {
      ctx += `\n\n--- REGIONAL READER CONTEXT ---`;
      ctx += `\nStudent State: ${student.state || "N/A"}`;
      ctx += `\nHigh School: ${student.high_school || "Unknown"}`;
      if (instCtx.geographic_notes) {
        ctx += `\nGeographic Notes: ${instCtx.geographic_notes}`;
      }
      break;
    }

    case "mission_advocate": {
      ctx += `\n\n--- MISSION ADVOCATE CONTEXT ---`;
      if (university.essay_hooks?.length > 0) {
        ctx += `\nEssay Hooks: ${JSON.stringify(university.essay_hooks)}`;
      }
      if (university.clubs?.length > 0) {
        ctx += `\nClubs: ${JSON.stringify(university.clubs)}`;
      }
      if (student.survey_responses) {
        ctx += `\nStudent Survey Responses: ${JSON.stringify(student.survey_responses)}`;
      }
      if (instCtx.culture_signals) {
        ctx += `\nCulture Signals: ${JSON.stringify(instCtx.culture_signals)}`;
      }
      if (instCtx.notable_quotes) {
        ctx += `\nNotable Quotes: ${JSON.stringify(instCtx.notable_quotes)}`;
      }
      break;
    }

    case "department_rep": {
      ctx += `\n\n--- DEPARTMENT REP CONTEXT ---`;
      // Filter majors to target area
      if (university.majors?.length > 0) {
        const relevantMajors = (university.majors as string[]).filter(
          (m: string) =>
            m.toLowerCase().includes(targetMajor.toLowerCase()) ||
            targetMajor.toLowerCase().includes(m.toLowerCase()),
        );
        ctx += `\nRelevant Majors: ${relevantMajors.length > 0 ? relevantMajors.join(", ") : university.majors.join(", ")}`;
      }
      if (university.research) {
        ctx += `\nResearch: ${JSON.stringify(university.research)}`;
      }
      if (university.major_urls) {
        ctx += `\nMajor URLs: ${JSON.stringify(university.major_urls)}`;
      }
      // Filter courses and activities to target discipline
      const majorLower = targetMajor.toLowerCase();
      const relevantCourses = courses.filter(
        (c) =>
          c.subject_area?.toLowerCase().includes(majorLower) ||
          c.name?.toLowerCase().includes(majorLower),
      );
      if (relevantCourses.length > 0) {
        ctx += `\nRelevant Courses (${targetMajor}):`;
        for (const c of relevantCourses) {
          ctx += `\n  - ${c.name} (${c.level || "regular"}) — Grade: ${c.grade || "N/A"}`;
        }
      }
      const relevantActivities = activities.filter(
        (a) =>
          a.category?.toLowerCase().includes(majorLower) ||
          a.name?.toLowerCase().includes(majorLower),
      );
      if (relevantActivities.length > 0) {
        ctx += `\nRelevant Activities (${targetMajor}):`;
        for (const a of relevantActivities) {
          ctx += `\n  - ${a.name} (${a.role || "Member"})`;
        }
      }
      break;
    }

    case "interdisciplinary": {
      ctx += `\n\n--- INTERDISCIPLINARY CONTEXT ---`;
      // Cross-domain activities (different category from major)
      const majorCat = targetMajor.toLowerCase();
      const crossDomainActivities = activities.filter(
        (a) =>
          a.category &&
          !a.category.toLowerCase().includes(majorCat) &&
          !majorCat.includes(a.category.toLowerCase()),
      );
      if (crossDomainActivities.length > 0) {
        ctx += `\nCross-Domain Activities:`;
        for (const a of crossDomainActivities) {
          ctx += `\n  - ${a.name} (${a.category}): ${a.role || "Member"}`;
        }
      }
      // Breadth of coursework outside major
      const outsideMajorCourses = courses.filter(
        (c) =>
          c.subject_area &&
          !c.subject_area.toLowerCase().includes(majorCat) &&
          !majorCat.includes(c.subject_area.toLowerCase()),
      );
      if (outsideMajorCourses.length > 0) {
        const subjectAreas = [
          ...new Set(outsideMajorCourses.map((c) => c.subject_area)),
        ];
        ctx += `\nCoursework Breadth Outside Major: ${subjectAreas.join(", ")} (${outsideMajorCourses.length} courses)`;
      }
      break;
    }
  }

  return ctx;
}

function selectWinner(assessments: MemberAssessment[]): string {
  if (assessments.length === 0) throw new Error("No assessments to select winner from");

  // Find the highest conviction
  const maxConviction = Math.max(...assessments.map((a) => a.conviction));
  const topConviction = assessments.filter(
    (a) => a.conviction === maxConviction,
  );

  if (topConviction.length === 1) return topConviction[0].role;

  // Tiebreaker 1: senior_officer wins if part of tie
  const senior = topConviction.find((a) => a.role === "senior_officer");
  if (senior) return senior.role;

  // Tiebreaker 2: first_reader wins if part of tie
  const firstReader = topConviction.find((a) => a.role === "first_reader");
  if (firstReader) return firstReader.role;

  // Tiebreaker 3: most skeptical lean wins (deny > waitlist > admit)
  topConviction.sort(
    (a, b) => (LEAN_RANK[b.lean] || 0) - (LEAN_RANK[a.lean] || 0),
  );
  return topConviction[0].role;
}

function formatAssessmentsForSynthesis(
  assessments: MemberAssessment[],
): string {
  let ctx = "";
  for (const a of assessments) {
    ctx += `\nMEMBER: ${a.role}`;
    ctx += `\nLean: ${a.lean} (conviction ${a.conviction})`;
    ctx += `\nAssessment: ${a.assessment}`;
    ctx += `\nStrengths: ${a.strengths.join("; ")}`;
    ctx += `\nConcerns: ${a.concerns.join("; ")}`;
    ctx += `\nQuestion: ${a.question_for_committee}`;
    ctx += `\n`;
  }
  return ctx;
}

// ── Handler ──

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx: EdgeContext) => {
      const { student_id, school_name, target_major, essay_texts } =
        ctx.body as {
          student_id: string;
          school_name: string;
          target_major: string;
          essay_texts?: Record<string, string>;
        };

      // ── Step 1: Validate inputs ──

      if (!student_id || !school_name || !target_major) {
        return jsonResponse(
          { error: "student_id, school_name, and target_major are required" },
          400,
        );
      }

      // Verify counselor owns this student
      const { data: studentCheck } = await ctx.supabase
        .from("students")
        .select("counselor_id")
        .eq("id", student_id)
        .single();

      if (!studentCheck) {
        return jsonResponse({ error: "Student not found" }, 404);
      }

      if (
        ctx.callerRole !== "admin" &&
        studentCheck.counselor_id !== ctx.callerId
      ) {
        return jsonResponse(
          { error: "You do not have access to this student" },
          403,
        );
      }

      // Validate school exists
      const { data: universityCheck } = await ctx.supabase
        .from("universities")
        .select("id")
        .eq("name", school_name)
        .maybeSingle();

      if (!universityCheck) {
        return jsonResponse(
          { error: `University "${school_name}" not found` },
          404,
        );
      }

      // Check no generating simulation already exists
      const { data: existingSim } = await ctx.supabase
        .from("committee_simulations")
        .select("id")
        .eq("student_id", student_id)
        .eq("school_name", school_name)
        .eq("target_major", target_major)
        .eq("status", "generating")
        .maybeSingle();

      if (existingSim) {
        return jsonResponse(
          { error: "A simulation is already in progress for this student/school/major combination" },
          409,
        );
      }

      // ── Step 2: Lock — Insert simulation row ──

      const mode =
        essay_texts && Object.keys(essay_texts).length > 0
          ? "post_essay"
          : "pre_essay";

      // Calculate run_number
      const { data: maxRunData } = await ctx.supabase
        .from("committee_simulations")
        .select("run_number")
        .eq("student_id", student_id)
        .eq("school_name", school_name)
        .eq("target_major", target_major)
        .order("run_number", { ascending: false })
        .limit(1)
        .maybeSingle();

      const runNumber = (maxRunData?.run_number || 0) + 1;

      const { data: inserted, error: insertError } = await ctx.supabase
        .from("committee_simulations")
        .insert({
          student_id,
          school_name,
          target_major,
          mode,
          run_number: runNumber,
          status: "generating",
          created_by: ctx.callerId,
        })
        .select("id")
        .single();

      if (insertError || !inserted) {
        console.error("Failed to insert simulation row:", insertError);
        return jsonResponse(
          { error: "Failed to initialize simulation" },
          500,
        );
      }

      const simulationId = inserted.id;

      // From here on, any error must update status
      try {
        // ── Step 3: Parallel data fetch ──

        const [
          studentRes,
          coursesRes,
          activitiesRes,
          awardsRes,
          narrativeArcRes,
          collegeListRes,
          universityRes,
          memberProfilesRes,
          promptTemplatesRes,
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
            .eq("student_id", student_id),
          ctx.supabase
            .from("awards")
            .select("*")
            .eq("student_id", student_id),
          ctx.supabase
            .from("narrative_arcs")
            .select("*")
            .eq("student_id", student_id)
            .eq("status", "idle")
            .maybeSingle(),
          ctx.supabase
            .from("college_lists")
            .select("*")
            .eq("student_id", student_id),
          ctx.supabase
            .from("universities")
            .select("*")
            .eq("name", school_name)
            .single(),
          ctx.supabase
            .from("committee_member_profiles")
            .select("*")
            .eq("school_name", school_name),
          ctx.supabase.from("committee_prompt_templates").select("*"),
        ]);

        if (studentRes.error || !studentRes.data) {
          await markFailed(ctx, simulationId);
          return jsonResponse({ error: "Student not found" }, 404);
        }

        if (!narrativeArcRes.data) {
          await markFailed(ctx, simulationId);
          return jsonResponse(
            {
              error:
                "Narrative arc not found or not ready. Generate a narrative arc first.",
            },
            400,
          );
        }

        if (universityRes.error || !universityRes.data) {
          await markFailed(ctx, simulationId);
          return jsonResponse(
            { error: `University "${school_name}" not found` },
            404,
          );
        }

        const student = studentRes.data;
        const courses = coursesRes.data || [];
        const activities = activitiesRes.data || [];
        const awards = awardsRes.data || [];
        const arc = narrativeArcRes.data.arc as AnyRecord;
        const collegeList = collegeListRes.data || [];
        const university = universityRes.data;
        const memberProfiles = memberProfilesRes.data || [];
        const promptTemplates = promptTemplatesRes.data || [];

        // ── Step 5: Assemble panel ──

        const roles: string[] = [...BASE_ROLES];

        // Check if any member profile has cross_disciplinary in institutional_context
        const hasCrossDisciplinary = memberProfiles.some((p) => {
          const instCtx = p.institutional_context as AnyRecord;
          return instCtx?.cross_disciplinary === true;
        });
        if (hasCrossDisciplinary) {
          roles.push("interdisciplinary");
        }

        // ── Step 6: Build shared context ──

        const sharedContext = buildSharedContext(
          student,
          courses,
          activities,
          awards,
          arc,
          collegeList,
          school_name,
          mode === "post_essay" ? essay_texts : undefined,
        );

        // ── Build panel members with their prompts ──

        const panelComposition: PanelMember[] = [];
        const memberConfigs: {
          role: string;
          systemPrompt: string;
          userContext: string;
        }[] = [];

        for (const role of roles) {
          const template = promptTemplates.find(
            (t: AnyRecord) => t.role === role,
          );
          if (!template) {
            console.warn(`No template found for role: ${role}, skipping`);
            continue;
          }

          const profile = memberProfiles.find(
            (p: AnyRecord) => p.role === role,
          );

          // Build system prompt
          let systemPrompt = template.base_system_prompt;
          if (profile?.persona_prompt) {
            systemPrompt += `\n\n--- SCHOOL-SPECIFIC CONTEXT ---\n\n${profile.persona_prompt}`;
          }
          systemPrompt += `\n\n${MEMBER_RESPONSE_SCHEMA}`;

          // Build user context with role-specific additions
          const userContext = buildRoleContext(
            role,
            sharedContext,
            student,
            university,
            memberProfiles,
            courses,
            activities,
            target_major,
          );

          panelComposition.push({
            role,
            display_title: ROLE_DISPLAY_TITLES[role] || role,
            template_version: template.version,
            profile_version: profile?.version ?? null,
          });

          memberConfigs.push({ role, systemPrompt, userContext });
        }

        // ── Step 8: Phase 2 — Parallel member calls ──

        const assessmentResults = await Promise.all(
          memberConfigs.map(async ({ role, systemPrompt, userContext }) => {
            for (let attempt = 0; attempt < 2; attempt++) {
              try {
                const result = await callClaude(
                  systemPrompt,
                  userContext,
                  2048,
                );
                const parsed = parseJsonResponse<MemberAssessment>(
                  result.text,
                );
                // Attach role in case model omits it
                parsed.role = role;

                await trackAIUsage(ctx.supabase, {
                  function_name: "simulate-committee",
                  result,
                  student_id,
                  caller_id: ctx.callerId,
                  metadata: {
                    school_name,
                    phase: "member_assessment",
                    role,
                  },
                });

                return { success: true as const, role, assessment: parsed };
              } catch (err) {
                if (attempt === 0) {
                  console.warn(
                    `Retrying ${role} after error:`,
                    (err as Error).message,
                  );
                  continue;
                }
                console.error(
                  `Failed ${role} after retry:`,
                  (err as Error).message,
                );
                return { success: false as const, role, error: (err as Error).message };
              }
            }
            // Unreachable, but TypeScript needs it
            return { success: false as const, role, error: "Unknown error" };
          }),
        );

        const successfulAssessments = assessmentResults
          .filter(
            (r): r is { success: true; role: string; assessment: MemberAssessment } =>
              r.success,
          )
          .map((r) => r.assessment);

        if (successfulAssessments.length < 3) {
          await ctx.supabase
            .from("committee_simulations")
            .update({
              status: "failed",
              error_phase: "member_assessment",
              assessments: successfulAssessments,
              panel_composition: panelComposition,
            })
            .eq("id", simulationId);

          return jsonResponse(
            {
              error: `Only ${successfulAssessments.length} of ${memberConfigs.length} committee members responded. Minimum 3 required.`,
            },
            500,
          );
        }

        // ── Step 9: Phase 3 — Winner selection + synthesis ──

        const winnerRole = selectWinner(successfulAssessments);
        const winnerAssessment = successfulAssessments.find(
          (a) => a.role === winnerRole,
        )!;
        const winnerConfig = memberConfigs.find(
          (c) => c.role === winnerRole,
        )!;

        const synthesisSystemPrompt = `You are the ${ROLE_DISPLAY_TITLES[winnerRole] || winnerRole} and you have won the floor. You are delivering the committee's final verdict.

${winnerConfig.systemPrompt}

You must respond with a JSON object in this exact format:
{
  "final_lean": "admit" | "waitlist" | "deny",
  "verdict": "<3-4 paragraphs delivering the committee's final assessment>",
  "consensus_points": ["<points all members agreed on>", ...],
  "friction_points": ["<points of disagreement>", ...],
  "tip_factors": ["<factors that tipped the decision>", ...],
  "what_would_change": ["<what would change the outcome>", ...]
}`;

        const synthesisContext = `THE COMMITTEE HAS DELIBERATED. Here are all member assessments:\n${formatAssessmentsForSynthesis(successfulAssessments)}\n\nYour original assessment leaned ${winnerAssessment.lean} with conviction ${winnerAssessment.conviction}. Now synthesize the full committee discussion into a final verdict.`;

        let synthResult: SynthesisResult | null = null;

        try {
          const synthResponse = await callClaude(
            synthesisSystemPrompt,
            synthesisContext,
            2048,
          );
          synthResult = parseJsonResponse<SynthesisResult>(
            synthResponse.text,
          );

          await trackAIUsage(ctx.supabase, {
            function_name: "simulate-committee",
            result: synthResponse,
            student_id,
            caller_id: ctx.callerId,
            metadata: { school_name, phase: "synthesis" },
          });
        } catch (err) {
          console.error("Synthesis failed:", (err as Error).message);
          // Save partial results
          await ctx.supabase
            .from("committee_simulations")
            .update({
              panel_composition: panelComposition,
              assessments: successfulAssessments,
              winner_role: winnerRole,
              status: "partial",
              error_phase: "synthesis",
            })
            .eq("id", simulationId);

          return { simulation_id: simulationId };
        }

        // ── Step 10: Phase 4 — Essay prompt analysis (conditional) ──

        let essayAnalysis: EssayAnalysisItem[] | null = null;

        // Check if institutional_context has current_essay_prompts
        const schoolProfile = memberProfiles.find(
          (p) => (p.institutional_context as AnyRecord)?.current_essay_prompts,
        );
        const essayPrompts = (
          schoolProfile?.institutional_context as AnyRecord
        )?.current_essay_prompts;

        if (essayPrompts && Array.isArray(essayPrompts) && essayPrompts.length > 0) {
          const essayAnalysisSystem = `You are an admissions committee essay strategist. Given the committee's assessment of this student, analyze each essay prompt. Respond as a JSON array:
[{
  "prompt_text": "<the essay prompt>",
  "risk_level": "high" | "medium" | "low",
  "risk_analysis": "<why this prompt is risky or safe for this student>",
  "suggested_angle": "<recommended approach>",
  "improvement_suggestions": ["<specific suggestion>", ...],
  "avoid": ["<what to avoid>", ...]
}]`;

          const essayAnalysisContext = `COMMITTEE ASSESSMENTS:\n${formatAssessmentsForSynthesis(successfulAssessments)}\n\nSYNTHESIS VERDICT:\n${synthResult.verdict}\n\nESSAY PROMPTS:\n${essayPrompts.map((p: string, i: number) => `${i + 1}. ${p}`).join("\n")}`;

          try {
            const essayResponse = await callClaude(
              essayAnalysisSystem,
              essayAnalysisContext,
              2048,
            );
            essayAnalysis = parseJsonResponse<EssayAnalysisItem[]>(
              essayResponse.text,
            );

            await trackAIUsage(ctx.supabase, {
              function_name: "simulate-committee",
              result: essayResponse,
              student_id,
              caller_id: ctx.callerId,
              metadata: { school_name, phase: "essay_analysis" },
            });
          } catch (err) {
            console.error("Essay analysis failed:", (err as Error).message);
            // Save partial results with synthesis but no essay analysis
            await ctx.supabase
              .from("committee_simulations")
              .update({
                panel_composition: panelComposition,
                assessments: successfulAssessments,
                winner_role: winnerRole,
                synthesis: synthResult,
                outcome: synthResult.final_lean,
                status: "partial",
                error_phase: "essay_analysis",
                generated_at: new Date().toISOString(),
              })
              .eq("id", simulationId);

            return { simulation_id: simulationId };
          }
        }

        // ── Step 11: Save results ──

        await ctx.supabase
          .from("committee_simulations")
          .update({
            panel_composition: panelComposition,
            assessments: successfulAssessments,
            winner_role: winnerRole,
            synthesis: synthResult,
            essay_analysis: essayAnalysis,
            outcome: synthResult.final_lean,
            status: "idle",
            error_phase: null,
            generated_at: new Date().toISOString(),
          })
          .eq("id", simulationId);

        return { simulation_id: simulationId };
      } catch (err) {
        console.error("Committee simulation error:", err);
        await markFailed(ctx, simulationId);
        throw err;
      }
    },
  }),
);

/** Mark simulation as failed on unrecoverable error. */
async function markFailed(
  ctx: EdgeContext,
  simulationId: string,
): Promise<void> {
  const { error } = await ctx.supabase
    .from("committee_simulations")
    .update({ status: "failed" })
    .eq("id", simulationId);

  if (error) {
    console.error("Failed to mark simulation as failed:", error);
  }
}
