-- College suggestions table: parents suggest changes, counselors approve/dismiss
CREATE TABLE IF NOT EXISTS college_suggestions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id uuid REFERENCES students(id) ON DELETE CASCADE NOT NULL,
  suggested_by uuid REFERENCES profiles(id) NOT NULL,
  suggestion_type text NOT NULL CHECK (suggestion_type IN ('add_school', 'update_status')),
  -- For add_school:
  school_name text,
  -- For update_status:
  college_list_id uuid REFERENCES college_lists(id) ON DELETE CASCADE,
  suggested_status app_status,
  -- Workflow:
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'dismissed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by uuid REFERENCES profiles(id)
);

ALTER TABLE college_suggestions ENABLE ROW LEVEL SECURITY;

-- Parents can insert suggestions for their students
DO $$ BEGIN
  CREATE POLICY "Parents can create suggestions" ON college_suggestions
    FOR INSERT WITH CHECK (
      can_access_student(student_id)
      AND current_user_role() = 'student_parent'
      AND suggested_by = auth.uid()
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Parents can view their own suggestions
DO $$ BEGIN
  CREATE POLICY "Parents can view own suggestions" ON college_suggestions
    FOR SELECT USING (suggested_by = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Counselors/admins can view suggestions for their students
DO $$ BEGIN
  CREATE POLICY "Counselors can view suggestions" ON college_suggestions
    FOR SELECT USING (
      can_access_student(student_id)
      AND current_user_role() = ANY (ARRAY['counselor'::user_role, 'admin'::user_role])
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Counselors/admins can update (approve/dismiss) suggestions for their students
DO $$ BEGIN
  CREATE POLICY "Counselors can resolve suggestions" ON college_suggestions
    FOR UPDATE USING (
      can_access_student(student_id)
      AND current_user_role() = ANY (ARRAY['counselor'::user_role, 'admin'::user_role])
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Tighten college_lists write access to counselor/admin only
-- (Parents must go through suggestions)
DROP POLICY IF EXISTS "Users can add to college list" ON college_lists;
DROP POLICY IF EXISTS "Users can update college list" ON college_lists;
DROP POLICY IF EXISTS "Users can remove from college list" ON college_lists;

DO $$ BEGIN
  CREATE POLICY "Counselors can add to college list" ON college_lists
    FOR INSERT WITH CHECK (
      can_access_student(student_id)
      AND current_user_role() = ANY (ARRAY['counselor'::user_role, 'admin'::user_role])
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Counselors can update college list" ON college_lists
    FOR UPDATE USING (
      can_access_student(student_id)
      AND current_user_role() = ANY (ARRAY['counselor'::user_role, 'admin'::user_role])
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Counselors can remove from college list" ON college_lists
    FOR DELETE USING (
      can_access_student(student_id)
      AND current_user_role() = ANY (ARRAY['counselor'::user_role, 'admin'::user_role])
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_college_suggestions_student_id ON college_suggestions USING btree (student_id);
CREATE INDEX IF NOT EXISTS idx_college_suggestions_status ON college_suggestions USING btree (status) WHERE status = 'pending';
