-- Track who added each school and allow counselors to propose removals

-- 1. Add added_by to college_lists
ALTER TABLE college_lists ADD COLUMN IF NOT EXISTS added_by UUID REFERENCES profiles(id);

-- 2. Expand suggestion_type to include remove_school
ALTER TABLE college_suggestions DROP CONSTRAINT IF EXISTS college_suggestions_suggestion_type_check;
ALTER TABLE college_suggestions ADD CONSTRAINT college_suggestions_suggestion_type_check
  CHECK (suggestion_type IN ('add_school', 'update_status', 'remove_school'));

-- 3. Allow counselors to create suggestions (for propose-to-delete)
DROP POLICY IF EXISTS "Parents can create suggestions" ON college_suggestions;
CREATE POLICY "Users can create suggestions" ON college_suggestions
  FOR INSERT WITH CHECK (
    can_access_student(student_id)
    AND suggested_by = auth.uid()
  );

-- 4. Allow counselors to view suggestions on their students
DROP POLICY IF EXISTS "Parents can view own suggestions" ON college_suggestions;
CREATE POLICY "Users can view relevant suggestions" ON college_suggestions
  FOR SELECT USING (
    suggested_by = auth.uid()
    OR can_access_student(student_id)
  );

-- 5. Let parents insert directly into college_lists (update RLS)
-- Existing policies allow counselor insert; add parent insert
CREATE POLICY "Parents can add schools to own student lists" ON college_lists
  FOR INSERT WITH CHECK (
    current_user_role() = 'student_parent'
    AND can_access_student(student_id)
  );
