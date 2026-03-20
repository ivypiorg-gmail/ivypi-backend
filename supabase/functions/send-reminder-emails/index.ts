import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { reminderClient, reminderCounselor } from "../_shared/email-templates.ts";

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

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Find bookings starting in 23-25 hours with status 'confirmed'
    const now = new Date();
    const windowStart = new Date(now.getTime() + 23 * 60 * 60 * 1000);
    const windowEnd = new Date(now.getTime() + 25 * 60 * 60 * 1000);

    const { data: bookings, error: bookingsError } = await supabase
      .from("bookings")
      .select("*")
      .eq("status", "confirmed")
      .gte("starts_at", windowStart.toISOString())
      .lte("starts_at", windowEnd.toISOString());

    if (bookingsError) {
      throw new Error(`Failed to query bookings: ${bookingsError.message}`);
    }

    if (!bookings || bookings.length === 0) {
      return new Response(
        JSON.stringify({ success: true, reminders_sent: 0 }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    let remindersSent = 0;

    for (const booking of bookings) {
      // Idempotency check: see if a reminder_24h was already sent for this booking
      const { data: existingLog } = await supabase
        .from("notifications_log")
        .select("id")
        .eq("booking_id", booking.id)
        .eq("type", "reminder_24h")
        .limit(1);

      if (existingLog && existingLog.length > 0) {
        continue; // Already sent, skip
      }

      // Fetch client and counselor profiles
      const [clientResult, counselorResult] = await Promise.all([
        supabase.from("profiles").select("*").eq("id", booking.client_id).single(),
        supabase.from("profiles").select("*").eq("id", booking.counselor_id).single(),
      ]);

      if (clientResult.error || !clientResult.data || counselorResult.error || !counselorResult.data) {
        console.error(
          `Skipping booking ${booking.id}: missing profile(s)`,
          clientResult.error?.message,
          counselorResult.error?.message,
        );
        continue;
      }

      const client = clientResult.data;
      const counselor = counselorResult.data;

      const appointmentDate = new Date(booking.starts_at);
      const formattedDate = appointmentDate.toLocaleDateString("en-US", {
        weekday: "long",
        year: "numeric",
        month: "long",
        day: "numeric",
      });
      const formattedTime = appointmentDate.toLocaleTimeString("en-US", {
        hour: "numeric",
        minute: "2-digit",
        hour12: true,
      });

      // Send reminder to client
      const clientEmailRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendApiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: "IvyPi Scheduling <noreply@ivypi.org>",
          to: [client.email],
          subject: "Reminder: Upcoming Session Tomorrow - IvyPi",
          html: reminderClient(client.full_name, counselor.full_name, formattedDate, formattedTime),
        }),
      });

      if (!clientEmailRes.ok) {
        console.error(`Failed to send client reminder for booking ${booking.id}:`, await clientEmailRes.text());
        continue;
      }

      // Send reminder to counselor
      const counselorEmailRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendApiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: "IvyPi Scheduling <noreply@ivypi.org>",
          to: [counselor.email],
          subject: "Reminder: Upcoming Session Tomorrow - IvyPi",
          html: reminderCounselor(counselor.full_name, client.full_name, formattedDate, formattedTime),
        }),
      });

      if (!counselorEmailRes.ok) {
        console.error(`Failed to send counselor reminder for booking ${booking.id}:`, await counselorEmailRes.text());
        continue;
      }

      // Log both reminders
      const { error: logError } = await supabase
        .from("notifications_log")
        .insert([
          {
            booking_id: booking.id,
            recipient_id: client.id,
            recipient: client.email,
            type: "reminder_24h",
            channel: "email",
            status: "sent",
          },
          {
            booking_id: booking.id,
            recipient_id: counselor.id,
            recipient: counselor.email,
            type: "reminder_24h",
            channel: "email",
            status: "sent",
          },
        ]);

      if (logError) {
        console.error(`Failed to log reminders for booking ${booking.id}:`, logError.message);
      }

      remindersSent++;
    }

    return new Response(
      JSON.stringify({ success: true, reminders_sent: remindersSent }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-reminder-emails error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
