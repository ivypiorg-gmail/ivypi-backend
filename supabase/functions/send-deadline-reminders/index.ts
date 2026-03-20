import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { deadlineReminder7d, deadlineReminder2d } from "../_shared/email-templates.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const today = new Date();
    const in7d = new Date(today.getTime() + 7 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];
    const in2d = new Date(today.getTime() + 2 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];

    const windows = [
      { date: in7d, type: "deadline_reminder_7d" as const, template: deadlineReminder7d },
      { date: in2d, type: "deadline_reminder_2d" as const, template: deadlineReminder2d },
    ];

    let sent = 0;

    for (const window of windows) {
      const { data: deadlines } = await supabase
        .from("student_deadlines")
        .select("id, student_id, title, school_name, deadline_type, due_date")
        .eq("due_date", window.date)
        .eq("status", "pending");

      if (!deadlines || deadlines.length === 0) continue;

      for (const deadline of deadlines) {
        // Idempotency check
        const { data: existingLog } = await supabase
          .from("notifications_log")
          .select("id")
          .eq("student_deadline_id", deadline.id)
          .eq("type", window.type)
          .eq("channel", "email")
          .limit(1);

        if (existingLog && existingLog.length > 0) continue;

        // Fetch student -> parent
        const { data: student } = await supabase
          .from("students")
          .select("user_id, counselor_id, full_name")
          .eq("id", deadline.student_id)
          .single();

        if (!student) continue;

        // Fetch parent profile (if exists)
        const parentId = student.user_id;
        const counselorId = student.counselor_id;

        let parentEmail: string | null = null;
        let parentName = "Parent";
        let counselorEmail: string | null = null;

        if (parentId) {
          const { data: parentProfile } = await supabase
            .from("profiles")
            .select("email, full_name")
            .eq("id", parentId)
            .single();
          parentEmail = parentProfile?.email ?? null;
          parentName = parentProfile?.full_name ?? "Parent";
        }

        if (counselorId) {
          const { data: counselorProfile } = await supabase
            .from("profiles")
            .select("email")
            .eq("id", counselorId)
            .single();
          counselorEmail = counselorProfile?.email ?? null;
        }

        // Must have at least one recipient
        const to = parentEmail ? [parentEmail] : counselorEmail ? [counselorEmail] : null;
        if (!to) continue;

        const cc = parentEmail && counselorEmail ? [counselorEmail] : undefined;
        const dueDate = new Date(deadline.due_date).toLocaleDateString("en-US", {
          weekday: "long", month: "long", day: "numeric", year: "numeric",
        });

        const html = window.template(
          parentName,
          student.full_name,
          deadline.school_name ?? "Unknown School",
          deadline.deadline_type ?? "deadline",
          dueDate,
        );

        const subject = window.type === "deadline_reminder_7d"
          ? `Upcoming deadline: ${deadline.school_name} — due ${dueDate}`
          : `Due in 2 days: ${deadline.school_name} ${deadline.deadline_type?.replace(/_/g, " ") ?? "deadline"}`;

        await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${resendApiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            from: "IvyPi Deadlines <noreply@ivypi.org>",
            to,
            cc,
            subject,
            html,
          }),
        });

        // Log
        await supabase.from("notifications_log").insert({
          student_deadline_id: deadline.id,
          type: window.type,
          channel: "email",
          recipient: to[0],
          recipient_id: parentId ?? counselorId,
          status: "sent",
        });

        sent++;
      }
    }

    return new Response(
      JSON.stringify({ success: true, sent }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-deadline-reminders error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
