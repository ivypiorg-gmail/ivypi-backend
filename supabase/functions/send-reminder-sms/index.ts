import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
    const twilioAccountSid = Deno.env.get("TWILIO_ACCOUNT_SID")!;
    const twilioAuthToken = Deno.env.get("TWILIO_AUTH_TOKEN")!;
    const twilioPhoneNumber = Deno.env.get("TWILIO_PHONE_NUMBER")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Find bookings starting in 25–35 min (10-min window, pairs with 5-min cron)
    const now = new Date();
    const windowStart = new Date(now.getTime() + 25 * 60 * 1000);
    const windowEnd = new Date(now.getTime() + 35 * 60 * 1000);

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
      // Idempotency check: see if a reminder_30m SMS was already sent for this booking
      const { data: existingLog } = await supabase
        .from("notifications_log")
        .select("id")
        .eq("booking_id", booking.id)
        .eq("type", "reminder_30m")
        .eq("channel", "sms")
        .limit(1);

      if (existingLog && existingLog.length > 0) {
        continue; // Already sent, skip
      }

      // Fetch client (student_parent) and counselor profiles
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

      // Only send to student_parent clients with a phone number
      if (client.role !== "student_parent" || !client.phone) {
        continue;
      }

      const appointmentDate = new Date(booking.starts_at);
      const formattedTime = appointmentDate.toLocaleTimeString("en-US", {
        hour: "numeric",
        minute: "2-digit",
        hour12: true,
      });

      const messageBody =
        `IvyPi Reminder: Your session with ${counselor.full_name} starts in 30 minutes (${formattedTime}). See you soon!`;

      // Send SMS via Twilio REST API
      const twilioUrl =
        `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;

      const smsRes = await fetch(twilioUrl, {
        method: "POST",
        headers: {
          Authorization: "Basic " + btoa(`${twilioAccountSid}:${twilioAuthToken}`),
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          From: twilioPhoneNumber,
          To: client.phone,
          Body: messageBody,
        }).toString(),
      });

      if (!smsRes.ok) {
        console.error(
          `Failed to send SMS for booking ${booking.id}:`,
          await smsRes.text(),
        );
        continue;
      }

      // Log the reminder
      const { error: logError } = await supabase
        .from("notifications_log")
        .insert({
          booking_id: booking.id,
          recipient_id: client.id,
          recipient: client.phone,
          type: "reminder_30m",
          channel: "sms",
          status: "sent",
        });

      if (logError) {
        console.error(
          `Failed to log SMS reminder for booking ${booking.id}:`,
          logError.message,
        );
      }

      remindersSent++;
    }

    return new Response(
      JSON.stringify({ success: true, reminders_sent: remindersSent }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-reminder-sms error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
