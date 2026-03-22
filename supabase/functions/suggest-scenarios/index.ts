import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface SuggestedScenario {
  key: string;
  title: string;
  rationale: string;
  source_type: "dimension";
  source_key: string;
  modifications: { type: string; description: string; details: Record<string, string> }[];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
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
          headers: { "Content-Type": "application/json" },
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
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    const { student_id } = await req.json();
    if (!student_id) {
      return new Response(JSON.stringify({ error: "student_id required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
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
            headers: { "Content-Type": "application/json" },
          });
        }
      }
    }

    // Fetch student data — profile insights are the primary input
    const [studentRes, collegeRes, arcRes] = await Promise.all([
      supabase
        .from("students")
        .select("full_name, profile_insights")
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
    if (!student?.profile_insights || Object.keys(student.profile_insights).length === 0) {
      return new Response(JSON.stringify({ error: "No profile insights found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }

    const colleges = collegeRes.data ?? [];
    const arc = arcRes.data?.arc ?? null;

    const systemPrompt = `You are a college admissions strategist. Given this student's profile insights across 6 dimensions, suggest 3-5 specific actions that would strengthen their weakest areas.

Each suggestion must:
- Reference a specific profile dimension by its key (e.g. "community_impact", "academic_rigor", "extracurricular_depth", "leadership", "intellectual_curiosity", "narrative_coherence")
- Propose concrete modifications using ONLY these types: add_course, add_activity, drop_activity, improve_test_score
- Each modification needs: type, description (human-readable summary), details (key-value pairs specific to the type)
- For add_course: details must have "name" and "level" (e.g. AP, IB, Honors)
- For add_activity: details must have "name" and "role"
- For drop_activity: details must have "name"
- For improve_test_score: details must have "test" and "score"
- Explain WHY this action addresses the identified weakness
- Be actionable within the current application cycle
- Prioritize dimensions with "Developing" or "Emerging" tiers

${arc ? "If narrative arc context is provided, use it to add strategic depth — consider gaps, contradictions, and throughlines when crafting suggestions." : ""}

Respond with a JSON array: [{ "key": "<unique-id>", "title": "...", "rationale": "...", "source_type": "dimension", "source_key": "<dimension_key>", "modifications": [...] }]`;

    const profileSection = Object.entries(student.profile_insights as Record<string, { tier: string; narrative: string; recommendation: string }>)
      .map(([dim, data]) => `- ${dim}: ${data.tier}\n  Narrative: ${data.narrative}\n  Recommendation: ${data.recommendation}`)
      .join("\n");

    let userContent = `Student: ${student.full_name}

Profile Insights:
${profileSection}

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

    const result = await callClaude(systemPrompt, userContent, 2048);
    const suggestions = parseJsonResponse<SuggestedScenario[]>(result.text);

    // Validate: ensure all have source_type "dimension" and valid dimension keys
    const validDimensions = ["academic_rigor", "extracurricular_depth", "leadership", "community_impact", "intellectual_curiosity", "narrative_coherence"];
    const validated = suggestions.filter(
      (s: SuggestedScenario) =>
        s.key && s.title && s.rationale && s.source_key &&
        s.source_type === "dimension" &&
        validDimensions.includes(s.source_key) &&
        Array.isArray(s.modifications) && s.modifications.length > 0
    );

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
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({
        success: true,
        count: validated.length,
        usage: result.usage,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : "Unknown error" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});
