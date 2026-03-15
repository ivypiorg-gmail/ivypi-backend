-- Counselor Invite Flow
-- Allows admins to invite counselors by email.
-- New signups matching a pending invite auto-receive counselor role.

-- ══════════════════════════════════════════════════════════════
-- 1. COUNSELOR INVITES TABLE
-- ══════════════════════════════════════════════════════════════

CREATE TABLE public.counselor_invites (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT NOT NULL,
  invited_by  UUID NOT NULL REFERENCES public.profiles(id),
  token       TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32), 'hex'),
  status      TEXT NOT NULL DEFAULT 'pending',  -- pending | accepted | expired
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at TIMESTAMPTZ
);

CREATE INDEX idx_counselor_invites_email ON public.counselor_invites(email);
CREATE INDEX idx_counselor_invites_token ON public.counselor_invites(token);
CREATE UNIQUE INDEX idx_counselor_invites_pending ON public.counselor_invites(email) WHERE status = 'pending';

-- ══════════════════════════════════════════════════════════════
-- 2. RLS POLICIES
-- ══════════════════════════════════════════════════════════════

ALTER TABLE public.counselor_invites ENABLE ROW LEVEL SECURITY;

-- Admins have full access
CREATE POLICY "Admins can manage invites"
  ON public.counselor_invites FOR ALL
  USING (public.current_user_role() = 'admin');

-- Anyone can look up a pending invite by token (for the signup page)
CREATE POLICY "Public can verify pending invite"
  ON public.counselor_invites FOR SELECT
  USING (status = 'pending');

-- ══════════════════════════════════════════════════════════════
-- 3. UPDATE handle_new_user() TO CHECK INVITES
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_invite_exists BOOLEAN;
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM public.counselor_invites
    WHERE email = NEW.email AND status = 'pending'
  ) INTO v_invite_exists;

  INSERT INTO public.profiles (id, full_name, avatar_url, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture', ''),
    CASE WHEN v_invite_exists THEN 'counselor'::public.user_role ELSE 'student_parent'::public.user_role END
  );

  IF v_invite_exists THEN
    UPDATE public.counselor_invites
    SET status = 'accepted', accepted_at = now()
    WHERE email = NEW.email AND status = 'pending';
  END IF;

  RETURN NEW;
END;
$$;
