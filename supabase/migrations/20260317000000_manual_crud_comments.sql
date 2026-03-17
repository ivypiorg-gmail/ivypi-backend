-- 1. New enum for course type
CREATE TYPE course_type AS ENUM ('high_school', 'college', 'online');

-- 2. Add columns to courses
ALTER TABLE courses ADD COLUMN course_type course_type DEFAULT 'high_school';

-- 3. Add columns to activities
ALTER TABLE activities
  ADD COLUMN organization TEXT,
  ADD COLUMN weeks_per_year INTEGER,
  ADD COLUMN common_app_description TEXT,
  ADD COLUMN activity_type TEXT,
  ADD COLUMN sort_order INTEGER;

-- 4. Create comments table
CREATE TABLE comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  author_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  body TEXT NOT NULL,
  target_type TEXT,
  target_id UUID,
  parent_id UUID REFERENCES comments(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT comments_target_consistency CHECK ((target_type IS NULL) = (target_id IS NULL))
);

CREATE INDEX idx_comments_student_id ON comments(student_id);
CREATE INDEX idx_comments_target ON comments(target_type, target_id) WHERE target_type IS NOT NULL;
CREATE INDEX idx_comments_parent_id ON comments(parent_id) WHERE parent_id IS NOT NULL;

CREATE TRIGGER update_comments_updated_at
  BEFORE UPDATE ON comments FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- 5. Orphan cleanup trigger
CREATE OR REPLACE FUNCTION delete_comments_for_target()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM comments
  WHERE target_type = TG_ARGV[0] AND target_id = OLD.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_courses_delete_comments
  AFTER DELETE ON courses FOR EACH ROW
  EXECUTE FUNCTION delete_comments_for_target('course');

CREATE TRIGGER trg_activities_delete_comments
  AFTER DELETE ON activities FOR EACH ROW
  EXECUTE FUNCTION delete_comments_for_target('activity');

-- 6. Comments RLS
ALTER TABLE comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view comments for accessible students"
  ON comments FOR SELECT
  USING (can_access_student(student_id));

CREATE POLICY "Users can add comments for accessible students"
  ON comments FOR INSERT
  WITH CHECK (can_access_student(student_id) AND author_id = auth.uid());

CREATE POLICY "Users can edit own comments"
  ON comments FOR UPDATE
  USING (author_id = auth.uid())
  WITH CHECK (author_id = auth.uid());

CREATE POLICY "Users can delete own comments"
  ON comments FOR DELETE
  USING (author_id = auth.uid());

-- 7. Update courses/activities RLS to allow all authorized users
-- NOTE: Existing SELECT policies ("Users can view own courses", "Users can view own activities")
-- are preserved and continue to provide read access via can_access_student().
DROP POLICY IF EXISTS "Counselors can manage courses" ON courses;
DROP POLICY IF EXISTS "Counselors can manage activities" ON activities;

CREATE POLICY "Users can insert courses for accessible students"
  ON courses FOR INSERT
  WITH CHECK (can_access_student(student_id));

CREATE POLICY "Users can update courses for accessible students"
  ON courses FOR UPDATE
  USING (can_access_student(student_id))
  WITH CHECK (can_access_student(student_id));

CREATE POLICY "Users can delete courses for accessible students"
  ON courses FOR DELETE
  USING (can_access_student(student_id));

CREATE POLICY "Users can insert activities for accessible students"
  ON activities FOR INSERT
  WITH CHECK (can_access_student(student_id));

CREATE POLICY "Users can update activities for accessible students"
  ON activities FOR UPDATE
  USING (can_access_student(student_id))
  WITH CHECK (can_access_student(student_id));

CREATE POLICY "Users can delete activities for accessible students"
  ON activities FOR DELETE
  USING (can_access_student(student_id));
