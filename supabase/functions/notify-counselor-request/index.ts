import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { counselorRequestNotification } from "../_shared/email-templates.ts";

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
    // Verify this is called with the service role key (from pg_net trigger)
    const authHeader = req.headers.get("Authorization");
    const token = authHeader?.replace("Bearer ", "");
    if (token !== Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

    const { email, full_name } = await req.json();

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const { data: admins } = await supabase.from("profiles").select("email").eq("role", "admin");

    if (!admins || admins.length === 0) {
      return new Response(JSON.stringify({ success: true, note: "No admins found" }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const adminEmails = admins.map((a) => a.email).filter(Boolean);

    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendApiKey}` },
      body: JSON.stringify({
        from: "IvyPi <noreply@ivypi.org>",
        to: adminEmails,
        subject: "New Counselor Access Request",
        html: counselorRequestNotification(full_name, email),
      }),
    });

    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
