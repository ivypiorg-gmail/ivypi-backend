-- Backend cleanup: drop dead infrastructure, consolidate triggers, simplify RLS
-- Addresses high & medium priority items from backend audit (2026-03-20)

------------------------------------------------------------------------
-- A) Drop school_knowledge_chunks table + pgvector extension
------------------------------------------------------------------------

-- Table drop cascades: primary key, index, trigger, RLS policies
DROP TABLE IF EXISTS public.school_knowledge_chunks CASCADE;

-- pgvector was only used by school_knowledge_chunks
DROP EXTENSION IF EXISTS vector CASCADE;

------------------------------------------------------------------------
-- B) Consolidate trigger functions: update_updated_at() → set_updated_at()
--    Both are identical; standardize on set_updated_at().
------------------------------------------------------------------------

-- Drop and recreate each trigger to use set_updated_at()

-- bookings
DROP TRIGGER IF EXISTS bookings_updated_at ON public.bookings;
CREATE TRIGGER bookings_updated_at
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- profiles
DROP TRIGGER IF EXISTS profiles_updated_at ON public.profiles;
CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- college_lists
DROP TRIGGER IF EXISTS set_college_lists_updated_at ON public.college_lists;
CREATE TRIGGER set_college_lists_updated_at
  BEFORE UPDATE ON public.college_lists
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- students
DROP TRIGGER IF EXISTS set_students_updated_at ON public.students;
CREATE TRIGGER set_students_updated_at
  BEFORE UPDATE ON public.students
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- universities
DROP TRIGGER IF EXISTS set_universities_updated_at ON public.universities;
CREATE TRIGGER set_universities_updated_at
  BEFORE UPDATE ON public.universities
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- action_items
DROP TRIGGER IF EXISTS update_action_items_updated_at ON public.action_items;
CREATE TRIGGER set_action_items_updated_at
  BEFORE UPDATE ON public.action_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- comments
DROP TRIGGER IF EXISTS update_comments_updated_at ON public.comments;
CREATE TRIGGER set_comments_updated_at
  BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- google_calendar_tokens
DROP TRIGGER IF EXISTS update_google_calendar_tokens_updated_at ON public.google_calendar_tokens;
CREATE TRIGGER set_google_calendar_tokens_updated_at
  BEFORE UPDATE ON public.google_calendar_tokens
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- narrative_annotations
DROP TRIGGER IF EXISTS update_narrative_annotations_updated_at ON public.narrative_annotations;
CREATE TRIGGER set_narrative_annotations_updated_at
  BEFORE UPDATE ON public.narrative_annotations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- narrative_arcs
DROP TRIGGER IF EXISTS update_narrative_arcs_updated_at ON public.narrative_arcs;
CREATE TRIGGER set_narrative_arcs_updated_at
  BEFORE UPDATE ON public.narrative_arcs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- session_notes
DROP TRIGGER IF EXISTS update_session_notes_updated_at ON public.session_notes;
CREATE TRIGGER set_session_notes_updated_at
  BEFORE UPDATE ON public.session_notes
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- portfolio_alerts (created in recent migration with update_updated_at)
DROP TRIGGER IF EXISTS set_portfolio_alerts_updated_at ON public.portfolio_alerts;
CREATE TRIGGER set_portfolio_alerts_updated_at
  BEFORE UPDATE ON public.portfolio_alerts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Now safe to drop the legacy function
DROP FUNCTION IF EXISTS public.update_updated_at();

------------------------------------------------------------------------
-- C) Simplify RLS policies
------------------------------------------------------------------------

-- C1) bookings: drop redundant admin SELECT (the ALL policy covers it)
DROP POLICY IF EXISTS "Admins can read all bookings" ON public.bookings;

-- C2) action_items: consolidate 4 counselor policies into 1 FOR ALL
DROP POLICY IF EXISTS "Counselors can read action items" ON public.action_items;
DROP POLICY IF EXISTS "Counselors can insert action items" ON public.action_items;
DROP POLICY IF EXISTS "Counselors can update action items" ON public.action_items;
DROP POLICY IF EXISTS "Counselors can delete action items" ON public.action_items;

CREATE POLICY "Counselors can manage action items"
  ON public.action_items FOR ALL
  USING (counselor_id = auth.uid())
  WITH CHECK (counselor_id = auth.uid());

-- C3) session_notes: consolidate 4 counselor policies into 1 FOR ALL
DROP POLICY IF EXISTS "Counselors can read session notes" ON public.session_notes;
DROP POLICY IF EXISTS "Counselors can insert session notes" ON public.session_notes;
DROP POLICY IF EXISTS "Counselors can update session notes" ON public.session_notes;
DROP POLICY IF EXISTS "Counselors can delete session notes" ON public.session_notes;

CREATE POLICY "Counselors can manage session notes"
  ON public.session_notes FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.id = session_notes.booking_id
      AND b.counselor_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.id = session_notes.booking_id
      AND b.counselor_id = auth.uid()
  ));

-- C4) activities: consolidate 4 policies into 1 FOR ALL
DROP POLICY IF EXISTS "Users can view own activities" ON public.activities;
DROP POLICY IF EXISTS "Users can insert activities for accessible students" ON public.activities;
DROP POLICY IF EXISTS "Users can update activities for accessible students" ON public.activities;
DROP POLICY IF EXISTS "Users can delete activities for accessible students" ON public.activities;

CREATE POLICY "Users can manage activities for accessible students"
  ON public.activities FOR ALL
  USING (can_access_student(student_id))
  WITH CHECK (can_access_student(student_id));

-- C5) awards: consolidate 4 policies into 1 FOR ALL
DROP POLICY IF EXISTS "Users can view awards for accessible students" ON public.awards;
DROP POLICY IF EXISTS "Users can insert awards for accessible students" ON public.awards;
DROP POLICY IF EXISTS "Users can update awards for accessible students" ON public.awards;
DROP POLICY IF EXISTS "Users can delete awards for accessible students" ON public.awards;

CREATE POLICY "Users can manage awards for accessible students"
  ON public.awards FOR ALL
  USING (can_access_student(student_id))
  WITH CHECK (can_access_student(student_id));

-- C6) courses: consolidate 4 policies into 1 FOR ALL
DROP POLICY IF EXISTS "Users can view own courses" ON public.courses;
DROP POLICY IF EXISTS "Users can insert courses for accessible students" ON public.courses;
DROP POLICY IF EXISTS "Users can update courses for accessible students" ON public.courses;
DROP POLICY IF EXISTS "Users can delete courses for accessible students" ON public.courses;

CREATE POLICY "Users can manage courses for accessible students"
  ON public.courses FOR ALL
  USING (can_access_student(student_id))
  WITH CHECK (can_access_student(student_id));

-- C7) documents: consolidate 4 policies into 1 FOR ALL
DROP POLICY IF EXISTS "Users can view own documents" ON public.documents;
DROP POLICY IF EXISTS "Users can upload documents" ON public.documents;
DROP POLICY IF EXISTS "Users can update own documents" ON public.documents;
DROP POLICY IF EXISTS "Users can delete own documents" ON public.documents;

CREATE POLICY "Users can manage documents for accessible students"
  ON public.documents FOR ALL
  USING (can_access_student(student_id))
  WITH CHECK (can_access_student(student_id));
