import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const { student_id } = await req.json();
    if (!student_id) {
      return new Response(
        JSON.stringify({ error: "student_id is required" }),
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

    // Fetch all student data
    const [studentRes, coursesRes, activitiesRes] = await Promise.all([
      supabase.from("students").select("*").eq("id", student_id).single(),
      supabase.from("courses").select("*").eq("student_id", student_id).order("year"),
      supabase.from("activities").select("*").eq("student_id", student_id).order("name"),
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

    // Build context for Claude
    const studentContext = `
Student: ${student.full_name}
High School: ${student.high_school || "Unknown"}
Graduation Year: ${student.grad_year || "Unknown"}
GPA (Unweighted): ${student.gpa_unweighted ?? "N/A"}
GPA (Weighted): ${student.gpa_weighted ?? "N/A"}
Test Scores: ${JSON.stringify(student.test_scores || {})}

Courses (${courses.length} total):
${courses.map((c) => `- ${c.name} (${c.level || "regular"}, ${c.subject_area || "other"}) — Grade: ${c.grade || "N/A"}, Year: ${c.year || "N/A"}`).join("\n")}

Activities (${activities.length} total):
${activities.map((a) => `- ${a.name} (${a.category || "other"}) — Role: ${a.role || "N/A"}, Hours/week: ${a.hours_per_week || "N/A"}, Years: ${a.years_active?.join(",") || "N/A"}, Depth: ${a.depth_tier || "N/A"}\n  Impact: ${a.impact_description || "N/A"}`).join("\n")}`;

    const systemPrompt = `You are a college admissions profile analyst for IvyPi, a college consulting firm. Generate a comprehensive 6-dimension student profile analysis.

Return ONLY valid JSON with this exact structure:
{
  "academic_rigor": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing their academic trajectory, course selection, and rigor",
    "recommendation": "1-2 sentences of actionable advice"
  },
  "extracurricular_depth": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing breadth vs. depth of activities",
    "recommendation": "1-2 sentences of actionable advice"
  },
  "leadership": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing leadership roles and initiative",
    "recommendation": "1-2 sentences of actionable advice"
  },
  "community_impact": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing community service and social impact",
    "recommendation": "1-2 sentences of actionable advice"
  },
  "intellectual_curiosity": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing intellectual growth and academic passion",
    "recommendation": "1-2 sentences of actionable advice"
  },
  "narrative_coherence": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences on how well the student's story comes together — do activities, academics, and interests tell a cohesive story?",
    "recommendation": "1-2 sentences of actionable advice for strengthening their narrative"
  }
}

Tier definitions:
- Compelling: Exceptional — would stand out at any university. National/international recognition, clear passion.
- Strong: Above average — competitive for top 30. Clear strengths and trajectory.
- Developing: On track but needs refinement. Good foundation with room for growth.
- Emerging: Early stage — significant development needed. Building blocks present.

Be honest but constructive. Focus on growth opportunities, not deficiencies.`;

    const response = await callClaude(systemPrompt, studentContext, 4096);
    const insights = parseJsonResponse<Record<string, unknown>>(response);

    // Save to student record
    await supabase
      .from("students")
      .update({ profile_insights: insights })
      .eq("id", student_id);

    return new Response(
      JSON.stringify({ message: "Profile generated successfully" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("generate-profile error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
