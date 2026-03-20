-- Deadline Daemon: extend Phase 1 tables, create strategic_timelines,
-- add notification types, indexes, staleness trigger, cron job

-- 1. Extend school_deadlines
ALTER TABLE school_deadlines ADD COLUMN IF NOT EXISTS verified BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE school_deadlines ADD COLUMN IF NOT EXISTS verified_by UUID REFERENCES profiles(id);
ALTER TABLE school_deadlines ADD COLUMN IF NOT EXISTS cycle_year INTEGER;
ALTER TABLE school_deadlines ADD CONSTRAINT school_deadlines_unique_school_type_year
  UNIQUE (school_name, deadline_type, cycle_year);

-- 2. Extend student_deadlines
ALTER TABLE student_deadlines ADD COLUMN IF NOT EXISTS deadline_type TEXT;
ALTER TABLE student_deadlines ADD COLUMN IF NOT EXISTS school_name TEXT;
ALTER TABLE student_deadlines ADD COLUMN IF NOT EXISTS priority TEXT NOT NULL DEFAULT 'normal';
ALTER TABLE student_deadlines ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES profiles(id);

-- 3. Create strategic_timelines
CREATE TABLE IF NOT EXISTS strategic_timelines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  narrative_brief TEXT,
  risk_flags JSONB NOT NULL DEFAULT '[]',
  sequenced_tasks JSONB NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'idle',
  stale BOOLEAN NOT NULL DEFAULT false,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT strategic_timelines_student_unique UNIQUE (student_id),
  CONSTRAINT strategic_timelines_status_check CHECK (status IN ('idle', 'generating', 'failed'))
);

CREATE TRIGGER set_strategic_timelines_updated_at
  BEFORE UPDATE ON strategic_timelines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- RLS for strategic_timelines
ALTER TABLE strategic_timelines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own student timelines" ON strategic_timelines
  FOR SELECT USING (public.can_access_student(student_id));

CREATE POLICY "Counselors and admins can insert/update timelines" ON strategic_timelines
  FOR ALL USING (public.current_user_role() IN ('counselor', 'admin'))
  WITH CHECK (public.current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "Only admins can delete timelines" ON strategic_timelines
  FOR DELETE USING (public.current_user_role() = 'admin');

-- 4. Extend notifications_log
ALTER TABLE notifications_log ADD COLUMN IF NOT EXISTS student_deadline_id UUID REFERENCES student_deadlines(id);
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'deadline_reminder_7d';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'deadline_reminder_2d';

-- 5. Indexes for caseload queries
CREATE INDEX IF NOT EXISTS idx_student_deadlines_due_date
  ON student_deadlines(due_date) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_student_deadlines_student
  ON student_deadlines(student_id);

-- 6. Staleness trigger on college_lists
CREATE OR REPLACE FUNCTION mark_timeline_stale() RETURNS trigger AS $$
BEGIN
  UPDATE strategic_timelines SET stale = true
  WHERE student_id = COALESCE(NEW.student_id, OLD.student_id);
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER college_lists_timeline_stale
  AFTER INSERT OR UPDATE OR DELETE ON college_lists
  FOR EACH ROW EXECUTE FUNCTION mark_timeline_stale();

-- 7. Daily deadline reminder cron (9am UTC)
SELECT cron.schedule(
  'send-deadline-reminders',
  '0 9 * * *',
  $$
  SELECT extensions.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/send-deadline-reminders',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
