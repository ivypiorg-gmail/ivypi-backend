-- ============================================================================
-- When2Meet-Style Mutual Availability Scheduling
-- Replaces availability_windows/overrides with per-slot availability model.
-- Adds booking_students junction table for multi-student sessions.
-- ============================================================================

-- ============================================================================
-- 1. availability_slots — individual 30-min availability slots
-- ============================================================================
CREATE TABLE public.availability_slots (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_type TEXT NOT NULL CHECK (owner_type IN ('counselor', 'student')),
  owner_id   UUID NOT NULL,
  slot_date  DATE NOT NULL,
  slot_start TIME NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  UNIQUE (owner_type, owner_id, slot_date, slot_start)
);

CREATE INDEX idx_availability_slots_owner
  ON public.availability_slots (owner_type, owner_id, slot_date);

ALTER TABLE public.availability_slots ENABLE ROW LEVEL SECURITY;

-- Admins can manage all
CREATE POLICY "Admins can manage availability slots"
  ON public.availability_slots FOR ALL
  USING (current_user_role() = 'admin'::user_role)
  WITH CHECK (current_user_role() = 'admin'::user_role);

-- Counselors manage own slots
CREATE POLICY "Counselors manage own availability slots"
  ON public.availability_slots FOR ALL
  USING (owner_type = 'counselor' AND owner_id = auth.uid())
  WITH CHECK (owner_type = 'counselor' AND owner_id = auth.uid());

-- Parents manage child slots
CREATE POLICY "Parents manage child availability slots"
  ON public.availability_slots FOR ALL
  USING (
    owner_type = 'student'
    AND owner_id IN (SELECT id FROM public.students WHERE user_id = auth.uid())
  )
  WITH CHECK (
    owner_type = 'student'
    AND owner_id IN (SELECT id FROM public.students WHERE user_id = auth.uid())
  );

-- Counselors read student slots (for assigned students)
CREATE POLICY "Counselors read student availability slots"
  ON public.availability_slots FOR SELECT
  USING (
    owner_type = 'student'
    AND owner_id IN (SELECT id FROM public.students WHERE counselor_id = auth.uid())
  );

-- Parents read counselor slots (for their child's counselor)
CREATE POLICY "Parents read counselor availability slots"
  ON public.availability_slots FOR SELECT
  USING (
    owner_type = 'counselor'
    AND owner_id IN (
      SELECT DISTINCT counselor_id FROM public.students WHERE user_id = auth.uid()
    )
  );

GRANT ALL ON TABLE public.availability_slots TO anon;
GRANT ALL ON TABLE public.availability_slots TO authenticated;
GRANT ALL ON TABLE public.availability_slots TO service_role;

-- ============================================================================
-- 2. booking_students — junction table for multi-student sessions
-- ============================================================================
CREATE TABLE public.booking_students (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  booking_id UUID NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  UNIQUE (booking_id, student_id)
);

CREATE INDEX idx_booking_students_booking ON public.booking_students (booking_id);
CREATE INDEX idx_booking_students_student ON public.booking_students (student_id);

ALTER TABLE public.booking_students ENABLE ROW LEVEL SECURITY;

-- Admins can manage all
CREATE POLICY "Admins can manage booking students"
  ON public.booking_students FOR ALL
  USING (current_user_role() = 'admin'::user_role)
  WITH CHECK (current_user_role() = 'admin'::user_role);

-- Counselors can manage (for their assigned students)
CREATE POLICY "Counselors can manage booking students"
  ON public.booking_students FOR ALL
  USING (
    current_user_role() = 'counselor'::user_role
    AND can_access_student(student_id)
  )
  WITH CHECK (
    current_user_role() = 'counselor'::user_role
    AND can_access_student(student_id)
  );

-- Parents can read (for their children)
CREATE POLICY "Parents can read booking students"
  ON public.booking_students FOR SELECT
  USING (can_access_student(student_id));

GRANT ALL ON TABLE public.booking_students TO anon;
GRANT ALL ON TABLE public.booking_students TO authenticated;
GRANT ALL ON TABLE public.booking_students TO service_role;

-- ============================================================================
-- 3. get_overlap_slots RPC — finds mutual availability
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_overlap_slots(
  p_counselor_id UUID,
  p_student_id   UUID,
  p_start_date   DATE,
  p_end_date     DATE
) RETURNS TABLE (slot_date DATE, slot_start TIME)
LANGUAGE sql STABLE
AS $$
  SELECT c.slot_date, c.slot_start
  FROM public.availability_slots c
  JOIN public.availability_slots s
    ON  s.slot_date  = c.slot_date
    AND s.slot_start = c.slot_start
  WHERE c.owner_type = 'counselor'
    AND c.owner_id   = p_counselor_id
    AND s.owner_type = 'student'
    AND s.owner_id   = p_student_id
    AND c.slot_date BETWEEN p_start_date AND p_end_date
    -- Exclude slots where a confirmed booking already exists.
    AND NOT EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.counselor_id = p_counselor_id
        AND b.status = 'confirmed'
        AND (c.slot_date + c.slot_start) AT TIME ZONE 'UTC' < b.ends_at
        AND (c.slot_date + c.slot_start + interval '30 minutes') AT TIME ZONE 'UTC' > b.starts_at
    )
  ORDER BY c.slot_date, c.slot_start;
$$;

GRANT EXECUTE ON FUNCTION public.get_overlap_slots(UUID, UUID, DATE, DATE) TO authenticated;

-- ============================================================================
-- 4. pg_cron job to clean expired slots daily
-- ============================================================================
-- Note: pg_cron must be enabled in Supabase dashboard (Database > Extensions).
-- If pg_cron is not available, expired slots are harmless (the grid only shows
-- today onward) but will accumulate.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'cleanup-expired-availability-slots',
      '0 3 * * *', -- daily at 3 AM UTC
      'DELETE FROM public.availability_slots WHERE slot_date < (now() AT TIME ZONE ''UTC'')::date'
    );
  END IF;
END $$;

-- ============================================================================
-- 5. Drop old availability tables and function
-- ============================================================================
DROP TABLE IF EXISTS public.availability_overrides;
DROP TABLE IF EXISTS public.availability_windows;
DROP FUNCTION IF EXISTS public.get_available_slots(UUID, DATE, DATE);
