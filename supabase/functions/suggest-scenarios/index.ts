import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { corsHeaders } from "../_shared/edge-middleware.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface PlaybookItem {
  action_ref: string;
  step: string;
}

interface ImplementationPlaybook {
  counselor: PlaybookItem[];
  student: PlaybookItem[];
  parent: PlaybookItem[];
}

interface StrategyPhase {
  label: string;
  urgency: "immediate" | "near" | "future";
  actions: { type: "add_course" | "add_activity" | "drop_activity" | "improve_test_score"; description: string; details: Record<string, string> }[];
}

interface StrategyPackage {
  key: string;
  title: string;
  rationale: string;
  compatibility: { type: "complementary" | "alternative"; conflicts_with?: string[] };
  source_gaps: string[];
  phases: StrategyPhase[];
  maintain: string;
  playbook: ImplementationPlaybook;
}

interface StrategyPlaybook {
  shared_strengths: { title: string; detail: string; tier: string }[];
  packages: StrategyPackage[];
}

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const token = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // Dual auth: service role key OR user JWT
    let callerId: string | null = null;
    const isServiceRole = token === serviceRoleKey;

    if (!isServiceRole) {
      const { data: { user }, error: authError } = await supabase.auth.getUser(token);
      if (authError || !user) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: jsonHeaders,
        });
      }
      callerId = user.id;

      // Check role
      const { data: profile } = await supabase
        .from("profiles")
        .select("role")
        .eq("id", user.id)
        .single();

      if (!profile || !["counselor", "admin"].includes(profile.role)) {
        return new Response(JSON.stringify({ error: "Forbidden" }), {
          status: 403,
          headers: jsonHeaders,
        });
      }
    }

    const { student_id, counselor_guidance, regenerate_key } = await req.json();
    if (!student_id) {
      return new Response(JSON.stringify({ error: "student_id required" }), {
        status: 400,
        headers: jsonHeaders,
      });
    }

    // If user JWT, verify access to student
    if (callerId) {
      const { data: student } = await supabase
        .from("students")
        .select("counselor_id")
        .eq("id", student_id)
        .single();

      if (!student || (student.counselor_id !== callerId)) {
        // Check admin fallback
        const { data: callerProfile } = await supabase
          .from("profiles")
          .select("role")
          .eq("id", callerId)
          .single();
        if (callerProfile?.role !== "admin") {
          return new Response(JSON.stringify({ error: "Forbidden" }), {
            status: 403,
            headers: jsonHeaders,
          });
        }
      }
    }

    // Fetch student data — profile insights are the primary input
    const [studentRes, collegeRes, arcRes] = await Promise.all([
      supabase
        .from("students")
        .select("full_name, profile_insights, suggested_scenarios")
        .eq("id", student_id)
        .single(),
      supabase
        .from("college_lists")
        .select("school_name, app_status, app_round")
        .eq("student_id", student_id),
      supabase
        .from("narrative_arcs")
        .select("arc, stage")
        .eq("student_id", student_id)
        .single(),
    ]);

    const student = studentRes.data;
    const briefing = student?.profile_insights as {
      strategic_overview?: string;
      grade_context?: { urgency?: string; grad_year?: number; current_grade?: string };
      strengths?: { title: string; narrative: string; tier: string; evidence?: string[] }[];
      gaps?: { title: string; narrative: string; suggestion: string; tier: string }[];
      next_steps?: { action: string; rationale: string; priority: number }[];
    } | null;

    if (!briefing?.gaps || briefing.gaps.length === 0) {
      return new Response(
        JSON.stringify({ success: true, count: 0 }),
        { status: 200, headers: jsonHeaders }
      );
    }

    const colleges = collegeRes.data ?? [];
    const arc = arcRes.data?.arc ?? null;

    const urgency = briefing.grade_context?.urgency ?? "building";

    const phaseGuidance = urgency === "exploratory"
      ? 'Use phase labels: "This Year", "Next Year", "By Junior Year", "By Senior Year". Suggestions should be exploratory and identity-forming.'
      : urgency === "building"
      ? 'Use phase labels: "Now", "Spring", "Junior Year", "Senior Year". Suggestions should consolidate interests into clear threads.'
      : urgency === "positioning"
      ? 'Use phase labels: "Now", "This Semester", "Application Season". Suggestions should be urgent and positioning-focused.'
      : 'Use phase labels: "Now", "Before Deadlines". Suggestions should maximize what already exists.';

    const gapsSection = briefing.gaps
      .map((g) => `- ${g.title} (${g.tier})\n  ${g.narrative}\n  Suggestion: ${g.suggestion}`)
      .join("\n");

    const strengthsSection = (briefing.strengths ?? [])
      .map((s) => `- ${s.title} (${s.tier}): ${s.narrative}`)
      .join("\n");

    const nextStepsSection = (briefing.next_steps ?? [])
      .map((ns) => `${ns.priority}. ${ns.action} — ${ns.rationale}`)
      .join("\n");

    let userContent = `Student: ${student.full_name}

Strategic Overview:
${briefing.strategic_overview ?? "N/A"}

Gaps (primary input for strategy packages):
${gapsSection}

Strengths (context — extract shared_strengths from Compelling/Strong tier):
${strengthsSection}

Next Steps (context):
${nextStepsSection}

College List:
${colleges.map((c: { school_name: string; app_status: string; app_round: string | null }) => `- ${c.school_name} (${c.app_status}${c.app_round ? `, ${c.app_round}` : ""})`).join("\n")}`;

    // Add narrative arc as optional enrichment context
    if (arc) {
      userContent += `

Narrative Arc Context (for strategic depth):
Throughlines: ${JSON.stringify(arc.throughlines?.map((t: { key: string; title: string; narrative: string }) => ({ key: t.key, title: t.title, narrative: t.narrative })) ?? [])}
Gaps: ${JSON.stringify(arc.gaps ?? [])}
Contradictions: ${JSON.stringify(arc.contradictions ?? [])}`;
    }

    // Add counselor guidance if provided
    if (counselor_guidance) {
      userContent += `

Counselor Guidance (incorporate into strategy):
${counselor_guidance}`;
    }

    // --- Single-package regeneration flow ---
    if (regenerate_key) {
      const currentPlaybook = student?.suggested_scenarios as StrategyPlaybook | null;
      if (!currentPlaybook || !Array.isArray(currentPlaybook.packages)) {
        return new Response(
          JSON.stringify({ error: "No existing playbook to regenerate from" }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const targetIndex = currentPlaybook.packages.findIndex((p: StrategyPackage) => p.key === regenerate_key);
      if (targetIndex === -1) {
        return new Response(
          JSON.stringify({ error: `Package with key "${regenerate_key}" not found` }),
          { status: 404, headers: jsonHeaders }
        );
      }

      const targetPackage = currentPlaybook.packages[targetIndex];
      const otherPackages = currentPlaybook.packages.filter((_: StrategyPackage, i: number) => i !== targetIndex);

      const regenSystemPrompt = `You are a senior college admissions counselor with 20+ years of experience building student strategies. You are regenerating ONE strategy package for a student.

The previous package titled "${targetPackage.title}" (key: "${targetPackage.key}") addressing gaps [${targetPackage.source_gaps.join(", ")}] needs to be replaced with a fresh alternative.

Generate exactly ONE new strategy package that:
- Addresses the SAME source_gaps: [${targetPackage.source_gaps.join(", ")}]
- Takes a meaningfully DIFFERENT approach than the previous package
- Does NOT duplicate actions from these other existing packages: ${JSON.stringify(otherPackages.map((p: StrategyPackage) => ({ key: p.key, title: p.title, actions: p.phases.flatMap((ph: StrategyPhase) => ph.actions.map((a) => a.description)) })))}

Cluster the addressed gaps into a coherent strategic theme for the package title.

Phase sequencing:
- Urgency level is "${urgency}". ${phaseGuidance}
- Each phase has an urgency field: "immediate" (do now), "near" (next few months), "future" (longer term).

Action types are ONLY: add_course, add_activity, drop_activity, improve_test_score.
- For add_course: details must have "name" and "level" (e.g. AP, IB, Honors)
- For add_activity: details must have "name" and "role"
- For drop_activity: details must have "name"
- For improve_test_score: details must have "test" and "score"

Each package must include:
- "maintain": a short sentence about what the student should keep doing (existing strengths to preserve)
- "playbook": implementation steps for counselor, student, and parent. Each item has "action_ref" (matching an action description from the phases) and "step" (concrete next step for that stakeholder).
- "compatibility": { "type": "complementary" or "alternative", "conflicts_with": [keys of conflicting packages] }. Mark as "alternative" if it conflicts with any existing package; "complementary" if it can coexist.

${arc ? "Use the narrative arc context to add strategic depth — consider throughlines, gaps, and contradictions." : ""}

IMPORTANT: The output package must use the key "${targetPackage.key}" (preserve the original key).

Respond with a JSON object matching this exact schema:
{
  "key": "${targetPackage.key}",
  "title": "...",
  "rationale": "...",
  "compatibility": { "type": "complementary" | "alternative", "conflicts_with": ["..."] },
  "source_gaps": [${targetPackage.source_gaps.map((g: string) => `"${g}"`).join(", ")}],
  "phases": [{ "label": "...", "urgency": "immediate" | "near" | "future", "actions": [{ "type": "...", "description": "...", "details": {...} }] }],
  "maintain": "...",
  "playbook": { "counselor": [{ "action_ref": "...", "step": "..." }], "student": [...], "parent": [...] }
}`;

      const regenResult = await callClaude(regenSystemPrompt, userContent, 6144);
      const newPackage = parseJsonResponse<StrategyPackage>(regenResult.text);

      // Validate the regenerated package
      if (
        !newPackage.key || !newPackage.title || !newPackage.rationale ||
        !Array.isArray(newPackage.phases) || newPackage.phases.length === 0 ||
        !newPackage.playbook || !Array.isArray(newPackage.source_gaps)
      ) {
        throw new Error("Invalid regenerated package structure");
      }

      // Preserve original key
      newPackage.key = targetPackage.key;

      // Replace the old package and preserve order
      const updatedPackages = [...currentPlaybook.packages];
      updatedPackages[targetIndex] = newPackage;

      const updatedPlaybook: StrategyPlaybook = {
        shared_strengths: currentPlaybook.shared_strengths,
        packages: updatedPackages,
      };

      // Save WITHOUT updating suggested_scenarios_generated_at
      const { error: updateError } = await supabase
        .from("students")
        .update({
          suggested_scenarios: updatedPlaybook,
        })
        .eq("id", student_id);

      if (updateError) {
        return new Response(JSON.stringify({ error: updateError.message }), {
          status: 500,
          headers: jsonHeaders,
        });
      }

      return new Response(
        JSON.stringify({
          success: true,
          regenerated_key: regenerate_key,
          count: updatedPackages.length,
          usage: regenResult.usage,
        }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // --- Full generation flow ---
    const systemPrompt = `You are a senior college admissions counselor with 20+ years of experience building student strategies. Given this student's strategic briefing, create a comprehensive strategy playbook.

Your output is a StrategyPlaybook with two parts:

1. "shared_strengths": Extract the student's strongest assets from the briefing strengths that are "Compelling" or "Strong" tier. Each entry has "title", "detail" (a concise sentence on why this is an asset), and "tier".

2. "packages": Create 2-4 strategy packages. Each package clusters related gaps into a coherent strategic theme.

For each package:
- "key": a unique kebab-case identifier (e.g. "stem-depth-boost")
- "title": a short, descriptive name for the strategic theme
- "rationale": explain WHY this cluster of actions addresses the identified gaps and how it strengthens the student's profile
- "source_gaps": array of exact gap titles from the briefing that this package addresses
- "compatibility": { "type": "complementary" or "alternative", "conflicts_with": [keys of conflicting packages] }. If two packages can coexist (address different gaps, no resource conflicts), mark both as "complementary". If they compete for the same slot or represent mutually exclusive paths, mark as "alternative" with cross-references.
- "phases": sequence actions into time-based phases. Each phase has:
  - "label": a time label appropriate for the urgency level
  - "urgency": "immediate" (do now), "near" (next few months), "future" (longer term)
  - "actions": array of concrete actions. Each action has:
    - "type": ONLY one of: add_course, add_activity, drop_activity, improve_test_score
    - "description": human-readable summary of the action
    - "details": key-value pairs specific to the type:
      - For add_course: "name" and "level" (e.g. AP, IB, Honors)
      - For add_activity: "name" and "role"
      - For drop_activity: "name"
      - For improve_test_score: "test" and "score"
- "maintain": a short sentence about what the student should keep doing (existing strengths to preserve)
- "playbook": implementation steps broken down by stakeholder:
  - "counselor": steps the counselor should take (e.g. "Schedule meeting to discuss course selection")
  - "student": steps the student should take (e.g. "Research AP Environmental Science syllabus")
  - "parent": steps the parent can support with (e.g. "Help identify local volunteer organizations")
  Each item has "action_ref" (matching an action description from the phases) and "step" (concrete next step).

Phase sequencing rules:
- Urgency level is "${urgency}". ${phaseGuidance}
- Prioritize gaps with "Developing" or "Emerging" tiers for immediate phases.

${arc ? "Use the narrative arc context to add strategic depth — consider throughlines, gaps, and contradictions when crafting packages." : ""}

${counselor_guidance ? "The counselor has provided specific guidance that MUST be incorporated into the strategy." : ""}

Respond with a JSON object matching this exact schema:
{
  "shared_strengths": [{ "title": "...", "detail": "...", "tier": "..." }],
  "packages": [{
    "key": "...",
    "title": "...",
    "rationale": "...",
    "compatibility": { "type": "complementary" | "alternative", "conflicts_with": ["..."] },
    "source_gaps": ["..."],
    "phases": [{ "label": "...", "urgency": "immediate" | "near" | "future", "actions": [{ "type": "...", "description": "...", "details": {...} }] }],
    "maintain": "...",
    "playbook": { "counselor": [{ "action_ref": "...", "step": "..." }], "student": [{ "action_ref": "...", "step": "..." }], "parent": [{ "action_ref": "...", "step": "..." }] }
  }]
}`;

    const result = await callClaude(systemPrompt, userContent, 6144);
    const playbook = parseJsonResponse<StrategyPlaybook>(result.text);

    // Validate playbook structure
    if (!playbook.shared_strengths || !Array.isArray(playbook.packages)) {
      throw new Error("Invalid playbook structure");
    }
    const validatedPackages = playbook.packages.filter(
      (p: StrategyPackage) =>
        p.key && p.title && p.rationale &&
        Array.isArray(p.phases) && p.phases.length > 0 &&
        p.playbook && Array.isArray(p.source_gaps)
    );
    const validated: StrategyPlaybook = {
      shared_strengths: playbook.shared_strengths,
      packages: validatedPackages,
    };

    // Save to students table
    const { error: updateError } = await supabase
      .from("students")
      .update({
        suggested_scenarios: validated,
        suggested_scenarios_generated_at: new Date().toISOString(),
      })
      .eq("id", student_id);

    if (updateError) {
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: jsonHeaders,
      });
    }

    return new Response(
      JSON.stringify({
        success: true,
        count: validatedPackages.length,
        usage: result.usage,
      }),
      { status: 200, headers: jsonHeaders }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : "Unknown error" }),
      { status: 500, headers: jsonHeaders }
    );
  }
});
