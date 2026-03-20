import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface SuggestedScenario {
  key: string;
  title: string;
  rationale: string;
  source_type: "gap" | "contradiction" | "identity_frame" | "throughline";
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

    // Fetch student data
    const [arcRes, collegeRes, studentRes] = await Promise.all([
      supabase
        .from("narrative_arcs")
        .select("arc, stage")
        .eq("student_id", student_id)
        .single(),
      supabase
        .from("college_lists")
        .select("school_name, app_status, app_round")
        .eq("student_id", student_id),
      supabase
        .from("students")
        .select("full_name, profile_insights")
        .eq("id", student_id)
        .single(),
    ]);

    if (!arcRes.data?.arc) {
      return new Response(JSON.stringify({ error: "No narrative arc found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }

    const arc = arcRes.data.arc;
    const colleges = collegeRes.data ?? [];
    const student = studentRes.data;

    const systemPrompt = `You are a college admissions strategist. Given this student's narrative arc, suggest 3-5 specific actions that would strengthen their application.

Each suggestion must:
- Reference a specific gap, contradiction, identity frame, or throughline from the arc by its "key" field
- Propose concrete modifications using ONLY these types: add_course, add_activity, drop_activity, improve_test_score
- Each modification needs: type, description (human-readable summary), details (key-value pairs specific to the type)
- For add_course: details must have "name" and "level" (e.g. AP, IB, Honors)
- For add_activity: details must have "name" and "role"
- For drop_activity: details must have "name"
- For improve_test_score: details must have "test" and "score"
- Explain WHY this action addresses the identified issue
- Be actionable within the current application cycle

Respond with a JSON array: [{ "key": "...", "title": "...", "rationale": "...", "source_type": "gap|contradiction|identity_frame|throughline", "source_key": "...", "modifications": [...] }]`;

    const userContent = `Student: ${student?.full_name ?? "Unknown"}

Narrative Arc (stage: ${arcRes.data.stage}):
Throughlines: ${JSON.stringify(arc.throughlines?.map((t: { key: string; title: string; narrative: string }) => ({ key: t.key, title: t.title, narrative: t.narrative })) ?? [])}
Gaps: ${JSON.stringify(arc.gaps ?? [])}
Contradictions: ${JSON.stringify(arc.contradictions ?? [])}
Identity Frames: ${JSON.stringify(arc.identity_frames?.map((f: { key: string; title: string; pitch: string; best_for: string[] }) => ({ key: f.key, title: f.title, pitch: f.pitch, best_for: f.best_for })) ?? [])}

College List:
${colleges.map((c: { school_name: string; app_status: string; app_round: string | null }) => `- ${c.school_name} (${c.app_status}${c.app_round ? `, ${c.app_round}` : ""})`).join("\n")}

Current Profile:
${student?.profile_insights ? Object.entries(student.profile_insights).map(([dim, data]: [string, unknown]) => {
  const d = data as { tier: string };
  return `- ${dim}: ${d.tier}`;
}).join("\n") : "No profile insights available"}`;

    const result = await callClaude(systemPrompt, userContent, 2048);
    const suggestions = parseJsonResponse<SuggestedScenario[]>(result.text);

    // Validate: filter out any with invalid source_type
    const validSourceTypes = ["gap", "contradiction", "identity_frame", "throughline"];
    const validated = suggestions.filter(
      (s: SuggestedScenario) =>
        s.key && s.title && s.rationale && s.source_key &&
        validSourceTypes.includes(s.source_type) &&
        Array.isArray(s.modifications) && s.modifications.length > 0
    );

    // Save to narrative_arcs
    const { error: updateError } = await supabase
      .from("narrative_arcs")
      .update({ suggested_scenarios: validated })
      .eq("student_id", student_id);

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
