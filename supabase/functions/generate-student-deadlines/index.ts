import { createEdgeHandler, jsonResponse, type EdgeContext } from "../_shared/edge-middleware.ts";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

const SEED_PROMPT = `You are a college admissions data assistant. Given a university name and application cycle year, output the known application deadlines as a JSON array.

Include only deadlines you are confident about. For each deadline provide:
- type: one of "early_decision", "early_decision_2", "early_action", "restrictive_early_action", "regular_decision", "css_profile", "fafsa", "scholarship", "supplement", "interview", "recommendation"
- date: ISO date string (YYYY-MM-DD)
- description: brief description

Common anchor dates for reference:
- Common App RD deadline: typically January 1
- FAFSA opens: October 1
- Most ED deadlines: November 1 or November 15
- Most EA deadlines: November 1 or November 15
- Most RD deadlines: January 1 or January 15

Output ONLY valid JSON: { "deadlines": [...] }`;

async function seedSchoolDeadlines(
  supabase: EdgeContext["supabase"],
  school: string,
  cycleYear: number,
  callerId?: string,
): Promise<void> {
  try {
    const result = await callClaude(
      SEED_PROMPT,
      `University: ${school}\nCycle year: ${cycleYear}`,
      2048,
    );

    await trackAIUsage(supabase, {
      function_name: "generate-student-deadlines:auto-seed",
      result,
      caller_id: callerId,
      metadata: { school, cycle_year: cycleYear },
    });

    const parsed = parseJsonResponse<{
      deadlines: { type: string; date: string; description?: string }[];
    }>(result.text);
    const deadlines = parsed.deadlines ?? [];

    const rows = deadlines.map((d) => ({
      school_name: school,
      deadline_type: d.type,
      deadline_date: d.date,
      description: d.description ?? null,
      cycle_year: cycleYear,
      verified: false,
    }));

    if (rows.length > 0) {
      await supabase
        .from("school_deadlines")
        .upsert(rows, { onConflict: "school_name,deadline_type,cycle_year", ignoreDuplicates: true });
    }
  } catch (e) {
    console.error(`Failed to auto-seed deadlines for ${school}:`, e);
  }
}

Deno.serve(
  createEdgeHandler({
    requireAuth: true,
    handler: async (ctx: EdgeContext) => {
      const { student_id } = ctx.body as { student_id: string };

      if (!student_id) return jsonResponse({ error: "student_id is required" }, 400);

      // Fetch student for cycle year and access check
      const { data: student } = await ctx.supabase
        .from("students")
        .select("application_cycle, grad_year, counselor_id, user_id")
        .eq("id", student_id)
        .single();

      if (!student) return jsonResponse({ error: "Student not found" }, 404);

      // Fetch caller's role (requireAuth doesn't populate callerRole)
      const { data: callerProfile } = await ctx.supabase
        .from("profiles")
        .select("role")
        .eq("id", ctx.callerId)
        .single();
      const callerRole = callerProfile?.role;

      // Access check: caller must be the counselor, parent, or admin
      if (callerRole !== "admin") {
        const isParent = student.user_id === ctx.callerId;
        const isCounselor = student.counselor_id === ctx.callerId;
        if (!isParent && !isCounselor) {
          return jsonResponse({ error: "Not authorized for this student" }, 403);
        }
      }

      // Resolve cycle year from student profile
      const cycleYear = student.application_cycle ?? student.grad_year;
      if (!cycleYear) {
        return { added: 0, removed: 0, skipped: "no_cycle_year" };
      }

      // Fetch student's active college list entries
      const { data: collegeEntries } = await ctx.supabase
        .from("college_lists")
        .select("school_name, app_status")
        .eq("student_id", student_id)
        .in("app_status", ["considering", "applying"]);

      const activeSchools = (collegeEntries ?? []).map((e: { school_name: string }) => e.school_name);

      if (activeSchools.length === 0) {
        return { added: 0, removed: 0 };
      }

      // Check which schools need seeding (no entries in school_deadlines for this cycle)
      const { data: existingSchoolDeadlines } = await ctx.supabase
        .from("school_deadlines")
        .select("school_name")
        .in("school_name", activeSchools)
        .eq("cycle_year", cycleYear);

      const schoolsWithDeadlines = new Set(
        (existingSchoolDeadlines ?? []).map((d: { school_name: string }) => d.school_name)
      );

      const schoolsNeedingSeeding = activeSchools.filter((s) => !schoolsWithDeadlines.has(s));

      // Auto-seed missing schools in parallel (max 5 concurrent)
      if (schoolsNeedingSeeding.length > 0) {
        const toSeed = schoolsNeedingSeeding.slice(0, 5);
        await Promise.all(
          toSeed.map((school) => seedSchoolDeadlines(ctx.supabase, school, cycleYear, ctx.callerId))
        );
      }

      // Now fetch all matching school deadlines (including freshly seeded ones)
      const { data: schoolDeadlines } = await ctx.supabase
        .from("school_deadlines")
        .select("*")
        .in("school_name", activeSchools)
        .eq("cycle_year", cycleYear);

      // Fetch existing student deadlines to preserve status/notes
      const { data: existingDeadlines } = await ctx.supabase
        .from("student_deadlines")
        .select("id, school_deadline_id, school_name, deadline_type, status, notes, priority")
        .eq("student_id", student_id);

      const existingByKey = new Map(
        (existingDeadlines ?? []).map((d: { school_name: string | null; deadline_type: string | null; id: string }) => [
          `${d.school_name}|${d.deadline_type}`, d,
        ]),
      );

      // Build new rows (only for deadlines not already tracked)
      const newRows = (schoolDeadlines ?? [])
        .filter((sd: { school_name: string; deadline_type: string }) => {
          const key = `${sd.school_name}|${sd.deadline_type}`;
          return !existingByKey.has(key);
        })
        .map((sd: { id: string; school_name: string; deadline_type: string; deadline_date: string }) => ({
          student_id,
          school_deadline_id: sd.id,
          title: `${sd.school_name} — ${sd.deadline_type.replace(/_/g, " ").replace(/\b\w/g, (c: string) => c.toUpperCase())}`,
          due_date: sd.deadline_date,
          status: "pending",
          deadline_type: sd.deadline_type,
          school_name: sd.school_name,
        }));

      if (newRows.length > 0) {
        await ctx.supabase.from("student_deadlines").insert(newRows);
      }

      // Remove deadlines for schools no longer on the list (only auto-generated ones)
      const existingToRemove = (existingDeadlines ?? []).filter(
        (d: { school_name: string | null; school_deadline_id: string | null; status: string }) =>
          d.school_deadline_id &&
          d.school_name &&
          !activeSchools.includes(d.school_name) &&
          d.status === "pending",
      );

      for (const d of existingToRemove) {
        await ctx.supabase.from("student_deadlines").delete().eq("id", (d as { id: string }).id);
      }

      // Mark strategic timeline as stale
      await ctx.supabase
        .from("strategic_timelines")
        .update({ stale: true })
        .eq("student_id", student_id);

      return { added: newRows.length, removed: existingToRemove.length };
    },
  }),
);
