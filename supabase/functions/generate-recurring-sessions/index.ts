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
      student_ids,
      recurrence_group_id,
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

    const groupId = recurrence_group_id || crypto.randomUUID();
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

    // Calculate all candidate session dates (starting from offset 1 since the first is already booked)
    const candidates: { starts_at: Date; ends_at: Date }[] = [];
    for (let i = 1; i <= total_sessions; i++) {
      const offsetMs = i * intervalDays * 24 * 60 * 60 * 1000;
      const startsAt = new Date(firstStart.getTime() + offsetMs);
      const endsAt = new Date(startsAt.getTime() + sessionDurationMs);
      candidates.push({ starts_at: startsAt, ends_at: endsAt });
    }

    // Check availability for each candidate by querying availability_slots directly
    const availableBookings: { starts_at: string; ends_at: string }[] = [];
    const unavailableDates: string[] = [];

    for (const candidate of candidates) {
      const dateStr = candidate.starts_at.toISOString().split("T")[0];
      // Two 30-min slots that make up the 60-min session
      const slot1Time =
        candidate.starts_at.toISOString().split("T")[1].substring(0, 5) + ":00";
      const slot2Dt = new Date(candidate.starts_at.getTime() + 30 * 60 * 1000);
      const slot2Time =
        slot2Dt.toISOString().split("T")[1].substring(0, 5) + ":00";

      // Check counselor has both 30-min slots
      const { data: counselorSlots } = await supabase
        .from("availability_slots")
        .select("slot_start")
        .eq("owner_type", "counselor")
        .eq("owner_id", counselor_id)
        .eq("slot_date", dateStr)
        .in("slot_start", [slot1Time, slot2Time]);

      if (!counselorSlots || counselorSlots.length < 2) {
        unavailableDates.push(dateStr);
        continue;
      }

      // Check no conflicting confirmed booking exists for this counselor at this time
      const { data: conflicts } = await supabase
        .from("bookings")
        .select("id")
        .eq("counselor_id", counselor_id)
        .eq("status", "confirmed")
        .lt("starts_at", candidate.ends_at.toISOString())
        .gt("ends_at", candidate.starts_at.toISOString())
        .limit(1);

      if (conflicts && conflicts.length > 0) {
        unavailableDates.push(dateStr);
        continue;
      }

      availableBookings.push({
        starts_at: candidate.starts_at.toISOString(),
        ends_at: candidate.ends_at.toISOString(),
      });
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

    // Insert all valid bookings
    const bookingRows = availableBookings.map((slot) => ({
      counselor_id,
      client_id,
      starts_at: slot.starts_at,
      ends_at: slot.ends_at,
      status: "confirmed",
      recurrence,
      recurrence_group_id: groupId,
    }));

    const { data: insertedBookings, error: insertError } = await supabase
      .from("bookings")
      .insert(bookingRows)
      .select("id, starts_at, ends_at");

    if (insertError) {
      throw new Error(`Failed to insert bookings: ${insertError.message}`);
    }

    // Insert booking_students rows for each new booking
    if (insertedBookings && student_ids && student_ids.length > 0) {
      const bsRows = insertedBookings.flatMap(
        (b: { id: string }) =>
          student_ids.map((sid: string) => ({
            booking_id: b.id,
            student_id: sid,
          })),
      );

      const { error: bsError } = await supabase
        .from("booking_students")
        .insert(bsRows);

      if (bsError) {
        console.error("Failed to insert booking_students:", bsError.message);
      }
    }

    const createdIds = insertedBookings?.map((b: { id: string }) => b.id) ?? [];

    return new Response(
      JSON.stringify({
        success: true,
        recurrence_group_id: groupId,
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
