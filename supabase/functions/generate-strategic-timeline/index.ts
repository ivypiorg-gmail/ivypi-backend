import { createEdgeHandler, jsonResponse, type EdgeContext } from "../_shared/edge-middleware.ts";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";
import { trackAIUsage } from "../_shared/cost-tracking.ts";

const SYSTEM_PROMPT = `You are a senior college admissions strategist. Given a student's deadline set, college list, and profile context, produce a strategic timeline analysis.

Output ONLY valid JSON with this structure:
{
  "narrative_brief": "2-3 paragraphs written for counselor-to-parent communication. Summarize the strategic situation: pressure points, timing conflicts, and overall recommendation. Reference specific schools and dates. Clear enough to share in a meeting.",
  "sequenced_tasks": [
    {
      "title": "Action description",
      "due_date": "YYYY-MM-DD",
      "school_name": "School Name",
      "reasoning": "Why this date matters — include non-obvious dependencies like processing times, lead times, strategic considerations",
      "depends_on": "What must be done first, or null"
    }
  ],
  "risk_flags": [
    {
      "severity": "high",
      "description": "What could go wrong",
      "affected_schools": ["School A", "School B"],
      "recommendation": "Specific action to mitigate"
    }
  ]
}

Guidelines:
- Risk flags are HIGH-IMPORTANCE ONLY — deadline clusters, missing prerequisites, strategic conflicts. Do not flag routine items.
- Sequenced tasks should include non-obvious dependencies (rec letter lead times, financial aid processing windows), not just "submit by deadline".
- The narrative brief should be qualitative, not scored. No numeric rankings or percentages.
- Reference specific schools, dates, and deadlines — no generic advice.`;

async function resetStatus(ctx: EdgeContext, studentId: string) {
  await ctx.supabase
    .from("strategic_timelines")
    .update({ status: "failed" })
    .eq("student_id", studentId);
}

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx: EdgeContext) => {
      const { student_id } = ctx.body as { student_id: string };

      if (!student_id) return jsonResponse({ error: "student_id is required" }, 400);

      // Concurrency guard: claim the generation lock
      const { data: existing } = await ctx.supabase
        .from("strategic_timelines")
        .select("id, status")
        .eq("student_id", student_id)
        .maybeSingle();

      if (existing?.status === "generating") {
        return jsonResponse({ error: "Timeline generation already in progress" }, 409);
      }

      if (existing) {
        const { data: claimed } = await ctx.supabase
          .from("strategic_timelines")
          .update({ status: "generating" })
          .eq("student_id", student_id)
          .in("status", ["idle", "failed"])
          .select("id")
          .maybeSingle();

        if (!claimed) {
          return jsonResponse({ error: "Timeline generation already in progress" }, 409);
        }
      } else {
        await ctx.supabase.from("strategic_timelines").insert({
          student_id,
          status: "generating",
        });
      }

      try {
        // Fetch student's deadlines
        const { data: deadlines } = await ctx.supabase
          .from("student_deadlines")
          .select("*")
          .eq("student_id", student_id)
          .eq("status", "pending")
          .order("due_date");

        // Fetch college list
        const { data: colleges } = await ctx.supabase
          .from("college_lists")
          .select("school_name, app_status")
          .eq("student_id", student_id);

        // Fetch narrative arc (optional) — arc is a single JSONB column
        const { data: narrativeArc } = await ctx.supabase
          .from("narrative_arcs")
          .select("arc")
          .eq("student_id", student_id)
          .eq("status", "idle")
          .maybeSingle();

        // Fetch action items
        const { data: student } = await ctx.supabase
          .from("students")
          .select("full_name, counselor_id")
          .eq("id", student_id)
          .single();

        const { data: actionItems } = student?.counselor_id
          ? await ctx.supabase
              .from("action_items")
              .select("title, due_date, status")
              .eq("counselor_id", student.counselor_id)
              .in("status", ["open", "in_progress"])
          : { data: [] };

        // Build context for Claude
        const userContent = JSON.stringify({
          student_name: student?.full_name ?? "Student",
          deadlines: (deadlines ?? []).map((d: Record<string, unknown>) => ({
            school: d.school_name,
            type: d.deadline_type,
            due: d.due_date,
            title: d.title,
          })),
          college_list: (colleges ?? []).map((c: Record<string, unknown>) => ({
            school: c.school_name,
            status: c.app_status,
          })),
          narrative_arc: narrativeArc?.arc ? {
            throughlines: narrativeArc.arc.throughlines,
            identity_frames: narrativeArc.arc.identity_frames,
            brief: narrativeArc.arc.counselor_brief,
          } : null,
          open_action_items: (actionItems ?? []).map((ai: Record<string, unknown>) => ({
            title: ai.title,
            due: ai.due_date,
          })),
        });

        const result = await callClaude(SYSTEM_PROMPT, userContent, 4096);

        await trackAIUsage(ctx.supabase, {
          function_name: "generate-strategic-timeline",
          result,
          student_id,
          caller_id: ctx.callerId,
        });

        const parsed = parseJsonResponse<{
          narrative_brief?: string;
          risk_flags?: unknown[];
          sequenced_tasks?: unknown[];
        }>(result.text);

        await ctx.supabase
          .from("strategic_timelines")
          .update({
            narrative_brief: parsed.narrative_brief ?? null,
            risk_flags: parsed.risk_flags ?? [],
            sequenced_tasks: parsed.sequenced_tasks ?? [],
            status: "idle",
            stale: false,
            generated_at: new Date().toISOString(),
          })
          .eq("student_id", student_id);

        return { success: true };
      } catch (err) {
        await resetStatus(ctx, student_id);
        throw err;
      }
    },
  }),
);
