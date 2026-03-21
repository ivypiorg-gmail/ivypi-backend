# IvyPi Portal Backend

Supabase backend for the IvyPi counseling portal.

## Database Schema

- **`supabase/schema.sql`** — Complete, authoritative snapshot of the current database schema (tables, types, functions, RLS policies, triggers). Read this first.
- **`supabase/migrations/`** — Incremental migration history. Use for understanding how the schema evolved, not for current state.

### Core Tables (33 total)
- `profiles` — User profiles (linked to Supabase Auth), roles: `student_parent`, `counselor`, `admin`
- `students` — Student records with GPA, test scores, profile insights
- `documents` — Uploaded transcripts/resumes with parse status
- `courses` — Parsed course records from transcripts
- `activities` — Parsed extracurricular activities with depth tiers
- `awards` — Student awards and honors
- `college_lists` — College list entries with affinity reports and app status
- `college_suggestions` — Counselor/parent suggestions for college list changes
- `college_data_corrections` — User-submitted corrections to college data
- `scenarios` — What-if scenario modeling with projected insights
- `availability_slots` — Availability slots for counselors and students
- `bookings` — Session bookings between counselors and students
- `booking_students` — Many-to-many: bookings ↔ students
- `session_notes` — Notes attached to completed sessions
- `counselor_invites` — Invite tokens for onboarding new counselors
- `notifications_log` — Email/SMS notification tracking
- `action_items` — Counselor action items / tasks per client
- `ai_usage_log` — AI call tracking and cost estimates
- `campus_oracle_conversations` — Campus Oracle chat histories
- `comments` — Comments on activities, courses, awards
- `committee_member_profiles` — Simulated committee member personas
- `committee_prompt_templates` — Prompt templates for committee simulations
- `committee_simulations` — Committee simulation results
- `google_calendar_tokens` — Google Calendar OAuth tokens
- `narrative_annotations` — Annotations on narrative arcs
- `narrative_arcs` — AI-generated narrative arc data per student
- `portfolio_alerts` — Portfolio-level alerts (ED conflicts, overlaps, clusters)
- `school_deadlines` — Canonical school deadline data
- `school_url_index` — Indexed school URLs for Campus Oracle
- `shared_insights` — Counselor-shared insights per student/school
- `strategic_timelines` — AI-generated strategic timelines per student
- `student_deadlines` — Per-student deadline instances
- `universities` — University reference data

### Key Functions (12 total)
- `handle_new_user()` — Auth trigger: creates profile, auto-assigns counselor role if invite exists
- `can_access_student()` — RLS helper: checks if caller is admin, assigned counselor, or the student
- `current_user_role()` — Returns the authenticated user's role
- `append_oracle_messages()` — Updates Campus Oracle conversation with new messages
- `delete_comments_for_target()` — Cascade comment deletion trigger
- `derive_application_cycle()` — Auto-derive application cycle from graduation year
- `detect_portfolio_alerts()` — Detects ED conflicts, school overlaps, deadline clusters
- `mark_timeline_stale()` — Mark strategic timelines stale on college list changes
- `send_auth_email()` — Auth email hook (used by Supabase Auth)
- `set_profile_stale()` / `set_profile_stale_on_student_update()` — Profile staleness triggers
- `set_updated_at()` — Generic updated_at timestamp trigger

### RLS
All tables have row-level security enabled. Policies enforce role-based access: admins see everything, counselors see their own students, students see their own data.

## Edge Functions

Located in `supabase/functions/`. Deployed via `supabase functions deploy <name>`.

- **AI-powered:** `parse-transcript`, `parse-resume`, `parse-document`, `generate-profile`, `generate-affinity`, `generate-narrative-arc`, `generate-strategic-timeline`, `generate-student-deadlines`, `analyze-portfolio`, `simulate-committee`, `suggest-scenarios`, `campus-oracle`, `model-scenario`
- **Notifications:** `send-booking-confirmation`, `send-cancellation-notice`, `send-counselor-invite`, `send-reminder-emails`, `send-reminder-sms`, `send-deadline-reminders`, `approve-counselor-request`, `decline-counselor-request`, `notify-counselor-request`
- **Auth:** `send-auth-email` — Supabase Auth Email Hook; sends branded signup verification, password reset, magic link, and email change emails via Resend
- **Scheduling:** `generate-recurring-sessions`
- **Data seeding:** `seed-school-deadlines`, `seed-school-urls`
- **Integrations:** `sync-google-calendar`
- **Shared:** `_shared/ai-helpers.ts`, `_shared/email-templates.ts`, `_shared/edge-middleware.ts` (CORS, auth, role checks), `_shared/cost-tracking.ts` (AI usage logging), `_shared/send-email.ts` (Resend wrapper), `_shared/preview-*.html` (email template previews)

## Edge Function Environment Variables

Set via Supabase Dashboard (Settings > Edge Functions > Environment Variables):

```
# Auto-provided by Supabase
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=

# AI
ANTHROPIC_API_KEY=

# Email
RESEND_API_KEY=

# SMS
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_PHONE_NUMBER=

# Campus Oracle — Google Custom Search
GOOGLE_CSE_API_KEY=           # From console.cloud.google.com/apis/credentials
GOOGLE_CSE_CX=                # Search Engine ID from programmablesearchengine.google.com

# Google Calendar OAuth
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
```

## Regenerating Schema Artifacts

After any schema change (migration or SQL editor):
```bash
supabase db dump -f supabase/schema.sql
supabase gen types typescript --project-id gybkzyjtqhvxbuqzqanp > ../ivypi-portal/lib/supabase/types.ts
```
