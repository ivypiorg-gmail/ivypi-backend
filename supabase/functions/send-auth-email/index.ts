/**
 * Supabase Auth Email Hook — sends branded transactional emails via Resend
 * instead of the default Supabase auth emails.
 *
 * Configure in Supabase Dashboard → Auth → Hooks → Send Email Hook
 * pointing to this edge function.
 *
 * Handles: signup, recovery (password reset), magic_link, email_change
 */

import {
  signupConfirmation,
  passwordReset,
  magicLink,
  emailChange,
} from "../_shared/email-templates.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface AuthEmailPayload {
  user: {
    id: string;
    email: string;
    user_metadata?: { full_name?: string };
  };
  email_data: {
    token: string;
    token_hash: string;
    redirect_to: string;
    email_action_type: "signup" | "recovery" | "magic_link" | "email_change";
    site_url: string;
    new_email?: string;
  };
}

const SUBJECTS: Record<string, string> = {
  signup: "Verify Your Email — IvyPi",
  recovery: "Reset Your Password — IvyPi",
  magic_link: "Your Sign-In Link — IvyPi",
  email_change: "Confirm Your New Email — IvyPi",
};

function buildConfirmUrl(
  siteUrl: string,
  tokenHash: string,
  type: string,
  redirectTo: string,
): string {
  const base = siteUrl.replace(/\/$/, "");
  const params = new URLSearchParams({
    token_hash: tokenHash,
    type,
    redirect_to: redirectTo || `${base}/dashboard/`,
  });
  return `${base}/auth/confirm?${params.toString()}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const payload: AuthEmailPayload = await req.json();
    const { user, email_data } = payload;
    const {
      token_hash,
      email_action_type,
      site_url,
      redirect_to,
      new_email,
    } = email_data;

    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!resendApiKey) {
      throw new Error("RESEND_API_KEY is not set");
    }

    const confirmUrl = buildConfirmUrl(
      site_url,
      token_hash,
      email_action_type,
      redirect_to,
    );

    let html: string;
    switch (email_action_type) {
      case "signup":
        html = signupConfirmation(confirmUrl);
        break;
      case "recovery":
        html = passwordReset(confirmUrl);
        break;
      case "magic_link":
        html = magicLink(confirmUrl);
        break;
      case "email_change":
        html = emailChange(new_email || user.email, confirmUrl);
        break;
      default:
        console.warn(`Unknown email_action_type: ${email_action_type}`);
        return new Response(JSON.stringify({ error: "Unknown email type" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    }

    const subject = SUBJECTS[email_action_type] || "IvyPi";
    const recipient = email_action_type === "email_change" && new_email
      ? new_email
      : user.email;

    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "IvyPi <noreply@ivypi.org>",
        to: [recipient],
        subject,
        html,
      }),
    });

    if (!emailResponse.ok) {
      const err = await emailResponse.text();
      throw new Error(`Resend API error: ${err}`);
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("send-auth-email error:", err);
    return new Response(
      JSON.stringify({
        error: "Failed to send email",
        details: (err as Error).message,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
