import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface Modification {
  type: "add_course" | "add_activity" | "drop_activity" | "improve_test_score";
  description: string;
  details: Record<string, string>;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const { student_id, scenario_name, modifications } = await req.json();

    if (!student_id || !scenario_name || !modifications?.length) {
      return new Response(
        JSON.stringify({ error: "student_id, scenario_name, and modifications are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Authenticate caller — must be counselor or admin
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user: caller }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !caller) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: callerProfile } = await supabase
      .from("profiles")
      .select("id, role")
      .eq("id", caller.id)
      .single();

    if (!callerProfile || !["counselor", "admin"].includes(callerProfile.role)) {
      return new Response(
        JSON.stringify({ error: "Counselor or admin access required" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Fetch student data
    const [studentRes, coursesRes, activitiesRes, schoolsRes] = await Promise.all([
      supabase.from("students").select("*").eq("id", student_id).single(),
      supabase.from("courses").select("*").eq("student_id", student_id).order("year"),
      supabase.from("activities").select("*").eq("student_id", student_id).order("name"),
      supabase.from("college_lists").select("school_name").eq("student_id", student_id),
    ]);

    if (studentRes.error || !studentRes.data) {
      return new Response(
        JSON.stringify({ error: "Student not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const student = studentRes.data;
    const courses = coursesRes.data || [];
    const activities = activitiesRes.data || [];
    const schoolNames = (schoolsRes.data || []).map((s: { school_name: string }) => s.school_name);

    const mods = modifications as Modification[];

    // Build context
    const modsDescription = mods
      .map((m) => `- ${m.description}`)
      .join("\n");

    const studentContext = `
Student: ${student.full_name}
High School: ${student.high_school || "Unknown"}
Graduation Year: ${student.grad_year || "Unknown"}
GPA (Unweighted): ${student.gpa_unweighted ?? "N/A"}
GPA (Weighted): ${student.gpa_weighted ?? "N/A"}
Test Scores: ${JSON.stringify(student.test_scores || {})}
Current Profile Insights: ${JSON.stringify(student.profile_insights || {})}

Current Courses (${courses.length} total):
${courses.map((c) => `- ${c.name} (${c.level || "regular"}, ${c.subject_area || "other"}) — Grade: ${c.grade || "N/A"}, Year: ${c.year || "N/A"}`).join("\n")}

Current Activities (${activities.length} total):
${activities.map((a) => `- ${a.name} (${a.category || "other"}) — Role: ${a.role || "N/A"}, Depth: ${a.depth_tier || "N/A"}\n  Impact: ${a.impact_description || "N/A"}`).join("\n")}

PROPOSED MODIFICATIONS:
${modsDescription}`;

    const systemPrompt = `You are a college admissions scenario modeler for IvyPi, a college consulting firm.

Given a student's current profile and a set of proposed modifications (adding/dropping courses or activities, improving test scores), project how these changes would affect their 6-dimension profile.

Return ONLY valid JSON with this exact structure:
{
  "projected_insights": {
    "academic_rigor": {
      "tier": "Compelling|Strong|Developing|Emerging",
      "narrative": "2-3 sentences analyzing the projected academic trajectory with modifications applied",
      "recommendation": "1-2 sentences of advice"
    },
    "extracurricular_depth": { "tier": "...", "narrative": "...", "recommendation": "..." },
    "leadership": { "tier": "...", "narrative": "...", "recommendation": "..." },
    "community_impact": { "tier": "...", "narrative": "...", "recommendation": "..." },
    "intellectual_curiosity": { "tier": "...", "narrative": "...", "recommendation": "..." },
    "narrative_coherence": { "tier": "...", "narrative": "...", "recommendation": "..." }
  },
  "scenario_narrative": "A 3-4 sentence paragraph summarizing the overall impact of these modifications on the student's profile, highlighting the most significant tier changes and strategic value."
}

Important:
- Compare against the CURRENT profile insights to identify tier changes
- Be realistic about what modifications would actually shift tiers
- Adding one AP course alone rarely shifts Academic Rigor from Developing to Compelling
- CRITICAL: Adding a course or activity must NEVER decrease a tier unless it actively harms coherence (e.g. an off-brand activity diluting focus). Adding AP Physics C should not lower Intellectual Curiosity — it shows STEM breadth. If the narrative for a dimension is positive, the tier must not go down.
- Ensure the tier direction is consistent with the narrative you write. If the narrative describes improvement, the tier must stay the same or go up — never down.
- Focus on how modifications affect the coherence of the student's story
- Be constructive and encouraging`;

    const result = await callClaude(systemPrompt, studentContext, 4096);
    const parsed = parseJsonResponse<{
      projected_insights: Record<string, unknown>;
      scenario_narrative: string;
    }>(result.text);

    // Save scenario
    const { data: scenario, error: insertError } = await supabase
      .from("scenarios")
      .insert({
        student_id,
        name: scenario_name,
        modifications: mods,
        projected_insights: parsed.projected_insights,
        scenario_narrative: parsed.scenario_narrative,
        created_by: caller.id,
      })
      .select("id")
      .single();

    if (insertError) {
      return new Response(
        JSON.stringify({ error: "Failed to save scenario", details: insertError.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    return new Response(
      JSON.stringify({
        message: "Scenario modeled successfully",
        scenario_id: scenario.id,
        projected_insights: parsed.projected_insights,
        scenario_narrative: parsed.scenario_narrative,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("model-scenario error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
