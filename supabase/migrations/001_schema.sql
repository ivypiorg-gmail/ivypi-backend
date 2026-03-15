-- IvyPi Scheduling System Schema
-- Run in Supabase SQL Editor or via supabase db push

-- ══════════════════════════════════════════════════════════════
-- 1. CUSTOM TYPES
-- ══════════════════════════════════════════════════════════════

CREATE TYPE public.user_role AS ENUM ('student_parent', 'counselor', 'admin');
CREATE TYPE public.booking_status AS ENUM ('confirmed', 'cancelled_by_client', 'cancelled_by_counselor', 'completed', 'no_show');
CREATE TYPE public.recurrence_type AS ENUM ('none', 'weekly', 'biweekly');
CREATE TYPE public.notification_type AS ENUM ('confirmation', 'reminder_24h', 'cancellation');

-- ══════════════════════════════════════════════════════════════
-- 2. TABLES
-- ══════════════════════════════════════════════════════════════

-- Profiles — extends auth.users
CREATE TABLE public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role        public.user_role NOT NULL DEFAULT 'student_parent',
  full_name   TEXT NOT NULL DEFAULT '',
  phone       TEXT,
  timezone    TEXT NOT NULL DEFAULT 'America/Los_Angeles',
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Availability windows — counselor weekly schedule
CREATE TABLE public.availability_windows (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  counselor_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  day_of_week   SMALLINT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6), -- 0=Sun
  start_time    TIME NOT NULL,
  end_time      TIME NOT NULL,
  slot_duration SMALLINT NOT NULL DEFAULT 60, -- minutes
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT valid_time_range CHECK (end_time > start_time)
);

-- Availability overrides — one-off blocks or extra openings
CREATE TABLE public.availability_overrides (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  counselor_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  override_date DATE NOT NULL,
  start_time    TIME,          -- null = full day
  end_time      TIME,          -- null = full day
  is_available  BOOLEAN NOT NULL DEFAULT false,
  reason        TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Bookings — appointments
CREATE TABLE public.bookings (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id           UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  counselor_id        UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  starts_at           TIMESTAMPTZ NOT NULL,
  ends_at             TIMESTAMPTZ NOT NULL,
  status              public.booking_status NOT NULL DEFAULT 'confirmed',
  recurrence          public.recurrence_type NOT NULL DEFAULT 'none',
  recurrence_group_id UUID,
  notes               TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT valid_booking_range CHECK (ends_at > starts_at)
);

-- Notifications log — email audit trail
CREATE TABLE public.notifications_log (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES public.bookings(id) ON DELETE SET NULL,
  type       public.notification_type NOT NULL,
  recipient  TEXT NOT NULL,
  sent_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  status     TEXT NOT NULL DEFAULT 'sent'
);

-- Indexes
CREATE INDEX idx_availability_windows_counselor ON public.availability_windows(counselor_id);
CREATE INDEX idx_availability_overrides_counselor_date ON public.availability_overrides(counselor_id, override_date);
CREATE INDEX idx_bookings_counselor_starts ON public.bookings(counselor_id, starts_at);
CREATE INDEX idx_bookings_client ON public.bookings(client_id);
CREATE INDEX idx_bookings_recurrence_group ON public.bookings(recurrence_group_id) WHERE recurrence_group_id IS NOT NULL;
CREATE INDEX idx_notifications_booking ON public.notifications_log(booking_id);

-- ══════════════════════════════════════════════════════════════
-- 3. AUTO-CREATE PROFILE ON SIGNUP
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, avatar_url)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture', '')
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER bookings_updated_at
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ══════════════════════════════════════════════════════════════
-- 4. GET AVAILABLE SLOTS FUNCTION
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_available_slots(
  p_counselor_id UUID,
  p_start_date   DATE,
  p_end_date     DATE
)
RETURNS TABLE (slot_date DATE, start_time TIME, end_time TIME)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  d DATE;
  dow SMALLINT;
  win RECORD;
  slot_start TIME;
  slot_end TIME;
BEGIN
  -- Loop through each date in the range
  FOR d IN SELECT generate_series(p_start_date, p_end_date, '1 day'::interval)::date
  LOOP
    dow := EXTRACT(DOW FROM d)::smallint;

    -- Check if entire day is blocked by override
    IF EXISTS (
      SELECT 1 FROM public.availability_overrides ao
      WHERE ao.counselor_id = p_counselor_id
        AND ao.override_date = d
        AND ao.is_available = false
        AND ao.start_time IS NULL
    ) THEN
      CONTINUE;
    END IF;

    -- Generate slots from availability windows for this day
    FOR win IN
      SELECT aw.start_time AS w_start, aw.end_time AS w_end, aw.slot_duration
      FROM public.availability_windows aw
      WHERE aw.counselor_id = p_counselor_id
        AND aw.day_of_week = dow
        AND aw.is_active = true
    LOOP
      slot_start := win.w_start;
      WHILE slot_start + (win.slot_duration || ' minutes')::interval <= win.w_end LOOP
        slot_end := (slot_start + (win.slot_duration || ' minutes')::interval)::time;

        -- Skip if blocked by partial override
        IF NOT EXISTS (
          SELECT 1 FROM public.availability_overrides ao
          WHERE ao.counselor_id = p_counselor_id
            AND ao.override_date = d
            AND ao.is_available = false
            AND ao.start_time IS NOT NULL
            AND slot_start < ao.end_time
            AND slot_end > ao.start_time
        )
        -- Skip if already booked
        AND NOT EXISTS (
          SELECT 1 FROM public.bookings b
          WHERE b.counselor_id = p_counselor_id
            AND b.status = 'confirmed'
            AND b.starts_at < (d + slot_end)::timestamptz
            AND b.ends_at > (d + slot_start)::timestamptz
        )
        THEN
          slot_date := d;
          start_time := slot_start;
          end_time := slot_end;
          RETURN NEXT;
        END IF;

        slot_start := slot_end;
      END LOOP;
    END LOOP;

    -- Also include extra slots from "available" overrides
    FOR win IN
      SELECT ao.start_time AS w_start, ao.end_time AS w_end
      FROM public.availability_overrides ao
      WHERE ao.counselor_id = p_counselor_id
        AND ao.override_date = d
        AND ao.is_available = true
        AND ao.start_time IS NOT NULL
    LOOP
      -- Use default 60-minute slots for override windows
      slot_start := win.w_start;
      WHILE slot_start + '60 minutes'::interval <= win.w_end LOOP
        slot_end := (slot_start + '60 minutes'::interval)::time;

        IF NOT EXISTS (
          SELECT 1 FROM public.bookings b
          WHERE b.counselor_id = p_counselor_id
            AND b.status = 'confirmed'
            AND b.starts_at < (d + slot_end)::timestamptz
            AND b.ends_at > (d + slot_start)::timestamptz
        )
        THEN
          slot_date := d;
          start_time := slot_start;
          end_time := slot_end;
          RETURN NEXT;
        END IF;

        slot_start := slot_end;
      END LOOP;
    END LOOP;
  END LOOP;
END;
$$;

-- ══════════════════════════════════════════════════════════════
-- 5. ROW LEVEL SECURITY
-- ══════════════════════════════════════════════════════════════

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.availability_windows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.availability_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications_log ENABLE ROW LEVEL SECURITY;

-- Helper: get current user's role
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

-- ── PROFILES ──

CREATE POLICY "Anyone can read profiles"
  ON public.profiles FOR SELECT
  USING (true);

CREATE POLICY "Users can update own profile (not role)"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid() AND role = (SELECT role FROM public.profiles WHERE id = auth.uid()));

CREATE POLICY "Admins can update any profile"
  ON public.profiles FOR UPDATE
  USING (public.current_user_role() = 'admin');

-- ── AVAILABILITY WINDOWS ──

CREATE POLICY "Anyone can read availability"
  ON public.availability_windows FOR SELECT
  USING (true);

CREATE POLICY "Counselors can manage own availability"
  ON public.availability_windows FOR ALL
  USING (counselor_id = auth.uid() AND public.current_user_role() = 'counselor')
  WITH CHECK (counselor_id = auth.uid());

CREATE POLICY "Admins can manage all availability"
  ON public.availability_windows FOR ALL
  USING (public.current_user_role() = 'admin');

-- ── AVAILABILITY OVERRIDES ──

CREATE POLICY "Anyone can read overrides"
  ON public.availability_overrides FOR SELECT
  USING (true);

CREATE POLICY "Counselors can manage own overrides"
  ON public.availability_overrides FOR ALL
  USING (counselor_id = auth.uid() AND public.current_user_role() = 'counselor')
  WITH CHECK (counselor_id = auth.uid());

CREATE POLICY "Admins can manage all overrides"
  ON public.availability_overrides FOR ALL
  USING (public.current_user_role() = 'admin');

-- ── BOOKINGS ──

CREATE POLICY "Clients can read own bookings"
  ON public.bookings FOR SELECT
  USING (client_id = auth.uid());

CREATE POLICY "Counselors can read assigned bookings"
  ON public.bookings FOR SELECT
  USING (counselor_id = auth.uid());

CREATE POLICY "Admins can read all bookings"
  ON public.bookings FOR SELECT
  USING (public.current_user_role() = 'admin');

CREATE POLICY "Clients can create bookings"
  ON public.bookings FOR INSERT
  WITH CHECK (client_id = auth.uid() AND public.current_user_role() = 'student_parent');

CREATE POLICY "Clients can cancel own bookings"
  ON public.bookings FOR UPDATE
  USING (client_id = auth.uid())
  WITH CHECK (client_id = auth.uid() AND status IN ('cancelled_by_client'));

CREATE POLICY "Counselors can update assigned bookings"
  ON public.bookings FOR UPDATE
  USING (counselor_id = auth.uid())
  WITH CHECK (counselor_id = auth.uid());

CREATE POLICY "Admins can manage all bookings"
  ON public.bookings FOR ALL
  USING (public.current_user_role() = 'admin');

-- ── NOTIFICATIONS LOG ──

CREATE POLICY "Admins can read notifications"
  ON public.notifications_log FOR SELECT
  USING (public.current_user_role() = 'admin');
