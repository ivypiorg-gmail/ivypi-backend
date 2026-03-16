create extension if not exists "pg_cron" with schema "pg_catalog";

drop extension if exists "pg_net";

create extension if not exists "pg_net" with schema "public";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.can_access_student(p_student_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_role   TEXT;
  v_uid    UUID;
  v_match  BOOLEAN;
BEGIN
  v_uid  := auth.uid();
  v_role := public.current_user_role();

  -- Admins can access all students
  IF v_role = 'admin' THEN
    RETURN TRUE;
  END IF;

  -- Check if caller is the student or the assigned counselor
  SELECT EXISTS(
    SELECT 1 FROM public.students
    WHERE id = p_student_id
      AND (user_id = v_uid OR counselor_id = v_uid)
  ) INTO v_match;

  RETURN v_match;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.current_user_role()
 RETURNS public.user_role
 LANGUAGE sql
 STABLE
AS $function$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.get_available_slots(p_counselor_id uuid, p_start_date date, p_end_date date)
 RETURNS TABLE(slot_date date, start_time time without time zone, end_time time without time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_invite_exists BOOLEAN;
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM public.counselor_invites
    WHERE email = NEW.email AND status = 'pending'
  ) INTO v_invite_exists;

  INSERT INTO public.profiles (id, full_name, avatar_url, role, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture', ''),
    CASE WHEN v_invite_exists THEN 'counselor'::public.user_role ELSE 'student_parent'::public.user_role END,
    NEW.email
  );

  IF v_invite_exists THEN
    UPDATE public.counselor_invites
    SET status = 'accepted', accepted_at = now()
    WHERE email = NEW.email AND status = 'pending';
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;


