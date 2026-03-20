/**
 * Shared Resend email helper for IvyPi notification functions.
 */

export async function sendResendEmail(opts: {
  to: string[];
  cc?: string[];
  subject: string;
  html: string;
  from?: string;
}): Promise<void> {
  const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: opts.from ?? "IvyPi Scheduling <noreply@ivypi.org>",
      to: opts.to,
      cc: opts.cc,
      subject: opts.subject,
      html: opts.html,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Resend API error (${res.status}): ${body}`);
  }
}
