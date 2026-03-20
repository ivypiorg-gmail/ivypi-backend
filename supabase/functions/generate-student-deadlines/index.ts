import { createEdgeHandler, jsonResponse, type EdgeContext } from "../_shared/edge-middleware.ts";

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx: EdgeContext) => {
      const { student_id } = ctx.body as { student_id: string };

      if (!student_id) return jsonResponse({ error: "student_id is required" }, 400);

      // Determine current cycle year (applications filed in fall for next year's enrollment)
      const now = new Date();
      const cycleYear = now.getMonth() >= 7 ? now.getFullYear() + 1 : now.getFullYear();

      // Fetch student's active college list entries
      const { data: collegeEntries } = await ctx.supabase
        .from("college_lists")
        .select("school_name, app_status")
        .eq("student_id", student_id)
        .in("app_status", ["considering", "applying"]);

      const activeSchools = (collegeEntries ?? []).map((e: { school_name: string }) => e.school_name);

      // Fetch matching school deadlines
      const { data: schoolDeadlines } = activeSchools.length > 0
        ? await ctx.supabase
            .from("school_deadlines")
            .select("*")
            .in("school_name", activeSchools)
            .eq("cycle_year", cycleYear)
        : { data: [] };

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

      // Build upsert rows
      const newRows = (schoolDeadlines ?? [])
        .filter((sd: { school_name: string; deadline_type: string }) => {
          const key = `${sd.school_name}|${sd.deadline_type}`;
          return !existingByKey.has(key);
        })
        .map((sd: { id: string; school_name: string; deadline_type: string; deadline_date: string; description: string | null }) => ({
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
          d.school_deadline_id && // only auto-generated (not custom)
          d.school_name &&
          !activeSchools.includes(d.school_name) &&
          d.status === "pending", // don't remove submitted/missed
      );

      for (const d of existingToRemove) {
        await ctx.supabase.from("student_deadlines").delete().eq("id", (d as { id: string }).id);
      }

      // Mark strategic timeline as stale (trigger also does this, but belt-and-suspenders)
      await ctx.supabase
        .from("strategic_timelines")
        .update({ stale: true })
        .eq("student_id", student_id);

      return { added: newRows.length, removed: existingToRemove.length };
    },
  }),
);
