-- Extend booking_status enum with new values.
-- NOTE: ALTER TYPE ... ADD VALUE cannot run inside a transaction.
-- Supabase CLI handles these correctly when placed at the top of the migration.
ALTER TYPE booking_status ADD VALUE IF NOT EXISTS 'proposed' BEFORE 'confirmed';
ALTER TYPE booking_status ADD VALUE IF NOT EXISTS 'declined' AFTER 'no_show';

-- New enum for action item status
CREATE TYPE action_item_status AS ENUM ('open', 'in_progress', 'done');

-- Add proposed_by to bookings
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS proposed_by UUID REFERENCES profiles(id);

-- Add google_calendar_event_id to bookings
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS google_calendar_event_id TEXT;

-- Fix notifications_log mismatch: add missing columns
ALTER TABLE notifications_log ADD COLUMN IF NOT EXISTS recipient_id UUID REFERENCES profiles(id);
ALTER TABLE notifications_log ADD COLUMN IF NOT EXISTS channel TEXT DEFAULT 'email';
ALTER TABLE notifications_log ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}';

-- ============================================================================
-- session_notes: one note per session (booking)
-- ============================================================================
CREATE TABLE session_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  author_id UUID NOT NULL REFERENCES profiles(id),
  summary TEXT,
  discussion_points TEXT,
  next_steps TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT session_notes_booking_unique UNIQUE (booking_id)
);

CREATE INDEX idx_session_notes_booking ON session_notes(booking_id);

CREATE TRIGGER update_session_notes_updated_at
  BEFORE UPDATE ON session_notes FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

ALTER TABLE session_notes ENABLE ROW LEVEL SECURITY;

-- Counselors can CRUD notes for their own bookings
CREATE POLICY "Counselors can read session notes"
  ON session_notes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = session_notes.booking_id
        AND b.counselor_id = auth.uid()
    )
  );

CREATE POLICY "Counselors can insert session notes"
  ON session_notes FOR INSERT
  WITH CHECK (
    author_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = session_notes.booking_id
        AND b.counselor_id = auth.uid()
    )
  );

CREATE POLICY "Counselors can update session notes"
  ON session_notes FOR UPDATE
  USING (
    author_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = session_notes.booking_id
        AND b.counselor_id = auth.uid()
    )
  )
  WITH CHECK (
    author_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = session_notes.booking_id
        AND b.counselor_id = auth.uid()
    )
  );

CREATE POLICY "Counselors can delete session notes"
  ON session_notes FOR DELETE
  USING (
    author_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = session_notes.booking_id
        AND b.counselor_id = auth.uid()
    )
  );

-- Clients can read notes for their own bookings
CREATE POLICY "Clients can read session notes"
  ON session_notes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = session_notes.booking_id
        AND b.client_id = auth.uid()
    )
  );

-- Admins can manage all session notes
CREATE POLICY "Admins can manage session notes"
  ON session_notes
  USING (current_user_role() = 'admin'::user_role);

-- ============================================================================
-- action_items: tasks tied to bookings or standalone
-- ============================================================================
CREATE TABLE action_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
  client_id UUID NOT NULL REFERENCES profiles(id),
  counselor_id UUID NOT NULL REFERENCES profiles(id),
  title TEXT NOT NULL,
  description TEXT,
  assigned_to UUID REFERENCES profiles(id),
  status action_item_status DEFAULT 'open' NOT NULL,
  due_date DATE,
  sort_order INTEGER,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_action_items_booking ON action_items(booking_id);
CREATE INDEX idx_action_items_counselor ON action_items(counselor_id);
CREATE INDEX idx_action_items_client ON action_items(client_id);

CREATE TRIGGER update_action_items_updated_at
  BEFORE UPDATE ON action_items FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

ALTER TABLE action_items ENABLE ROW LEVEL SECURITY;

-- Both counselor and client in the relationship can read
CREATE POLICY "Counselors can read action items"
  ON action_items FOR SELECT
  USING (counselor_id = auth.uid());

CREATE POLICY "Clients can read action items"
  ON action_items FOR SELECT
  USING (client_id = auth.uid());

-- Counselors can create action items
CREATE POLICY "Counselors can insert action items"
  ON action_items FOR INSERT
  WITH CHECK (
    counselor_id = auth.uid()
    AND created_by = auth.uid()
  );

-- Counselors can delete action items
CREATE POLICY "Counselors can delete action items"
  ON action_items FOR DELETE
  USING (counselor_id = auth.uid());

-- Both counselor and client can update status
CREATE POLICY "Counselors can update action items"
  ON action_items FOR UPDATE
  USING (counselor_id = auth.uid())
  WITH CHECK (counselor_id = auth.uid());

CREATE POLICY "Clients can update action item status"
  ON action_items FOR UPDATE
  USING (client_id = auth.uid())
  WITH CHECK (client_id = auth.uid());

-- Admins can manage all action items
CREATE POLICY "Admins can manage action items"
  ON action_items
  USING (current_user_role() = 'admin'::user_role);

-- ============================================================================
-- google_calendar_tokens: one token set per user
-- ============================================================================
CREATE TABLE google_calendar_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  token_expires_at TIMESTAMPTZ NOT NULL,
  calendar_id TEXT DEFAULT 'primary',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT google_calendar_tokens_user_unique UNIQUE (user_id)
);

CREATE INDEX idx_google_calendar_tokens_user ON google_calendar_tokens(user_id);

CREATE TRIGGER update_google_calendar_tokens_updated_at
  BEFORE UPDATE ON google_calendar_tokens FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

ALTER TABLE google_calendar_tokens ENABLE ROW LEVEL SECURITY;

-- Users can only read their own tokens
CREATE POLICY "Users can read own calendar tokens"
  ON google_calendar_tokens FOR SELECT
  USING (user_id = auth.uid());

-- Users can insert their own tokens
CREATE POLICY "Users can insert own calendar tokens"
  ON google_calendar_tokens FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- Users can update their own tokens
CREATE POLICY "Users can update own calendar tokens"
  ON google_calendar_tokens FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Users can delete their own tokens
CREATE POLICY "Users can delete own calendar tokens"
  ON google_calendar_tokens FOR DELETE
  USING (user_id = auth.uid());

-- ============================================================================
-- Grants (following existing pattern from schema.sql)
-- ============================================================================
GRANT ALL ON TABLE session_notes TO anon;
GRANT ALL ON TABLE session_notes TO authenticated;
GRANT ALL ON TABLE session_notes TO service_role;

GRANT ALL ON TABLE action_items TO anon;
GRANT ALL ON TABLE action_items TO authenticated;
GRANT ALL ON TABLE action_items TO service_role;

GRANT ALL ON TABLE google_calendar_tokens TO anon;
GRANT ALL ON TABLE google_calendar_tokens TO authenticated;
GRANT ALL ON TABLE google_calendar_tokens TO service_role;
