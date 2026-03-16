# IvyPi Portal Backend

Supabase backend for the IvyPi counseling portal.

## Database Schema

- **`supabase/schema.sql`** — Complete, authoritative snapshot of the current database schema (tables, types, functions, RLS policies, triggers). Read this first.
- **`supabase/migrations/`** — Incremental migration history. Use for understanding how the schema evolved, not for current state.

### Core Tables
- `profiles` — User profiles (linked to Supabase Auth), roles: `student_parent`, `counselor`, `admin`
- `students` — Student records with GPA, test scores, profile insights
- `documents` — Uploaded transcripts/resumes with parse status
- `courses` — Parsed course records from transcripts
- `activities` — Parsed extracurricular activities with depth tiers
- `college_lists` — College list entries with affinity reports and app status
- `scenarios` — What-if scenario modeling with projected insights
- `availability_windows` — Counselor recurring availability slots
- `availability_overrides` — Date-specific availability overrides
- `bookings` — Session bookings between counselors and students
- `counselor_invites` — Invite tokens for onboarding new counselors
- `notifications_log` — Email/SMS notification tracking

### Key Functions
- `handle_new_user()` — Auth trigger: creates profile, auto-assigns counselor role if invite exists
- `get_available_slots()` — Returns bookable time slots for a counselor in a date range
- `can_access_student()` — RLS helper: checks if caller is admin, assigned counselor, or the student
- `current_user_role()` — Returns the authenticated user's role

### RLS
All tables have row-level security enabled. Policies enforce role-based access: admins see everything, counselors see their own students, students see their own data.

## Edge Functions

Located in `supabase/functions/`. Deployed via `supabase functions deploy <name>`.

- **AI-powered:** `parse-transcript`, `parse-resume`, `generate-profile`, `generate-affinity`, `model-scenario`
- **Notifications:** `send-booking-confirmation`, `send-cancellation-notice`, `send-counselor-invite`, `send-reminder-emails`, `send-reminder-sms`
- **Scheduling:** `generate-recurring-sessions`
- **Shared:** `_shared/ai-helpers.ts`, `_shared/email-templates.ts`

## Regenerating Schema Artifacts

After any schema change (migration or SQL editor):
```bash
supabase db dump -f supabase/schema.sql
supabase gen types typescript --project-id gybkzyjtqhvxbuqzqanp > ../ivypi-portal/lib/supabase/types.ts
```
