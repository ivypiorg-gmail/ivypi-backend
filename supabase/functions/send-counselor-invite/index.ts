import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  counselorInvite,
  counselorRoleUpgrade,
  counselorApproval,
} from "../_shared/email-templates.ts";

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
    const { email } = await req.json();

    if (!email) {
      return new Response(
        JSON.stringify({ error: "email is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Authenticate the caller as admin
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user: caller }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !caller) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: callerProfile } = await supabase
      .from("profiles")
      .select("id, role")
      .eq("id", caller.id)
      .single();

    if (!callerProfile || callerProfile.role !== "admin") {
      return new Response(
        JSON.stringify({ error: "Admin access required" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Check if email belongs to an existing user (exact match only)
    const normalizedEmail = email.toLowerCase();
    const { data: { users: existingUsers } } = await supabase.auth.admin.listUsers({
      filter: normalizedEmail,
      perPage: 50,
    });
    const existingUser = existingUsers?.find(
      (u: { email?: string }) => u.email?.toLowerCase() === normalizedEmail,
    );

    if (existingUser) {
      // Check their current role
      const { data: existingProfile } = await supabase
        .from("profiles")
        .select("id, role, full_name")
        .eq("id", existingUser.id)
        .single();

      if (existingProfile?.role === "counselor" || existingProfile?.role === "admin") {
        return new Response(
          JSON.stringify({ error: `This user is already a ${existingProfile.role}` }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const isPendingCounselor = existingProfile?.role === "pending_counselor";

      // Upgrade existing user to counselor
      const { error: updateError } = await supabase
        .from("profiles")
        .update({ role: "counselor" })
        .eq("id", existingUser.id);

      if (updateError) {
        throw new Error(`Failed to upgrade user: ${updateError.message}`);
      }

      // Update auth user_metadata to reflect new role
      await supabase.auth.admin.updateUserById(existingUser.id, {
        user_metadata: { role: "counselor", requested_role: null },
      });

      // Send appropriate notification email
      const emailSubject = isPendingCounselor
        ? "Your Counselor Account Has Been Approved"
        : "Your IvyPi Account Has Been Upgraded";
      const emailHtml = isPendingCounselor
        ? counselorApproval(existingProfile?.full_name || "")
        : counselorRoleUpgrade(existingProfile?.full_name || "");

      const upgradeEmailResponse = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendApiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: "IvyPi <noreply@ivypi.org>",
          to: [email],
          subject: emailSubject,
          html: emailHtml,
        }),
      });

      if (!upgradeEmailResponse.ok) {
        const err = await upgradeEmailResponse.text();
        console.error("Failed to send upgrade email:", err);
      }

      const successMessage = isPendingCounselor
        ? "Pending counselor approved and notified"
        : "Existing user upgraded to counselor";

      return new Response(
        JSON.stringify({ message: successMessage }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // No existing user — create invite and send email
    const { data: invite, error: insertError } = await supabase
      .from("counselor_invites")
      .insert({ email: email.toLowerCase(), invited_by: callerProfile.id })
      .select("token")
      .single();

    if (insertError) {
      // Unique constraint on pending invites
      if (insertError.code === "23505") {
        return new Response(
          JSON.stringify({ error: "A pending invite already exists for this email" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      throw new Error(`Failed to create invite: ${insertError.message}`);
    }

    const signupUrl = `https://ivypi.org/login/?invite=${invite.token}`;

    const inviteEmailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "IvyPi <noreply@ivypi.org>",
        to: [email],
        subject: "You're Invited to Join IvyPi as a Counselor",
        html: counselorInvite(signupUrl),
      }),
    });

    if (!inviteEmailResponse.ok) {
      const err = await inviteEmailResponse.text();
      throw new Error(`Failed to send invite email: ${err}`);
    }

    return new Response(
      JSON.stringify({ message: `Invite sent to ${email}` }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-counselor-invite error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
