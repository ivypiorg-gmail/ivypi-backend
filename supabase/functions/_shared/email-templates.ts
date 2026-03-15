/**
 * Shared branded email templates for IvyPi transactional emails.
 * Used by all edge functions that send email via Resend.
 */

const BRAND = {
  navy: "#044d76",
  blue: "#01a2e8",
  muted: "#9DC3D5",
  bg: "#f7f9fb",
  white: "#ffffff",
  textDark: "#1a1a2e",
  textMuted: "#6b7280",
  dashboardUrl: "https://ivypi.org/dashboard/",
  logoUrl: "https://ivypi.org/assets/images/logo-wide.webp",
};

function layout(content: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>IvyPi</title>
</head>
<body style="margin:0;padding:0;background-color:${BRAND.bg};font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-weight:300;color:${BRAND.textDark};">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:${BRAND.bg};padding:32px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;">
          <!-- Header -->
          <tr>
            <td style="background-color:${BRAND.white};padding:24px 32px;border-radius:12px 12px 0 0;border:1px solid #e5e7eb;border-bottom:none;text-align:center;">
              <img src="${BRAND.logoUrl}" alt="IvyPi College Consulting" width="200" style="display:inline-block;width:200px;max-width:100%;height:auto;">
            </td>
          </tr>
          <tr>
            <td style="background-color:${BRAND.navy};height:2px;font-size:0;line-height:0;">&nbsp;</td>
          </tr>
          <!-- Body -->
          <tr>
            <td style="background-color:${BRAND.white};padding:36px 32px;border-left:1px solid #e5e7eb;border-right:1px solid #e5e7eb;font-weight:300;">
              ${content}
            </td>
          </tr>
          <!-- Accent divider -->
          <tr>
            <td style="background-color:${BRAND.blue};height:1px;font-size:0;line-height:0;">&nbsp;</td>
          </tr>
          <!-- Footer -->
          <tr>
            <td style="background-color:${BRAND.bg};padding:24px 32px;border-radius:0 0 12px 12px;border:1px solid #e5e7eb;border-top:none;text-align:center;">
              <p style="margin:0 0 8px;font-size:13px;color:${BRAND.textMuted};">
                <a href="https://ivypi.org" style="color:${BRAND.blue};text-decoration:none;">ivypi.org</a>
              </p>
              <p style="margin:0;font-size:12px;color:${BRAND.textMuted};">
                &copy; ${new Date().getFullYear()} IvyPi Education. All rights reserved.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function detailsBlock(date: string, time: string): string {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:20px 0;background-color:${BRAND.bg};border-radius:8px;border:1px solid #e5e7eb;border-left:2px solid ${BRAND.blue};">
    <tr>
      <td style="padding:16px 20px;">
        <p style="margin:0 0 6px;font-size:12px;color:${BRAND.blue};text-transform:uppercase;letter-spacing:0.5px;font-weight:400;">Date</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:400;color:${BRAND.navy};">${date}</p>
        <p style="margin:0 0 6px;font-size:12px;color:${BRAND.blue};text-transform:uppercase;letter-spacing:0.5px;font-weight:400;">Time</p>
        <p style="margin:0;font-size:15px;font-weight:400;color:${BRAND.navy};">${time}</p>
      </td>
    </tr>
  </table>`;
}

function calendarLinks(startsAt: string, endsAt: string, counselorName: string): string {
  const title = `IvyPi Session with ${counselorName}`;
  const details = "IvyPi College Consulting session. Manage your booking at https://ivypi.org/dashboard/";

  // Google Calendar URL — dates in YYYYMMDDTHHmmssZ format
  const toGoogleDate = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const gcalUrl = `https://calendar.google.com/calendar/render?action=TEMPLATE&text=${encodeURIComponent(title)}&dates=${toGoogleDate(startsAt)}/${toGoogleDate(endsAt)}&details=${encodeURIComponent(details)}`;

  // Outlook Web URL
  const outlookUrl = `https://outlook.live.com/calendar/0/action/compose?subject=${encodeURIComponent(title)}&startdt=${startsAt}&enddt=${endsAt}&body=${encodeURIComponent(details)}`;

  return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 20px;">
    <tr>
      <td style="padding-right:10px;">
        <a href="${gcalUrl}" target="_blank" style="display:inline-block;padding:8px 16px;font-size:13px;font-weight:400;color:${BRAND.navy};text-decoration:none;border:1px solid #e5e7eb;border-radius:6px;letter-spacing:0.2px;">&#128197; Google Calendar</a>
      </td>
      <td>
        <a href="${outlookUrl}" target="_blank" style="display:inline-block;padding:8px 16px;font-size:13px;font-weight:400;color:${BRAND.navy};text-decoration:none;border:1px solid #e5e7eb;border-radius:6px;letter-spacing:0.2px;">&#128197; Outlook</a>
      </td>
    </tr>
  </table>`;
}

function dashboardButton(label = "View Dashboard"): string {
  return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0 8px;">
    <tr>
      <td style="border:1px solid ${BRAND.navy};">
        <a href="${BRAND.dashboardUrl}" style="display:inline-block;padding:10px 28px;font-size:14px;font-weight:400;color:${BRAND.navy};text-decoration:none;letter-spacing:0.3px;">${label} &rarr;</a>
      </td>
    </tr>
  </table>`;
}

// ── Exported Templates ──

export function bookingConfirmationClient(
  clientName: string,
  counselorName: string,
  date: string,
  time: string,
  startsAt?: string,
  endsAt?: string,
): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:${BRAND.navy};">Your appointment is confirmed <span style="color:${BRAND.blue};">&#10003;</span></h2>
    <p style="margin:0 0 20px;font-size:15px;color:${BRAND.textMuted};">Hi ${clientName},</p>
    <p style="margin:0 0 4px;font-size:15px;line-height:1.6;">Your session with <strong>${counselorName}</strong> has been confirmed.</p>
    ${detailsBlock(date, time)}
    ${startsAt && endsAt ? `<p style="margin:0 0 4px;font-size:13px;color:${BRAND.textMuted};">Add to your calendar:</p>${calendarLinks(startsAt, endsAt, counselorName)}` : ""}
    <p style="font-size:14px;color:${BRAND.textMuted};line-height:1.5;">Need to make changes? Log in to your dashboard to reschedule or cancel.</p>
    ${dashboardButton()}
  `);
}

export function bookingConfirmationCounselor(
  counselorName: string,
  clientName: string,
  date: string,
  time: string,
): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:${BRAND.navy};">New appointment confirmed <span style="color:${BRAND.blue};">&#10003;</span></h2>
    <p style="margin:0 0 20px;font-size:15px;color:${BRAND.textMuted};">Hi ${counselorName},</p>
    <p style="margin:0 0 4px;font-size:15px;line-height:1.6;">A session with <strong>${clientName}</strong> has been confirmed.</p>
    ${detailsBlock(date, time)}
    ${dashboardButton("View Details")}
  `);
}

export function reminderClient(
  clientName: string,
  counselorName: string,
  date: string,
  time: string,
): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:${BRAND.navy};">Session tomorrow</h2>
    <p style="margin:0 0 20px;font-size:15px;color:${BRAND.textMuted};">Hi ${clientName},</p>
    <p style="margin:0 0 4px;font-size:15px;line-height:1.6;">Friendly reminder — you have a session with <strong>${counselorName}</strong> tomorrow.</p>
    ${detailsBlock(date, time)}
    <p style="font-size:14px;color:${BRAND.textMuted};line-height:1.5;">Need to reschedule? Please update your booking as soon as possible.</p>
    ${dashboardButton()}
  `);
}

export function reminderCounselor(
  counselorName: string,
  clientName: string,
  date: string,
  time: string,
): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:${BRAND.navy};">Session tomorrow</h2>
    <p style="margin:0 0 20px;font-size:15px;color:${BRAND.textMuted};">Hi ${counselorName},</p>
    <p style="margin:0 0 4px;font-size:15px;line-height:1.6;">Friendly reminder — you have a session with <strong>${clientName}</strong> tomorrow.</p>
    ${detailsBlock(date, time)}
    ${dashboardButton("View Schedule")}
  `);
}

export function cancellationNotice(
  recipientName: string,
  cancellerName: string,
  date: string,
  time: string,
): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:#dc2626;">Session cancelled</h2>
    <p style="margin:0 0 20px;font-size:15px;color:${BRAND.textMuted};">Hi ${recipientName},</p>
    <p style="margin:0 0 4px;font-size:15px;line-height:1.6;"><strong>${cancellerName}</strong> has cancelled the following session:</p>
    ${detailsBlock(date, time)}
    <p style="font-size:14px;color:${BRAND.textMuted};line-height:1.5;">If you'd like to book a new session, visit your dashboard.</p>
    ${dashboardButton("Book New Session")}
  `);
}

export function counselorInvite(signupUrl: string): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:${BRAND.navy};">You're invited to join IvyPi</h2>
    <p style="margin:0 0 20px;font-size:15px;line-height:1.6;">You've been invited to join <strong>IvyPi</strong> as a counselor. As a counselor, you'll be able to set your availability, manage bookings, and connect with students and parents.</p>
    <p style="margin:0 0 24px;font-size:15px;line-height:1.6;">Click the button below to create your account. You can sign up with email or Google.</p>
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0 8px;">
      <tr>
        <td style="background-color:${BRAND.navy};border-radius:6px;">
          <a href="${signupUrl}" style="display:inline-block;padding:12px 32px;font-size:14px;font-weight:400;color:${BRAND.white};text-decoration:none;letter-spacing:0.3px;">Create Your Account &rarr;</a>
        </td>
      </tr>
    </table>
    <p style="margin:24px 0 0;font-size:13px;color:${BRAND.textMuted};line-height:1.5;">If you weren't expecting this invitation, you can safely ignore this email.</p>
  `);
}

export function counselorRoleUpgrade(counselorName: string): string {
  return layout(`
    <h2 style="margin:0 0 8px;font-size:21px;font-weight:400;color:${BRAND.navy};">Your account has been upgraded <span style="color:${BRAND.blue};">&#10003;</span></h2>
    <p style="margin:0 0 20px;font-size:15px;color:${BRAND.textMuted};">Hi${counselorName ? ` ${counselorName}` : ""},</p>
    <p style="margin:0 0 4px;font-size:15px;line-height:1.6;">Your IvyPi account now has <strong>counselor</strong> access. You can set your availability, manage bookings, and connect with students and parents through your dashboard.</p>
    ${dashboardButton("Go to Dashboard")}
  `);
}
