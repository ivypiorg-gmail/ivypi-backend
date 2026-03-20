-- Campus Oracle: conversations table and URL index

-- 1. Conversations table
CREATE TABLE IF NOT EXISTS campus_oracle_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  school_name TEXT NOT NULL,
  messages JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT campus_oracle_conversations_unique UNIQUE (student_id, school_name)
);

CREATE TRIGGER set_campus_oracle_conversations_updated_at
  BEFORE UPDATE ON campus_oracle_conversations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_campus_oracle_student ON campus_oracle_conversations(student_id);

ALTER TABLE campus_oracle_conversations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own student conversations" ON campus_oracle_conversations
  FOR SELECT USING (can_access_student(student_id));

CREATE POLICY "Users can create conversations for accessible students" ON campus_oracle_conversations
  FOR INSERT WITH CHECK (can_access_student(student_id));

CREATE POLICY "Counselors and admins can update conversations" ON campus_oracle_conversations
  FOR UPDATE USING (current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "Counselors and admins can delete conversations" ON campus_oracle_conversations
  FOR DELETE USING (current_user_role() IN ('counselor', 'admin'));

-- Atomic message append helper (avoids read-modify-write race conditions)
CREATE OR REPLACE FUNCTION append_oracle_messages(
  conv_id UUID,
  new_messages JSONB
) RETURNS void AS $$
  UPDATE campus_oracle_conversations
  SET messages = messages || new_messages, updated_at = now()
  WHERE id = conv_id;
$$ LANGUAGE sql SECURITY DEFINER;

-- 2. School URL index
CREATE TABLE IF NOT EXISTS school_url_index (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_name TEXT NOT NULL,
  page_type TEXT NOT NULL,
  url TEXT NOT NULL,
  label TEXT NOT NULL,
  last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT school_url_index_unique UNIQUE (school_name, page_type)
);

CREATE TRIGGER set_school_url_index_updated_at
  BEFORE UPDATE ON school_url_index
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_school_url_index_school ON school_url_index(school_name);

ALTER TABLE school_url_index ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read URL index" ON school_url_index
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Counselors and admins can manage URL index" ON school_url_index
  FOR INSERT TO authenticated
  WITH CHECK (current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "Counselors and admins can update URL index" ON school_url_index
  FOR UPDATE TO authenticated
  USING (current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "Counselors and admins can delete URL index" ON school_url_index
  FOR DELETE TO authenticated
  USING (current_user_role() IN ('counselor', 'admin'));
