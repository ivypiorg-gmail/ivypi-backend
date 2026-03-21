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

RULES — read these carefully before generating your response:

1. TIER-NARRATIVE CONSISTENCY (most important rule):
   Before finalizing each dimension, verify: does the tier direction match the narrative?
   - If your narrative says the modification helps, supports, strengthens, or broadens a dimension → the tier MUST stay the same or go UP. It must NEVER go down.
   - If your narrative says the modification hurts, dilutes, or weakens a dimension → the tier may go down.
   - A tier decrease paired with a positive narrative is a contradiction. This is the #1 mistake to avoid.

2. SCENARIO-NARRATIVE CONSISTENCY:
   The scenario_narrative summarizes the overall impact. Every claim in it must match the actual tier directions above. If you say a dimension "improved" or was "supported", the tier for that dimension must not have decreased.

3. ADDITIVE MODIFICATIONS:
   Adding a course, activity, or improving a test score should almost never decrease any tier. The only exception is if the addition actively harms narrative coherence (e.g. a random activity that dilutes an otherwise focused profile). If you are not describing such harm in the narrative, do not lower the tier.

4. SELF-CHECK:
   After generating your JSON, mentally review each dimension: "Did I lower a tier? If so, does my narrative explicitly explain WHY this modification is harmful to that dimension?" If the answer is no, keep the tier at its current level.

5. Be realistic — one AP course alone rarely shifts Academic Rigor from Developing to Compelling. Focus on how modifications affect the coherence of the student's story. Be constructive and encouraging.`;

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
