import { createEdgeHandler } from "../_shared/edge-middleware.ts";
import { callClaude, parseJsonResponse } from "../_shared/ai-helpers.ts";

interface SqlAlert {
  alert_type: string;
  severity: string;
  title: string;
  description: string;
  student_ids: string[];
  school_names: string[];
}

interface ClaudeConflictEnrichment {
  alert_index: number;
  recommendation: string;
  suggested_scenarios: { student_id: string; title: string; modifications: { type: string; description: string; details: Record<string, string> }[] }[];
}

interface ClaudeNewAlert {
  alert_type: string;
  severity: string;
  title: string;
  description: string;
  student_ids: string[];
  school_names: string[];
  recommendation: string;
  suggested_scenarios: { student_id: string; title: string; modifications: { type: string; description: string; details: Record<string, string> }[] }[];
}

interface ClaudeResponse {
  conflict_enrichments: ClaudeConflictEnrichment[];
  new_alerts: ClaudeNewAlert[];
}

Deno.serve(
  createEdgeHandler({
    requireRole: ["counselor", "admin"],
    handler: async (ctx) => {
      const counselorId = ctx.callerId;

      // Phase 1: SQL detection
      const { data: sqlAlerts, error: sqlError } = await ctx.supabase.rpc(
        "detect_portfolio_alerts",
        { p_counselor_id: counselorId }
      );

      if (sqlError) throw new Error(`SQL detection failed: ${sqlError.message}`);

      const alerts: SqlAlert[] = sqlAlerts ?? [];

      // Clean up previous undismissed alerts not referenced by any scenario
      const { data: referencedAlertIds } = await ctx.supabase
        .from("scenarios")
        .select("source_alert_id")
        .not("source_alert_id", "is", null);

      const referencedIds = (referencedAlertIds ?? [])
        .map((r: { source_alert_id: string }) => r.source_alert_id)
        .filter(Boolean);

      let deleteQuery = ctx.supabase
        .from("portfolio_alerts")
        .delete()
        .eq("counselor_id", counselorId)
        .is("dismissed_at", null);

      if (referencedIds.length > 0) {
        deleteQuery = deleteQuery.not("id", "in", `(${referencedIds.join(",")})`);
      }

      await deleteQuery;

      // Write SQL alerts immediately
      const sqlInserts = alerts.map((a: SqlAlert) => ({
        counselor_id: counselorId,
        alert_type: a.alert_type,
        severity: a.severity,
        title: a.title,
        description: a.description,
        student_ids: a.student_ids,
        school_names: a.school_names,
        recommendation: null,
        alert_scenarios: [],
        generated_at: new Date().toISOString(),
      }));

      if (sqlInserts.length > 0) {
        const { error: insertError } = await ctx.supabase
          .from("portfolio_alerts")
          .insert(sqlInserts);
        if (insertError) throw new Error(`Insert SQL alerts failed: ${insertError.message}`);
      }

      // Phase 2: AI enrichment
      // Collect all student IDs referenced in SQL alerts
      const flaggedStudentIds = new Set<string>();
      alerts.forEach((a: SqlAlert) => a.student_ids.forEach((id: string) => flaggedStudentIds.add(id)));

      // Fetch all active students for caseload summary
      const { data: allStudents } = await ctx.supabase
        .from("students")
        .select("id, full_name, profile_insights, status")
        .eq("counselor_id", counselorId)
        .eq("status", "active");

      const activeStudents = allStudents ?? [];

      // Fetch narrative arc identity frames and throughline titles for flagged students
      const flaggedIds = Array.from(flaggedStudentIds);
      let narrativeData: { student_id: string; arc: { identity_frames?: { key: string; title: string; pitch: string; best_for: string[] }[]; throughlines?: { key: string; title: string }[] } }[] = [];

      if (flaggedIds.length > 0) {
        const { data: arcs } = await ctx.supabase
          .from("narrative_arcs")
          .select("student_id, arc")
          .in("student_id", flaggedIds);
        narrativeData = arcs ?? [];
      }

      // Fetch top 3 schools per student
      const { data: allColleges } = await ctx.supabase
        .from("college_lists")
        .select("student_id, school_name, app_status, app_round")
        .in(
          "student_id",
          activeStudents.map((s: { id: string }) => s.id)
        );

      const collegesByStudent = new Map<string, { school_name: string; app_status: string; app_round: string | null }[]>();
      (allColleges ?? []).forEach((c: { student_id: string; school_name: string; app_status: string; app_round: string | null }) => {
        if (!collegesByStudent.has(c.student_id)) collegesByStudent.set(c.student_id, []);
        collegesByStudent.get(c.student_id)!.push(c);
      });

      const narrativeByStudent = new Map<string, typeof narrativeData[0]["arc"]>();
      narrativeData.forEach((n) => narrativeByStudent.set(n.student_id, n.arc));

      // Build Claude prompt
      const conflictsSection = alerts
        .map((a: SqlAlert, i: number) => {
          const studentDetails = a.student_ids.map((sid: string) => {
            const s = activeStudents.find((st: { id: string }) => st.id === sid);
            const arc = narrativeByStudent.get(sid);
            const frames = arc?.identity_frames?.map((f: { title: string }) => f.title).join(", ") ?? "none";
            const threads = arc?.throughlines?.map((t: { title: string }) => t.title).join(", ") ?? "none";
            return `  - ${s?.full_name ?? sid}: identity frames=[${frames}], throughlines=[${threads}]`;
          }).join("\n");
          return `Alert ${i}: ${a.alert_type} — ${a.title}\n${a.description}\n${studentDetails}`;
        })
        .join("\n\n");

      const caseloadSection = activeStudents
        .map((s: { id: string; full_name: string; profile_insights: Record<string, { tier: string }> | null }) => {
          const colleges = collegesByStudent.get(s.id) ?? [];
          const top3 = colleges.slice(0, 3).map((c: { school_name: string; app_round: string | null }) =>
            `${c.school_name}${c.app_round ? ` (${c.app_round})` : ""}`
          ).join(", ");
          const arc = narrativeByStudent.get(s.id);
          const frame = arc?.identity_frames?.[0]?.title ?? "none";
          return `- ${s.full_name}: schools=[${top3}], primary frame="${frame}"`;
        })
        .join("\n");

      const systemPrompt = `You are a strategic admissions counselor reviewing your caseload for conflicts and opportunities.

Respond with JSON only: {
  "conflict_enrichments": [{ "alert_index": <number>, "recommendation": "<text>", "suggested_scenarios": [{ "student_id": "<uuid>", "title": "<text>", "modifications": [{ "type": "add_course|add_activity|drop_activity|improve_test_score", "description": "<text>", "details": { ... } }] }] }],
  "new_alerts": [{ "alert_type": "positioning_collision|opportunity|timing_risk", "severity": "high|medium|low", "title": "<text>", "description": "<text>", "student_ids": ["<uuid>"], "school_names": ["<text>"], "recommendation": "<text>", "suggested_scenarios": [{ "student_id": "<uuid>", "title": "<text>", "modifications": [...] }] }]
}`;

      const userContent = `FLAGGED CONFLICTS (from database):
${conflictsSection || "None detected."}

FULL CASELOAD SUMMARY (${activeStudents.length} students):
${caseloadSection}

Tasks:
1. For each flagged conflict: assess which student has the stronger positioning for that school and why. Recommend specific pivots with concrete scenario modifications.
2. Scan the full caseload for:
   - Positioning collisions: students with similar identity frames targeting similar school types who need differentiation
   - Opportunities: schools that fit a student's profile but aren't on their list
   - Timing risks: strategic sequencing issues not captured by deadline dates alone`;

      const result = await callClaude(systemPrompt, userContent, 4096);
      const parsed = parseJsonResponse<ClaudeResponse>(result.text);

      // Apply conflict enrichments to existing SQL alerts
      if (parsed.conflict_enrichments?.length) {
        // Fetch the SQL alerts we just inserted (ordered by created_at to match index)
        const { data: insertedAlerts } = await ctx.supabase
          .from("portfolio_alerts")
          .select("id, alert_type, title")
          .eq("counselor_id", counselorId)
          .is("dismissed_at", null)
          .in("alert_type", ["ed_conflict", "school_overlap", "deadline_cluster"])
          .order("created_at", { ascending: true });

        for (const enrichment of parsed.conflict_enrichments) {
          const alert = (insertedAlerts ?? [])[enrichment.alert_index];
          if (alert) {
            await ctx.supabase
              .from("portfolio_alerts")
              .update({
                recommendation: enrichment.recommendation,
                alert_scenarios: enrichment.suggested_scenarios ?? [],
              })
              .eq("id", alert.id);
          }
        }
      }

      // Insert AI-detected alerts
      const validAlertTypes = ["positioning_collision", "opportunity", "timing_risk"];
      const validSeverities = ["high", "medium", "low"];
      const aiInserts = (parsed.new_alerts ?? [])
        .filter(
          (a: ClaudeNewAlert) =>
            validAlertTypes.includes(a.alert_type) && validSeverities.includes(a.severity)
        )
        .map((a: ClaudeNewAlert) => ({
          counselor_id: counselorId,
          alert_type: a.alert_type,
          severity: a.severity,
          title: a.title,
          description: a.description,
          student_ids: a.student_ids,
          school_names: a.school_names ?? [],
          recommendation: a.recommendation,
          alert_scenarios: a.suggested_scenarios ?? [],
          generated_at: new Date().toISOString(),
        }));

      if (aiInserts.length > 0) {
        await ctx.supabase.from("portfolio_alerts").insert(aiInserts);
      }

      // Fetch all current alerts to return
      const { data: allAlerts } = await ctx.supabase
        .from("portfolio_alerts")
        .select("*")
        .eq("counselor_id", counselorId)
        .is("dismissed_at", null)
        .order("severity", { ascending: true })
        .order("generated_at", { ascending: false });

      return {
        success: true,
        alerts: allAlerts ?? [],
        usage: result.usage,
      };
    },
  })
);
