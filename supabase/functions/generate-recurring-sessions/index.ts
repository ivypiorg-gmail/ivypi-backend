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
    const {
      counselor_id,
      client_id,
      first_starts_at,
      first_ends_at,
      recurrence,
      total_sessions,
    } = await req.json();

    // Validate required fields
    if (!counselor_id || !client_id || !first_starts_at || !first_ends_at || !recurrence || !total_sessions) {
      return new Response(
        JSON.stringify({
          error: "All fields required: counselor_id, client_id, first_starts_at, first_ends_at, recurrence, total_sessions",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (recurrence !== "weekly" && recurrence !== "biweekly") {
      return new Response(
        JSON.stringify({ error: "recurrence must be 'weekly' or 'biweekly'" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (typeof total_sessions !== "number" || total_sessions < 1 || total_sessions > 52) {
      return new Response(
        JSON.stringify({ error: "total_sessions must be a number between 1 and 52" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const recurrenceGroupId = crypto.randomUUID();
    const intervalDays = recurrence === "weekly" ? 7 : 14;

    const firstStart = new Date(first_starts_at);
    const firstEnd = new Date(first_ends_at);
    const sessionDurationMs = firstEnd.getTime() - firstStart.getTime();

    if (sessionDurationMs <= 0) {
      return new Response(
        JSON.stringify({ error: "first_ends_at must be after first_starts_at" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Calculate all candidate session dates
    const candidates: { starts_at: Date; ends_at: Date }[] = [];
    for (let i = 0; i < total_sessions; i++) {
      const offsetMs = i * intervalDays * 24 * 60 * 60 * 1000;
      const startsAt = new Date(firstStart.getTime() + offsetMs);
      const endsAt = new Date(startsAt.getTime() + sessionDurationMs);
      candidates.push({ starts_at: startsAt, ends_at: endsAt });
    }

    // Check availability for each candidate via get_available_slots RPC
    const availableBookings: { starts_at: string; ends_at: string }[] = [];
    const unavailableDates: string[] = [];

    for (const candidate of candidates) {
      const dateStr = candidate.starts_at.toISOString().split("T")[0];
      const timeStr = candidate.starts_at.toISOString().split("T")[1].substring(0, 5); // HH:MM

      const { data: slots, error: slotsError } = await supabase.rpc(
        "get_available_slots",
        {
          p_counselor_id: counselor_id,
          p_date: dateStr,
        },
      );

      if (slotsError) {
        console.error(`Error checking slots for ${dateStr}:`, slotsError.message);
        unavailableDates.push(dateStr);
        continue;
      }

      // Check if the desired time slot exists in the available slots
      const slotAvailable = slots?.some(
        (slot: { start_time: string }) => slot.start_time === timeStr,
      );

      if (slotAvailable) {
        availableBookings.push({
          starts_at: candidate.starts_at.toISOString(),
          ends_at: candidate.ends_at.toISOString(),
        });
      } else {
        unavailableDates.push(dateStr);
      }
    }

    if (availableBookings.length === 0) {
      return new Response(
        JSON.stringify({
          error: "No available slots found for any of the requested dates",
          unavailable_dates: unavailableDates,
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Insert all valid bookings atomically
    const bookingRows = availableBookings.map((slot) => ({
      counselor_id,
      client_id,
      starts_at: slot.starts_at,
      ends_at: slot.ends_at,
      status: "confirmed",
      recurrence_group_id: recurrenceGroupId,
    }));

    const { data: insertedBookings, error: insertError } = await supabase
      .from("bookings")
      .insert(bookingRows)
      .select("id, starts_at, ends_at");

    if (insertError) {
      throw new Error(`Failed to insert bookings: ${insertError.message}`);
    }

    const createdIds = insertedBookings?.map((b: { id: string }) => b.id) ?? [];

    return new Response(
      JSON.stringify({
        success: true,
        recurrence_group_id: recurrenceGroupId,
        created: createdIds,
        unavailable_dates: unavailableDates,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("generate-recurring-sessions error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
