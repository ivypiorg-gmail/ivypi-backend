-- New fields on activities
ALTER TABLE activities
  ADD COLUMN uc_description TEXT,
  ADD COLUMN resume_bullets TEXT;

-- Awards table
CREATE TABLE awards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  level TEXT, -- 'national', 'international', 'state', 'regional', 'school'
  category TEXT, -- 'stem', 'service', 'academic', 'arts', 'athletics', 'other'
  grade_year INTEGER,
  description TEXT,
  sort_order INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_awards_student_id ON awards(student_id);

ALTER TABLE awards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view awards for accessible students"
  ON awards FOR SELECT USING (can_access_student(student_id));
CREATE POLICY "Users can insert awards for accessible students"
  ON awards FOR INSERT WITH CHECK (can_access_student(student_id));
CREATE POLICY "Users can update awards for accessible students"
  ON awards FOR UPDATE USING (can_access_student(student_id)) WITH CHECK (can_access_student(student_id));
CREATE POLICY "Users can delete awards for accessible students"
  ON awards FOR DELETE USING (can_access_student(student_id));

-- Cleanup trigger for award comments
CREATE TRIGGER trg_awards_delete_comments
  AFTER DELETE ON awards FOR EACH ROW
  EXECUTE FUNCTION delete_comments_for_target('award');
