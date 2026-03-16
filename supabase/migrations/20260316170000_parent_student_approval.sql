-- Add pending_approval to student_status enum
ALTER TYPE student_status ADD VALUE IF NOT EXISTS 'pending_approval';

-- Drop unique constraint on user_id to allow multiple students per parent
ALTER TABLE public.students DROP CONSTRAINT IF EXISTS students_user_id_key;

-- Parents can insert their own students (must be pending_approval)
CREATE POLICY "Parents can insert students"
  ON public.students FOR INSERT
  WITH CHECK (
    public.current_user_role() = 'student_parent'
    AND user_id = auth.uid()
    AND status = 'pending_approval'
  );

-- Parents can update their own unassigned pending students (for re-requesting counselor)
CREATE POLICY "Parents can update unassigned students"
  ON public.students FOR UPDATE
  USING (
    public.current_user_role() = 'student_parent'
    AND user_id = auth.uid()
    AND counselor_id IS NULL
    AND status = 'pending_approval'
  )
  WITH CHECK (
    public.current_user_role() = 'student_parent'
    AND user_id = auth.uid()
    AND status = 'pending_approval'
  );
