-- Step 1: Remove abandoned proposed/declined enum values and proposed_by column

-- Safety guard: abort if any rows use proposed or declined
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE status IN ('proposed'::public.booking_status, 'declined'::public.booking_status)
  ) THEN
    RAISE EXCEPTION 'Cannot remove proposed/declined: rows with these statuses still exist';
  END IF;
END $$;

-- Drop the proposed_by column and its FK
ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_proposed_by_fkey;
ALTER TABLE public.bookings DROP COLUMN IF EXISTS proposed_by;

-- Drop RLS policies that reference the booking_status type
DROP POLICY IF EXISTS "Clients can cancel own bookings" ON public.bookings;

-- Recreate enum without proposed/declined
ALTER TYPE public.booking_status RENAME TO booking_status_old;

CREATE TYPE public.booking_status AS ENUM (
  'confirmed',
  'cancelled_by_client',
  'cancelled_by_counselor',
  'completed',
  'no_show'
);

ALTER TABLE public.bookings
  ALTER COLUMN status DROP DEFAULT,
  ALTER COLUMN status TYPE public.booking_status USING status::text::public.booking_status,
  ALTER COLUMN status SET DEFAULT 'confirmed'::public.booking_status;

DROP TYPE public.booking_status_old;

-- Recreate the dropped policy with the new type
CREATE POLICY "Clients can cancel own bookings" ON public.bookings
  FOR UPDATE
  USING (client_id = auth.uid())
  WITH CHECK (client_id = auth.uid() AND status = 'cancelled_by_client'::public.booking_status);
