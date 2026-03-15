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
    const body = await req.json();
    const { student_id, school_name } = body;

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

    // Fetch student data
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

    // Fetch schools to generate reports for
    let query = supabase
      .from("college_lists")
      .select("*")
      .eq("student_id", student_id);

    if (school_name) {
      query = query.eq("school_name", school_name);
    }

    const { data: schools, error: schoolsError } = await query;

    if (schoolsError || !schools?.length) {
      return new Response(
        JSON.stringify({ error: "No schools found on college list" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Build student context
    const studentContext = `
Student: ${student.full_name}
High School: ${student.high_school || "Unknown"}
Graduation Year: ${student.grad_year || "Unknown"}
GPA (Unweighted): ${student.gpa_unweighted ?? "N/A"}
GPA (Weighted): ${student.gpa_weighted ?? "N/A"}
Test Scores: ${JSON.stringify(student.test_scores || {})}
Profile Insights: ${JSON.stringify(student.profile_insights || {})}

Courses: ${courses.map((c) => `${c.name} (${c.level}, ${c.grade || "N/A"})`).join("; ")}

Activities: ${activities.map((a) => `${a.name} (${a.category}, ${a.role || "member"}, ${a.depth_tier || "N/A"})`).join("; ")}`;

    // Generate reports for each school
    const schoolNames = schools.map((s) => s.school_name);

    const systemPrompt = `You are a college admissions advisor for IvyPi, a college consulting firm. Generate affinity reports for a student's college list.

For EACH school, analyze how well the student's profile aligns with that school's values, programs, and admissions priorities.

Return ONLY valid JSON with this exact structure:
{
  "reports": {
    "School Name": {
      "strengths": ["2-3 bullet points about why the student is a good fit"],
      "distinctive": ["1-2 bullet points about what makes this student stand out for this school"],
      "growth_areas": ["1-2 bullet points about areas to strengthen for this school"],
      "narrative": "2-3 sentence constructive narrative about the student's fit with this school"
    }
  }
}

Important:
- Do NOT use safety/target/reach labels
- Focus on constructive, actionable insights
- Be school-specific — reference known programs, values, culture
- Be honest but encouraging`;

    const userPrompt = `${studentContext}

Generate affinity reports for these schools: ${schoolNames.join(", ")}`;

    const response = await callClaude(systemPrompt, userPrompt, 8192);
    const parsed = parseJsonResponse<{
      reports: Record<string, {
        strengths: string[];
        distinctive: string[];
        growth_areas: string[];
        narrative: string;
      }>;
    }>(response);

    // Update each school's affinity report
    let updatedCount = 0;
    for (const school of schools) {
      const report = parsed.reports?.[school.school_name];
      if (report) {
        await supabase
          .from("college_lists")
          .update({ affinity_report: report })
          .eq("id", school.id);
        updatedCount++;
      }
    }

    return new Response(
      JSON.stringify({
        message: `Affinity reports generated for ${updatedCount} school(s)`,
        updated: updatedCount,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("generate-affinity error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
