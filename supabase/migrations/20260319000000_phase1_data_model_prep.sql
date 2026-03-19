-- Phase 1 Data Model Preparation
-- 1. Add updated_at columns and triggers to courses, activities, awards
-- 2. Add Phase 1 table stubs (narrative arc, deadlines, knowledge chunks)
-- 3. Enable pgvector extension for Campus Oracle
-- 4. Create ai_usage_log table for cost tracking

-- ── Generic updated_at trigger function ──

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ── 1. Add updated_at to courses, activities, awards ──

ALTER TABLE courses
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

DROP TRIGGER IF EXISTS set_courses_updated_at ON courses;
CREATE TRIGGER set_courses_updated_at
  BEFORE UPDATE ON courses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE activities
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

DROP TRIGGER IF EXISTS set_activities_updated_at ON activities;
CREATE TRIGGER set_activities_updated_at
  BEFORE UPDATE ON activities
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE awards
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

DROP TRIGGER IF EXISTS set_awards_updated_at ON awards;
CREATE TRIGGER set_awards_updated_at
  BEFORE UPDATE ON awards
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── 2. Narrative Arc (Phase 1A) ──

ALTER TABLE students
  ADD COLUMN IF NOT EXISTS narrative_arc JSONB,
  ADD COLUMN IF NOT EXISTS narrative_arc_generated_at TIMESTAMPTZ;

-- ── 3. Deadline Daemon (Phase 1B) ──

CREATE TABLE IF NOT EXISTS school_deadlines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_name TEXT NOT NULL,
  deadline_type TEXT NOT NULL,
  deadline_date DATE NOT NULL,
  description TEXT,
  source_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS set_school_deadlines_updated_at ON school_deadlines;
CREATE TRIGGER set_school_deadlines_updated_at
  BEFORE UPDATE ON school_deadlines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS student_deadlines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  school_deadline_id UUID REFERENCES school_deadlines(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  due_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS set_student_deadlines_updated_at ON student_deadlines;
CREATE TRIGGER set_student_deadlines_updated_at
  BEFORE UPDATE ON student_deadlines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── 4. Campus Oracle / pgvector (Phase 1C) ──

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS school_knowledge_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_name TEXT NOT NULL,
  chunk_type TEXT NOT NULL,
  content TEXT NOT NULL,
  embedding vector(1536),
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Use hnsw (no training data needed, works on empty tables, unlike ivfflat)
CREATE INDEX IF NOT EXISTS idx_school_knowledge_embedding
  ON school_knowledge_chunks USING hnsw (embedding vector_cosine_ops);

DROP TRIGGER IF EXISTS set_school_knowledge_chunks_updated_at ON school_knowledge_chunks;
CREATE TRIGGER set_school_knowledge_chunks_updated_at
  BEFORE UPDATE ON school_knowledge_chunks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── 5. AI Usage Log (cost tracking) ──

CREATE TABLE IF NOT EXISTS ai_usage_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  function_name TEXT NOT NULL,
  student_id UUID REFERENCES students(id) ON DELETE SET NULL,
  school_id UUID,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cost_usd NUMERIC(10, 6),
  caller_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_log_function ON ai_usage_log(function_name);
CREATE INDEX IF NOT EXISTS idx_ai_usage_log_student ON ai_usage_log(student_id);
CREATE INDEX IF NOT EXISTS idx_ai_usage_log_created ON ai_usage_log(created_at);

-- ── 6. RLS Policies ──

ALTER TABLE school_deadlines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "school_deadlines_select"
  ON school_deadlines FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "school_deadlines_insert"
  ON school_deadlines FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('counselor', 'admin'))
  );

CREATE POLICY "school_deadlines_update"
  ON school_deadlines FOR UPDATE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('counselor', 'admin'))
  );

CREATE POLICY "school_deadlines_delete"
  ON school_deadlines FOR DELETE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

ALTER TABLE student_deadlines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "student_deadlines_all"
  ON student_deadlines FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM students s
      WHERE s.id = student_deadlines.student_id
      AND (
        s.counselor_id = auth.uid()
        OR s.user_id = auth.uid()
        OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
      )
    )
  );

ALTER TABLE school_knowledge_chunks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "school_knowledge_chunks_select"
  ON school_knowledge_chunks FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "school_knowledge_chunks_insert"
  ON school_knowledge_chunks FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "school_knowledge_chunks_update"
  ON school_knowledge_chunks FOR UPDATE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "school_knowledge_chunks_delete"
  ON school_knowledge_chunks FOR DELETE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

ALTER TABLE ai_usage_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ai_usage_log_admin_select"
  ON ai_usage_log FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );
