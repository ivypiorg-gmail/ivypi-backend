import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { counselorApproval } from "../_shared/email-templates.ts";

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
    const { user_id } = await req.json();
    if (!user_id || typeof user_id !== "string") {
      return new Response(JSON.stringify({ error: "user_id is required" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendApiKey = Deno.env.get("RESEND_API_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // Authenticate caller as admin (same pattern as send-counselor-invite)
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    const token = authHeader.replace("Bearer ", "");
    const { data: { user: caller }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !caller) {
      return new Response(JSON.stringify({ error: "Invalid token" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    const { data: callerProfile } = await supabase.from("profiles").select("id, role").eq("id", caller.id).single();
    if (!callerProfile || callerProfile.role !== "admin") {
      return new Response(JSON.stringify({ error: "Admin access required" }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // Verify target is pending_counselor
    const { data: targetProfile } = await supabase.from("profiles").select("role, email, full_name").eq("id", user_id).single();
    if (!targetProfile || targetProfile.role !== "pending_counselor") {
      return new Response(JSON.stringify({ error: "User is not a pending counselor" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // 1. Update auth user_metadata first (harder to fix if it fails)
    const { error: metaError } = await supabase.auth.admin.updateUserById(user_id, { user_metadata: { role: "counselor", requested_role: null } });
    if (metaError) throw metaError;

    // 2. Update profile role
    const { error: profileError } = await supabase.from("profiles").update({ role: "counselor" }).eq("id", user_id);
    if (profileError) throw profileError;

    // 3. Send approval email
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendApiKey}` },
      body: JSON.stringify({
        from: "IvyPi <noreply@ivypi.org>",
        to: [targetProfile.email],
        subject: "Your IvyPi Counselor Account is Approved",
        html: counselorApproval(targetProfile.full_name),
      }),
    });

    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
