-- Narrative Arc Engine: dedicated tables, annotations, and storage
-- Replaces the inline narrative_arc columns on students with a proper
-- counselor-only narrative_arcs table, plus annotation support.

-- ── 1. Enum for generation stage ──

CREATE TYPE narrative_stage AS ENUM ('academic', 'activities', 'full');

-- ── 2. narrative_arcs table (counselor-only) ──

CREATE TABLE narrative_arcs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE UNIQUE,
  arc JSONB NOT NULL,
  stage narrative_stage NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'idle' CHECK (status IN ('idle', 'generating', 'failed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_narrative_arcs_student_id ON narrative_arcs(student_id);

CREATE TRIGGER update_narrative_arcs_updated_at
  BEFORE UPDATE ON narrative_arcs FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- RLS: counselors and admins only
ALTER TABLE narrative_arcs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Counselors and admins can view narrative arcs"
  ON narrative_arcs FOR SELECT
  TO authenticated
  USING (
    can_access_student(student_id)
    AND current_user_role() IN ('counselor', 'admin')
  );

CREATE POLICY "Counselors and admins can insert narrative arcs"
  ON narrative_arcs FOR INSERT
  TO authenticated
  WITH CHECK (
    can_access_student(student_id)
    AND current_user_role() IN ('counselor', 'admin')
  );

CREATE POLICY "Counselors and admins can update narrative arcs"
  ON narrative_arcs FOR UPDATE
  TO authenticated
  USING (
    can_access_student(student_id)
    AND current_user_role() IN ('counselor', 'admin')
  )
  WITH CHECK (
    can_access_student(student_id)
    AND current_user_role() IN ('counselor', 'admin')
  );

-- ── 3. narrative_annotations table ──

CREATE TABLE narrative_annotations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  author_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL CHECK (target_type IN ('throughline', 'contradiction', 'gap', 'identity_frame')),
  target_key TEXT NOT NULL,
  body TEXT NOT NULL,
  audio_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_narrative_annotations_student_id ON narrative_annotations(student_id);
CREATE INDEX idx_narrative_annotations_target ON narrative_annotations(target_type, target_key);

CREATE TRIGGER update_narrative_annotations_updated_at
  BEFORE UPDATE ON narrative_annotations FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- RLS: counselors/admins can read and create; only author can edit/delete
ALTER TABLE narrative_annotations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Counselors and admins can view annotations"
  ON narrative_annotations FOR SELECT
  TO authenticated
  USING (
    can_access_student(student_id)
    AND current_user_role() IN ('counselor', 'admin')
  );

CREATE POLICY "Counselors and admins can insert annotations"
  ON narrative_annotations FOR INSERT
  TO authenticated
  WITH CHECK (
    can_access_student(student_id)
    AND current_user_role() IN ('counselor', 'admin')
  );

CREATE POLICY "Authors can update own annotations"
  ON narrative_annotations FOR UPDATE
  TO authenticated
  USING (author_id = auth.uid())
  WITH CHECK (author_id = auth.uid());

CREATE POLICY "Authors can delete own annotations"
  ON narrative_annotations FOR DELETE
  TO authenticated
  USING (author_id = auth.uid());

-- ── 4. Add shared-keys column to students ──

ALTER TABLE students
  ADD COLUMN IF NOT EXISTS narrative_arc_shared_keys TEXT[] NOT NULL DEFAULT '{}'::TEXT[];

-- ── 5. Storage bucket for annotation audio ──

INSERT INTO storage.buckets (id, name, public)
VALUES ('narrative-annotations', 'narrative-annotations', false)
ON CONFLICT (id) DO NOTHING;

-- INSERT: counselors/admins who can access the student
CREATE POLICY "Counselors and admins can upload annotation files"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'narrative-annotations'
    AND public.can_access_student(split_part(name, '/', 1)::uuid)
    AND public.current_user_role() IN ('counselor', 'admin')
  );

-- SELECT: counselors/admins who can access the student
CREATE POLICY "Counselors and admins can read annotation files"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'narrative-annotations'
    AND public.can_access_student(split_part(name, '/', 1)::uuid)
    AND public.current_user_role() IN ('counselor', 'admin')
  );

-- DELETE: only the uploader
CREATE POLICY "Owners can delete annotation files"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'narrative-annotations'
    AND owner = auth.uid()
  );
