import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { createEdgeHandler, jsonResponse } from "../_shared/edge-middleware.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx) => {
      const { student_id } = ctx.body;
      if (!student_id) {
        return jsonResponse({ error: "student_id is required" }, 400);
      }

      // Fetch all student data
      const [studentRes, coursesRes, activitiesRes, awardsRes] = await Promise.all([
        ctx.supabase.from("students").select("*").eq("id", student_id).single(),
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
      ]);

      if (studentRes.error || !studentRes.data) {
        return jsonResponse({ error: "Student not found" }, 404);
      }

      const student = studentRes.data;
      const courses = coursesRes.data || [];
      const activities = activitiesRes.data || [];
      const awards = awardsRes.data || [];

      // Build context for Claude
      const studentContext = `
Student: ${student.full_name}
High School: ${student.high_school || "Unknown"}
Graduation Year: ${student.grad_year || "Unknown"}
GPA (Unweighted): ${student.gpa_unweighted ?? "N/A"}
GPA (Weighted): ${student.gpa_weighted ?? "N/A"}
Test Scores: ${JSON.stringify(student.test_scores || {})}

Courses (${courses.length} total):
${courses.map((c: { name: string; level?: string; subject_area?: string; grade?: string; year?: string }) => `- ${c.name} (${c.level || "regular"}, ${c.subject_area || "other"}) — Grade: ${c.grade || "N/A"}, Year: ${c.year || "N/A"}`).join("\n")}

Activities (${activities.length} total):
${activities.map((a: { name: string; category?: string; role?: string; hours_per_week?: number; years_active?: number[]; depth_tier?: string; impact_description?: string }) => `- ${a.name} (${a.category || "other"}) — Role: ${a.role || "N/A"}, Hours/week: ${a.hours_per_week || "N/A"}, Years: ${a.years_active?.join(",") || "N/A"}, Depth: ${a.depth_tier || "N/A"}\n  Impact: ${a.impact_description || "N/A"}`).join("\n")}

Awards (${awards.length} total):
${awards.map((w: { title: string; level?: string; category?: string; grade_year?: number; description?: string }) => `- ${w.title} (${w.level || "N/A"}, ${w.category || "N/A"}) — Grade: ${w.grade_year || "N/A"}${w.description ? `\n  ${w.description}` : ""}`).join("\n")}`;

      const systemPrompt = `You are a college admissions profile analyst for IvyPi, a college consulting firm. Generate a comprehensive 6-dimension student profile analysis.

Return ONLY valid JSON with this exact structure:
{
  "academic_rigor": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing their academic trajectory, course selection, and rigor. Use **bold** sparingly — only 1-2 key course names, activity names, or conclusions per dimension.",
    "recommendation": "1-2 sentences of actionable advice",
    "evidence": ["specific course, activity, or award name 1", "specific item 2"]
  },
  "extracurricular_depth": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing breadth vs. depth of activities",
    "recommendation": "1-2 sentences of actionable advice",
    "evidence": ["specific item 1", "specific item 2"]
  },
  "leadership": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing leadership roles and initiative",
    "recommendation": "1-2 sentences of actionable advice",
    "evidence": ["specific item 1", "specific item 2"]
  },
  "community_impact": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing community service and social impact",
    "recommendation": "1-2 sentences of actionable advice",
    "evidence": ["specific item 1", "specific item 2"]
  },
  "intellectual_curiosity": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences analyzing intellectual growth and academic passion",
    "recommendation": "1-2 sentences of actionable advice",
    "evidence": ["specific item 1", "specific item 2"]
  },
  "narrative_coherence": {
    "tier": "Compelling|Strong|Developing|Emerging",
    "narrative": "2-3 sentences on how well the student's story comes together — do activities, academics, and interests tell a cohesive story?",
    "recommendation": "1-2 sentences of actionable advice for strengthening their narrative",
    "evidence": ["specific item 1", "specific item 2"]
  }
}

Each "evidence" array must contain 2-4 specific course names, activity names, or award titles from the student's data that support your assessment for that dimension. Reference actual items from the provided data.

For the "narrative" field, use **bold** markdown sparingly — bold only 1-2 key course/activity names or important conclusions per dimension, not entire sentences.

Tier definitions:
- Compelling: Exceptional — would stand out at any university. National/international recognition, clear passion.
- Strong: Above average — competitive for top 30. Clear strengths and trajectory.
- Developing: On track but needs refinement. Good foundation with room for growth.
- Emerging: Early stage — significant development needed. Building blocks present.

Be honest but constructive. Focus on growth opportunities, not deficiencies.`;

      const result = await callClaude(systemPrompt, studentContext, 4096);
      const insights = parseJsonResponse<Record<string, unknown>>(result.text);

      // Track AI usage
      await trackAIUsage(ctx.supabase, {
        function_name: "generate-profile",
        result,
        student_id: student_id as string,
        caller_id: ctx.callerId,
      });

      // Save to student record and clear staleness flag
      await ctx.supabase
        .from("students")
        .update({ profile_insights: insights, profile_stale: false, profile_insights_generated_at: new Date().toISOString() })
        .eq("id", student_id);

      return { message: "Profile generated successfully" };
    },
  }),
);
