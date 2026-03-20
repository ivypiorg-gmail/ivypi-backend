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

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx: EdgeContext) => {
      const { school_names, cycle_year } = ctx.body as {
        school_names?: string[];
        cycle_year: number;
      };

      if (!cycle_year) return jsonResponse({ error: "cycle_year is required" }, 400);

      // Get school list — either provided or all from universities table
      let schools: string[];
      if (school_names && school_names.length > 0) {
        schools = school_names;
      } else {
        const { data } = await ctx.supabase.from("universities").select("name");
        schools = (data ?? []).map((u: { name: string }) => u.name);
      }

      let seeded = 0;
      let skipped = 0;

      for (const school of schools) {
        // Check if already seeded
        const { data: existing } = await ctx.supabase
          .from("school_deadlines")
          .select("id")
          .eq("school_name", school)
          .eq("cycle_year", cycle_year)
          .limit(1);

        if (existing && existing.length > 0) {
          skipped++;
          continue;
        }

        const result = await callClaude(
          SEED_PROMPT,
          `University: ${school}\nCycle year: ${cycle_year}`,
          2048,
        );

        await trackAIUsage(ctx.supabase, {
          function_name: "seed-school-deadlines",
          result,
          caller_id: ctx.callerId,
          metadata: { school, cycle_year },
        });

        try {
          const parsed = parseJsonResponse<{ deadlines: { type: string; date: string; description?: string }[] }>(result.text);
          const deadlines = parsed.deadlines ?? [];

          const rows = deadlines.map((d: { type: string; date: string; description?: string }) => ({
            school_name: school,
            deadline_type: d.type,
            deadline_date: d.date,
            description: d.description ?? null,
            cycle_year,
            verified: false,
          }));

          if (rows.length > 0) {
            const { error } = await ctx.supabase
              .from("school_deadlines")
              .upsert(rows, { onConflict: "school_name,deadline_type,cycle_year", ignoreDuplicates: true });

            if (!error) seeded++;
            else console.error(`Error seeding ${school}:`, error.message);
          }
        } catch (e) {
          console.error(`Failed to parse deadlines for ${school}:`, e);
        }
      }

      return { seeded, skipped, total: schools.length };
    },
  }),
);
