import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cancellationNotice } from "../_shared/email-templates.ts";
import { corsHeaders } from "../_shared/edge-middleware.ts";
import { sendResendEmail } from "../_shared/send-email.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { booking_id, cancelled_by } = await req.json();

    if (!booking_id || !cancelled_by) {
      return new Response(
        JSON.stringify({ error: "booking_id and cancelled_by are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (cancelled_by !== "client" && cancelled_by !== "counselor") {
      return new Response(
        JSON.stringify({ error: "cancelled_by must be 'client' or 'counselor'" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Fetch the booking
    const { data: booking, error: bookingError } = await supabase
      .from("bookings")
      .select("*")
      .eq("id", booking_id)
      .single();

    if (bookingError || !booking) {
      return new Response(
        JSON.stringify({ error: "Booking not found", details: bookingError?.message }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Fetch client and counselor profiles in parallel
    const [clientResult, counselorResult] = await Promise.all([
      supabase.from("profiles").select("*").eq("id", booking.client_id).single(),
      supabase.from("profiles").select("*").eq("id", booking.counselor_id).single(),
    ]);

    if (clientResult.error || !clientResult.data) {
      return new Response(
        JSON.stringify({ error: "Client profile not found", details: clientResult.error?.message }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (counselorResult.error || !counselorResult.data) {
      return new Response(
        JSON.stringify({ error: "Counselor profile not found", details: counselorResult.error?.message }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const client = clientResult.data;
    const counselor = counselorResult.data;

    // Determine who gets the cancellation notice (the OTHER party)
    const recipient = cancelled_by === "client" ? counselor : client;
    const cancellerName = cancelled_by === "client" ? client.full_name : counselor.full_name;

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

    // Send cancellation notice to the other party
    await sendResendEmail({
      to: [recipient.email],
      subject: "Session Cancelled - IvyPi",
      html: cancellationNotice(recipient.full_name, cancellerName, formattedDate, formattedTime),
    });

    // Log to notifications_log
    const { error: logError } = await supabase
      .from("notifications_log")
      .insert({
        booking_id,
        recipient_id: recipient.id,
        recipient: recipient.email,
        type: "cancellation",
        channel: "email",
        status: "sent",
        metadata: { cancelled_by },
      });

    if (logError) {
      console.error("Failed to log notification:", logError.message);
    }

    return new Response(
      JSON.stringify({ success: true, booking_id, notified: recipient.id }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-cancellation-notice error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
