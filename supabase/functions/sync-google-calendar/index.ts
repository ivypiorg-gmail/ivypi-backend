import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface SyncRequest {
  bookingId: string;
  action: "create" | "update" | "delete";
}

/**
 * Refresh an expired Google access token using the refresh token.
 * Returns the new access token, or null on failure.
 */
async function refreshAccessToken(
  refreshToken: string,
  clientId: string,
  clientSecret: string
): Promise<{ access_token: string; expires_in: number } | null> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: clientId,
      client_secret: clientSecret,
    }),
  });

  if (!res.ok) {
    console.error("Token refresh failed:", await res.text());
    return null;
  }

  return await res.json();
}

/**
 * Get a valid access token for a user, refreshing if expired.
 */
async function getValidAccessToken(
  supabase: ReturnType<typeof createClient>,
  tokenRow: {
    user_id: string;
    access_token: string;
    refresh_token: string;
    token_expires_at: string;
    calendar_id: string;
  },
  clientId: string,
  clientSecret: string
): Promise<string | null> {
  const expiresAt = new Date(tokenRow.token_expires_at).getTime();
  const now = Date.now();

  // If token is still valid (with 60s buffer), use it
  if (expiresAt > now + 60_000) {
    return tokenRow.access_token;
  }

  // Refresh the token
  const refreshed = await refreshAccessToken(
    tokenRow.refresh_token,
    clientId,
    clientSecret
  );
  if (!refreshed) return null;

  const newExpiresAt = new Date(
    Date.now() + refreshed.expires_in * 1000
  ).toISOString();

  // Update the stored token
  await supabase
    .from("google_calendar_tokens")
    .update({
      access_token: refreshed.access_token,
      token_expires_at: newExpiresAt,
    })
    .eq("user_id", tokenRow.user_id);

  return refreshed.access_token;
}

/**
 * Create a Google Calendar event for a booking.
 */
async function createCalendarEvent(
  accessToken: string,
  calendarId: string,
  booking: {
    id: string;
    starts_at: string;
    ends_at: string;
    notes: string | null;
  },
  clientName: string,
  counselorName: string
): Promise<string | null> {
  const res = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        summary: `IvyPi Session: ${clientName} & ${counselorName}`,
        description: booking.notes || "IvyPi counseling session",
        start: {
          dateTime: booking.starts_at,
          timeZone: "UTC",
        },
        end: {
          dateTime: booking.ends_at,
          timeZone: "UTC",
        },
      }),
    }
  );

  if (!res.ok) {
    console.error("Failed to create calendar event:", await res.text());
    return null;
  }

  const event = await res.json();
  return event.id;
}

/**
 * Update an existing Google Calendar event.
 */
async function updateCalendarEvent(
  accessToken: string,
  calendarId: string,
  eventId: string,
  booking: {
    starts_at: string;
    ends_at: string;
    notes: string | null;
  },
  clientName: string,
  counselorName: string
): Promise<boolean> {
  const res = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`,
    {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        summary: `IvyPi Session: ${clientName} & ${counselorName}`,
        description: booking.notes || "IvyPi counseling session",
        start: {
          dateTime: booking.starts_at,
          timeZone: "UTC",
        },
        end: {
          dateTime: booking.ends_at,
          timeZone: "UTC",
        },
      }),
    }
  );

  if (!res.ok) {
    console.error("Failed to update calendar event:", await res.text());
    return false;
  }
  return true;
}

/**
 * Delete a Google Calendar event.
 */
async function deleteCalendarEvent(
  accessToken: string,
  calendarId: string,
  eventId: string
): Promise<boolean> {
  const res = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`,
    {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    }
  );

  // 204 No Content = success, 410 Gone = already deleted
  if (!res.ok && res.status !== 410) {
    console.error("Failed to delete calendar event:", await res.text());
    return false;
  }
  return true;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { bookingId, action } = (await req.json()) as SyncRequest;

    if (!bookingId || !action) {
      return new Response(
        JSON.stringify({ error: "bookingId and action are required" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const googleClientId = Deno.env.get("GOOGLE_CLIENT_ID")!;
    const googleClientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Fetch the booking
    const { data: booking, error: bookingError } = await supabase
      .from("bookings")
      .select("*")
      .eq("id", bookingId)
      .single();

    if (bookingError || !booking) {
      return new Response(
        JSON.stringify({
          error: "Booking not found",
          details: bookingError?.message,
        }),
        {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Fetch profiles for both parties
    const [clientResult, counselorResult] = await Promise.all([
      supabase
        .from("profiles")
        .select("full_name")
        .eq("id", booking.client_id)
        .single(),
      supabase
        .from("profiles")
        .select("full_name")
        .eq("id", booking.counselor_id)
        .single(),
    ]);

    const clientName = clientResult.data?.full_name ?? "Client";
    const counselorName = counselorResult.data?.full_name ?? "Counselor";

    // Check if either party has connected Google Calendar
    const { data: tokenRows } = await supabase
      .from("google_calendar_tokens")
      .select("*")
      .in("user_id", [booking.client_id, booking.counselor_id]);

    if (!tokenRows || tokenRows.length === 0) {
      return new Response(
        JSON.stringify({
          success: true,
          message: "No connected calendars found",
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const results: Array<{
      userId: string;
      success: boolean;
      eventId?: string;
    }> = [];

    for (const tokenRow of tokenRows) {
      const accessToken = await getValidAccessToken(
        supabase,
        tokenRow,
        googleClientId,
        googleClientSecret
      );

      if (!accessToken) {
        console.error(
          `Failed to get valid access token for user ${tokenRow.user_id}`
        );
        results.push({ userId: tokenRow.user_id, success: false });
        continue;
      }

      const calendarId = tokenRow.calendar_id || "primary";

      if (action === "create") {
        const eventId = await createCalendarEvent(
          accessToken,
          calendarId,
          booking,
          clientName,
          counselorName
        );
        if (eventId) {
          // Store the event ID on the booking (use the first one created)
          if (!booking.google_calendar_event_id) {
            await supabase
              .from("bookings")
              .update({ google_calendar_event_id: eventId })
              .eq("id", bookingId);
            booking.google_calendar_event_id = eventId;
          }
          results.push({ userId: tokenRow.user_id, success: true, eventId });
        } else {
          results.push({ userId: tokenRow.user_id, success: false });
        }
      } else if (action === "update") {
        const eventId = booking.google_calendar_event_id;
        if (eventId) {
          const ok = await updateCalendarEvent(
            accessToken,
            calendarId,
            eventId,
            booking,
            clientName,
            counselorName
          );
          results.push({ userId: tokenRow.user_id, success: ok });
        } else {
          // No event to update — create one instead
          const newEventId = await createCalendarEvent(
            accessToken,
            calendarId,
            booking,
            clientName,
            counselorName
          );
          if (newEventId && !booking.google_calendar_event_id) {
            await supabase
              .from("bookings")
              .update({ google_calendar_event_id: newEventId })
              .eq("id", bookingId);
            booking.google_calendar_event_id = newEventId;
          }
          results.push({
            userId: tokenRow.user_id,
            success: !!newEventId,
            eventId: newEventId ?? undefined,
          });
        }
      } else if (action === "delete") {
        const eventId = booking.google_calendar_event_id;
        if (eventId) {
          const ok = await deleteCalendarEvent(
            accessToken,
            calendarId,
            eventId
          );
          results.push({ userId: tokenRow.user_id, success: ok });
        } else {
          // Nothing to delete
          results.push({ userId: tokenRow.user_id, success: true });
        }
      }
    }

    // If action was delete, clear the event ID on the booking
    if (action === "delete" && booking.google_calendar_event_id) {
      await supabase
        .from("bookings")
        .update({ google_calendar_event_id: null })
        .eq("id", bookingId);
    }

    return new Response(
      JSON.stringify({ success: true, results }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    console.error("sync-google-calendar error:", err);
    return new Response(
      JSON.stringify({
        error: "Internal server error",
        details: (err as Error).message,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
