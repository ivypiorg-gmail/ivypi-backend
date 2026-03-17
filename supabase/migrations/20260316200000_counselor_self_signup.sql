-- Add pending_counselor to user_role enum
-- NOTE: ALTER TYPE ... ADD VALUE cannot run inside a transaction block.
-- Supabase migrations run each file as a single transaction by default,
-- but ADD VALUE is special-cased to work outside transactions in Postgres 12+.
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'pending_counselor';

-- Update handle_new_user() to support counselor self-signup
CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_invite_exists BOOLEAN;
  v_requested_role TEXT;
  v_role public.user_role;
  v_supabase_url TEXT;
  v_service_role_key TEXT;
  v_request_id BIGINT;
BEGIN
  -- 1. Check for pending counselor invite
  SELECT EXISTS(
    SELECT 1 FROM public.counselor_invites
    WHERE email = NEW.email AND status = 'pending'
  ) INTO v_invite_exists;

  -- 2. Determine role
  IF v_invite_exists THEN
    v_role := 'counselor'::public.user_role;
  ELSE
    v_requested_role := NEW.raw_user_meta_data ->> 'requested_role';
    IF v_requested_role = 'counselor' THEN
      v_role := 'pending_counselor'::public.user_role;
    ELSE
      v_role := 'student_parent'::public.user_role;
    END IF;
  END IF;

  -- 3. Create profile
  INSERT INTO public.profiles (id, full_name, avatar_url, role, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture', ''),
    v_role,
    NEW.email
  );

  -- 4. Write role to user_metadata so middleware can read without DB query
  UPDATE auth.users
  SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('role', v_role::text)
  WHERE id = NEW.id;

  -- 5. Accept invite if applicable
  IF v_invite_exists THEN
    UPDATE public.counselor_invites
    SET status = 'accepted', accepted_at = now()
    WHERE email = NEW.email AND status = 'pending';
  END IF;

  -- 6. Notify admins if pending counselor (using Vault secrets, matching auth email hook pattern)
  IF v_role = 'pending_counselor'::public.user_role THEN
    SELECT decrypted_secret INTO v_supabase_url
    FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1;

    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;

    IF v_supabase_url IS NOT NULL AND v_service_role_key IS NOT NULL THEN
      SELECT net.http_post(
        url := v_supabase_url || '/functions/v1/notify-counselor-request',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_service_role_key
        ),
        body := jsonb_build_object(
          'user_id', NEW.id,
          'email', NEW.email,
          'full_name', COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name', '')
        ),
        timeout_milliseconds := 5000
      ) INTO v_request_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
