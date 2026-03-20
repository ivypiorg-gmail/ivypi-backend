


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE TYPE "public"."action_item_status" AS ENUM (
    'open',
    'in_progress',
    'done'
);


ALTER TYPE "public"."action_item_status" OWNER TO "postgres";


CREATE TYPE "public"."activity_category" AS ENUM (
    'academic',
    'arts',
    'athletics',
    'community_service',
    'leadership',
    'work',
    'research',
    'other'
);


ALTER TYPE "public"."activity_category" OWNER TO "postgres";


CREATE TYPE "public"."app_status" AS ENUM (
    'considering',
    'applying',
    'applied',
    'accepted',
    'rejected',
    'waitlisted',
    'deferred',
    'committed'
);


ALTER TYPE "public"."app_status" OWNER TO "postgres";


CREATE TYPE "public"."booking_status" AS ENUM (
    'confirmed',
    'cancelled_by_client',
    'cancelled_by_counselor',
    'completed',
    'no_show'
);


ALTER TYPE "public"."booking_status" OWNER TO "postgres";


CREATE TYPE "public"."course_level" AS ENUM (
    'regular',
    'honors',
    'ap',
    'ib',
    'dual_enrollment',
    'other'
);


ALTER TYPE "public"."course_level" OWNER TO "postgres";


CREATE TYPE "public"."course_type" AS ENUM (
    'high_school',
    'college',
    'online'
);


ALTER TYPE "public"."course_type" OWNER TO "postgres";


CREATE TYPE "public"."depth_tier" AS ENUM (
    'exceptional',
    'strong',
    'moderate',
    'introductory'
);


ALTER TYPE "public"."depth_tier" OWNER TO "postgres";


CREATE TYPE "public"."document_type" AS ENUM (
    'transcript',
    'resume',
    'activity_list',
    'document'
);


ALTER TYPE "public"."document_type" OWNER TO "postgres";


CREATE TYPE "public"."narrative_stage" AS ENUM (
    'academic',
    'activities',
    'full'
);


ALTER TYPE "public"."narrative_stage" OWNER TO "postgres";


CREATE TYPE "public"."notification_type" AS ENUM (
    'confirmation',
    'reminder_24h',
    'cancellation',
    'reminder_30m',
    'deadline_reminder_7d',
    'deadline_reminder_2d'
);


ALTER TYPE "public"."notification_type" OWNER TO "postgres";


CREATE TYPE "public"."parse_status" AS ENUM (
    'pending',
    'processing',
    'complete',
    'failed'
);


ALTER TYPE "public"."parse_status" OWNER TO "postgres";


CREATE TYPE "public"."recurrence_type" AS ENUM (
    'none',
    'weekly',
    'biweekly'
);


ALTER TYPE "public"."recurrence_type" OWNER TO "postgres";


CREATE TYPE "public"."student_status" AS ENUM (
    'active',
    'inactive',
    'graduated',
    'deferred',
    'pending_approval'
);


ALTER TYPE "public"."student_status" OWNER TO "postgres";


CREATE TYPE "public"."subject_area" AS ENUM (
    'math',
    'science',
    'english',
    'history',
    'foreign_language',
    'arts',
    'computer_science',
    'social_science',
    'other'
);


ALTER TYPE "public"."subject_area" OWNER TO "postgres";


CREATE TYPE "public"."user_role" AS ENUM (
    'student_parent',
    'counselor',
    'admin',
    'pending_counselor'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."append_oracle_messages"("conv_id" "uuid", "new_messages" "jsonb") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  UPDATE campus_oracle_conversations
  SET messages = messages || new_messages, updated_at = now()
  WHERE id = conv_id;
$$;


ALTER FUNCTION "public"."append_oracle_messages"("conv_id" "uuid", "new_messages" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_access_student"("p_student_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
$$;


ALTER FUNCTION "public"."can_access_student"("p_student_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_role"() RETURNS "public"."user_role"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;


ALTER FUNCTION "public"."current_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_comments_for_target"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  DELETE FROM comments
  WHERE target_type = TG_ARGV[0] AND target_id = OLD.id;
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."delete_comments_for_target"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."derive_application_cycle"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.application_cycle IS NULL AND NEW.grad_year IS NOT NULL THEN
    NEW.application_cycle := NEW.grad_year;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."derive_application_cycle"() OWNER TO "postgres";


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


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_timeline_stale"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE strategic_timelines SET stale = true
  WHERE student_id = COALESCE(NEW.student_id, OLD.student_id);
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."mark_timeline_stale"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_auth_email"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  edge_function_url text;
  service_role_key text;
  request_id bigint;
begin
  -- Build the edge function URL from vault secrets / config
  edge_function_url := (
    select decrypted_secret
    from vault.decrypted_secrets
    where name = 'supabase_url'
    limit 1
  );

  -- Fallback: construct from project ref if vault secret not available
  if edge_function_url is null then
    edge_function_url := 'https://gybkzyjtqhvxbuqzqanp.supabase.co';
  end if;

  edge_function_url := edge_function_url || '/functions/v1/send-auth-email';

  service_role_key := (
    select decrypted_secret
    from vault.decrypted_secrets
    where name = 'service_role_key'
    limit 1
  );

  -- If no service role key in vault, the hook can't authenticate to the edge function.
  -- Fall back to letting Supabase send the default email.
  if service_role_key is null then
    raise warning 'send_auth_email: service_role_key not found in vault, falling back to default email';
    return event;
  end if;

  -- Fire-and-forget HTTP POST to the edge function
  select net.http_post(
    url := edge_function_url,
    body := event,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    timeout_milliseconds := 5000
  ) into request_id;

  return event;
end;
$$;


ALTER FUNCTION "public"."send_auth_email"("event" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_profile_stale"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE students SET profile_stale = true WHERE id = OLD.student_id;
    RETURN OLD;
  ELSE
    UPDATE students SET profile_stale = true WHERE id = NEW.student_id;
    RETURN NEW;
  END IF;
END;
$$;


ALTER FUNCTION "public"."set_profile_stale"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_profile_stale_on_student_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF (OLD.test_scores IS DISTINCT FROM NEW.test_scores)
     OR (OLD.survey_responses IS DISTINCT FROM NEW.survey_responses) THEN
    NEW.profile_stale := true;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_profile_stale_on_student_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."action_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid",
    "client_id" "uuid" NOT NULL,
    "counselor_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "assigned_to" "uuid",
    "status" "public"."action_item_status" DEFAULT 'open'::"public"."action_item_status" NOT NULL,
    "due_date" "date",
    "sort_order" integer,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."action_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "document_id" "uuid",
    "name" "text" NOT NULL,
    "category" "public"."activity_category" DEFAULT 'other'::"public"."activity_category",
    "role" "text",
    "years_active" integer[],
    "hours_per_week" numeric(4,1),
    "impact_description" "text",
    "depth_tier" "public"."depth_tier",
    "depth_narrative" "text",
    "organization" "text",
    "weeks_per_year" integer,
    "common_app_description" "text",
    "activity_type" "text",
    "sort_order" integer,
    "uc_description" "text",
    "resume_bullets" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_usage_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "function_name" "text" NOT NULL,
    "student_id" "uuid",
    "school_id" "uuid",
    "model" "text" NOT NULL,
    "input_tokens" integer NOT NULL,
    "output_tokens" integer NOT NULL,
    "cost_usd" numeric(10,6),
    "caller_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_usage_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."availability_slots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_type" "text" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "slot_date" "date" NOT NULL,
    "slot_start" time without time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "availability_slots_owner_type_check" CHECK (("owner_type" = ANY (ARRAY['counselor'::"text", 'student'::"text"])))
);


ALTER TABLE "public"."availability_slots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."awards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "level" "text",
    "category" "text",
    "grade_year" integer,
    "description" "text",
    "sort_order" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."awards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_students" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "student_id" "uuid" NOT NULL
);


ALTER TABLE "public"."booking_students" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bookings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "counselor_id" "uuid" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "status" "public"."booking_status" DEFAULT 'confirmed'::"public"."booking_status" NOT NULL,
    "recurrence" "public"."recurrence_type" DEFAULT 'none'::"public"."recurrence_type" NOT NULL,
    "recurrence_group_id" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "google_calendar_event_id" "text",
    CONSTRAINT "valid_booking_range" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."bookings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."campus_oracle_conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "school_name" "text" NOT NULL,
    "messages" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."campus_oracle_conversations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."college_data_corrections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "school_name" "text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "note" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "resolved_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "resolved_at" timestamp with time zone,
    CONSTRAINT "college_data_corrections_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'dismissed'::"text"])))
);


ALTER TABLE "public"."college_data_corrections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."college_lists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "school_name" "text" NOT NULL,
    "affinity_report" "jsonb" DEFAULT '{}'::"jsonb",
    "counselor_notes" "text",
    "app_status" "public"."app_status" DEFAULT 'considering'::"public"."app_status" NOT NULL,
    "decision_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "added_by" "uuid"
);


ALTER TABLE "public"."college_lists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."college_suggestions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "suggested_by" "uuid" NOT NULL,
    "suggestion_type" "text" NOT NULL,
    "school_name" "text",
    "college_list_id" "uuid",
    "suggested_status" "public"."app_status",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    CONSTRAINT "college_suggestions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'dismissed'::"text"]))),
    CONSTRAINT "college_suggestions_suggestion_type_check" CHECK (("suggestion_type" = ANY (ARRAY['add_school'::"text", 'update_status'::"text", 'remove_school'::"text"])))
);


ALTER TABLE "public"."college_suggestions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "target_type" "text",
    "target_id" "uuid",
    "parent_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comments_target_consistency" CHECK ((("target_type" IS NULL) = ("target_id" IS NULL)))
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."counselor_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "invited_by" "uuid" NOT NULL,
    "token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(32), 'hex'::"text") NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_at" timestamp with time zone
);


ALTER TABLE "public"."counselor_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."courses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "document_id" "uuid",
    "name" "text" NOT NULL,
    "subject_area" "public"."subject_area",
    "level" "public"."course_level" DEFAULT 'regular'::"public"."course_level",
    "grade" "text",
    "year" "text",
    "semester" "text",
    "course_type" "public"."course_type" DEFAULT 'high_school'::"public"."course_type",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "type" "public"."document_type" NOT NULL,
    "file_name" "text" NOT NULL,
    "storage_path" "text",
    "file_size" integer,
    "parsed_data" "jsonb" DEFAULT '{}'::"jsonb",
    "parse_status" "public"."parse_status" DEFAULT 'pending'::"public"."parse_status" NOT NULL,
    "parse_error" "text",
    "uploaded_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."google_calendar_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "access_token" "text" NOT NULL,
    "refresh_token" "text" NOT NULL,
    "token_expires_at" timestamp with time zone NOT NULL,
    "calendar_id" "text" DEFAULT 'primary'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."google_calendar_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."narrative_annotations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_key" "text" NOT NULL,
    "body" "text" NOT NULL,
    "audio_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "narrative_annotations_target_type_check" CHECK (("target_type" = ANY (ARRAY['throughline'::"text", 'contradiction'::"text", 'gap'::"text", 'identity_frame'::"text"])))
);


ALTER TABLE "public"."narrative_annotations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."narrative_arcs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "arc" "jsonb" NOT NULL,
    "stage" "public"."narrative_stage" NOT NULL,
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'idle'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "narrative_arcs_status_check" CHECK (("status" = ANY (ARRAY['idle'::"text", 'generating'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."narrative_arcs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid",
    "type" "public"."notification_type" NOT NULL,
    "recipient" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'sent'::"text" NOT NULL,
    "recipient_id" "uuid",
    "channel" "text" DEFAULT 'email'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "student_deadline_id" "uuid"
);


ALTER TABLE "public"."notifications_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "role" "public"."user_role" DEFAULT 'student_parent'::"public"."user_role" NOT NULL,
    "full_name" "text" DEFAULT ''::"text" NOT NULL,
    "phone" "text",
    "timezone" "text" DEFAULT 'America/Los_Angeles'::"text" NOT NULL,
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "email" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scenarios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "modifications" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "projected_insights" "jsonb",
    "projected_affinities" "jsonb",
    "scenario_narrative" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."scenarios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."school_deadlines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "school_name" "text" NOT NULL,
    "deadline_type" "text" NOT NULL,
    "deadline_date" "date" NOT NULL,
    "description" "text",
    "source_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "verified" boolean DEFAULT false NOT NULL,
    "verified_by" "uuid",
    "cycle_year" integer
);


ALTER TABLE "public"."school_deadlines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."school_knowledge_chunks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "school_name" "text" NOT NULL,
    "chunk_type" "text" NOT NULL,
    "content" "text" NOT NULL,
    "embedding" "public"."vector"(1536),
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."school_knowledge_chunks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."school_url_index" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "school_name" "text" NOT NULL,
    "page_type" "text" NOT NULL,
    "url" "text" NOT NULL,
    "label" "text" NOT NULL,
    "last_verified_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."school_url_index" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "summary" "text",
    "discussion_points" "text",
    "next_steps" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."session_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."strategic_timelines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "narrative_brief" "text",
    "risk_flags" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "sequenced_tasks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'idle'::"text" NOT NULL,
    "stale" boolean DEFAULT false NOT NULL,
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "strategic_timelines_status_check" CHECK (("status" = ANY (ARRAY['idle'::"text", 'generating'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."strategic_timelines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_deadlines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "school_deadline_id" "uuid",
    "title" "text" NOT NULL,
    "due_date" "date" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deadline_type" "text",
    "school_name" "text",
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "created_by" "uuid"
);


ALTER TABLE "public"."student_deadlines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."students" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "counselor_id" "uuid",
    "full_name" "text" NOT NULL,
    "grad_year" integer,
    "high_school" "text",
    "gpa_unweighted" numeric(4,2),
    "gpa_weighted" numeric(4,2),
    "test_scores" "jsonb" DEFAULT '{}'::"jsonb",
    "profile_insights" "jsonb" DEFAULT '{}'::"jsonb",
    "status" "public"."student_status" DEFAULT 'active'::"public"."student_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "survey_token" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "survey_responses" "jsonb",
    "survey_completed_at" timestamp with time zone,
    "linkedin_url" "text",
    "personal_website" "text",
    "profile_stale" boolean DEFAULT false NOT NULL,
    "narrative_arc" "jsonb",
    "narrative_arc_generated_at" timestamp with time zone,
    "narrative_arc_shared_keys" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "application_cycle" integer
);


ALTER TABLE "public"."students" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."universities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "url" "text",
    "institution_type" "text",
    "city" "text",
    "state" "text",
    "region" "text",
    "undergraduate_size" integer,
    "acceptance_rates" "jsonb" DEFAULT '{}'::"jsonb",
    "us_news_ranking" "text",
    "qs_world_ranking" integer,
    "majors" "text"[] DEFAULT '{}'::"text"[],
    "major_urls" "jsonb" DEFAULT '{}'::"jsonb",
    "research" "jsonb" DEFAULT '[]'::"jsonb",
    "clubs" "jsonb" DEFAULT '[]'::"jsonb",
    "essay_hooks" "jsonb" DEFAULT '[]'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "universities_institution_type_check" CHECK (("institution_type" = ANY (ARRAY['Private'::"text", 'Public'::"text"])))
);


ALTER TABLE "public"."universities" OWNER TO "postgres";


ALTER TABLE ONLY "public"."action_items"
    ADD CONSTRAINT "action_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_usage_log"
    ADD CONSTRAINT "ai_usage_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."availability_slots"
    ADD CONSTRAINT "availability_slots_owner_type_owner_id_slot_date_slot_start_key" UNIQUE ("owner_type", "owner_id", "slot_date", "slot_start");



ALTER TABLE ONLY "public"."availability_slots"
    ADD CONSTRAINT "availability_slots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."awards"
    ADD CONSTRAINT "awards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."booking_students"
    ADD CONSTRAINT "booking_students_booking_id_student_id_key" UNIQUE ("booking_id", "student_id");



ALTER TABLE ONLY "public"."booking_students"
    ADD CONSTRAINT "booking_students_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campus_oracle_conversations"
    ADD CONSTRAINT "campus_oracle_conversations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campus_oracle_conversations"
    ADD CONSTRAINT "campus_oracle_conversations_unique" UNIQUE ("student_id", "school_name");



ALTER TABLE ONLY "public"."college_data_corrections"
    ADD CONSTRAINT "college_data_corrections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_student_id_school_name_key" UNIQUE ("student_id", "school_name");



ALTER TABLE ONLY "public"."college_suggestions"
    ADD CONSTRAINT "college_suggestions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."counselor_invites"
    ADD CONSTRAINT "counselor_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."counselor_invites"
    ADD CONSTRAINT "counselor_invites_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."google_calendar_tokens"
    ADD CONSTRAINT "google_calendar_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."google_calendar_tokens"
    ADD CONSTRAINT "google_calendar_tokens_user_unique" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."narrative_annotations"
    ADD CONSTRAINT "narrative_annotations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."narrative_arcs"
    ADD CONSTRAINT "narrative_arcs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."narrative_arcs"
    ADD CONSTRAINT "narrative_arcs_student_id_key" UNIQUE ("student_id");



ALTER TABLE ONLY "public"."notifications_log"
    ADD CONSTRAINT "notifications_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scenarios"
    ADD CONSTRAINT "scenarios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."school_deadlines"
    ADD CONSTRAINT "school_deadlines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."school_deadlines"
    ADD CONSTRAINT "school_deadlines_unique_school_type_year" UNIQUE ("school_name", "deadline_type", "cycle_year");



ALTER TABLE ONLY "public"."school_knowledge_chunks"
    ADD CONSTRAINT "school_knowledge_chunks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."school_url_index"
    ADD CONSTRAINT "school_url_index_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."school_url_index"
    ADD CONSTRAINT "school_url_index_unique" UNIQUE ("school_name", "page_type");



ALTER TABLE ONLY "public"."session_notes"
    ADD CONSTRAINT "session_notes_booking_unique" UNIQUE ("booking_id");



ALTER TABLE ONLY "public"."session_notes"
    ADD CONSTRAINT "session_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."strategic_timelines"
    ADD CONSTRAINT "strategic_timelines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."strategic_timelines"
    ADD CONSTRAINT "strategic_timelines_student_unique" UNIQUE ("student_id");



ALTER TABLE ONLY "public"."student_deadlines"
    ADD CONSTRAINT "student_deadlines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_survey_token_key" UNIQUE ("survey_token");



ALTER TABLE ONLY "public"."universities"
    ADD CONSTRAINT "universities_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."universities"
    ADD CONSTRAINT "universities_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_action_items_booking" ON "public"."action_items" USING "btree" ("booking_id");



CREATE INDEX "idx_action_items_client" ON "public"."action_items" USING "btree" ("client_id");



CREATE INDEX "idx_action_items_counselor" ON "public"."action_items" USING "btree" ("counselor_id");



CREATE INDEX "idx_activities_document_id" ON "public"."activities" USING "btree" ("document_id");



CREATE INDEX "idx_activities_student_id" ON "public"."activities" USING "btree" ("student_id");



CREATE INDEX "idx_ai_usage_log_created" ON "public"."ai_usage_log" USING "btree" ("created_at");



CREATE INDEX "idx_ai_usage_log_function" ON "public"."ai_usage_log" USING "btree" ("function_name");



CREATE INDEX "idx_ai_usage_log_student" ON "public"."ai_usage_log" USING "btree" ("student_id");



CREATE INDEX "idx_availability_slots_owner" ON "public"."availability_slots" USING "btree" ("owner_type", "owner_id", "slot_date");



CREATE INDEX "idx_awards_student_id" ON "public"."awards" USING "btree" ("student_id");



CREATE INDEX "idx_booking_students_booking" ON "public"."booking_students" USING "btree" ("booking_id");



CREATE INDEX "idx_booking_students_student" ON "public"."booking_students" USING "btree" ("student_id");



CREATE INDEX "idx_bookings_client" ON "public"."bookings" USING "btree" ("client_id");



CREATE INDEX "idx_bookings_counselor_starts" ON "public"."bookings" USING "btree" ("counselor_id", "starts_at");



CREATE INDEX "idx_bookings_recurrence_group" ON "public"."bookings" USING "btree" ("recurrence_group_id") WHERE ("recurrence_group_id" IS NOT NULL);



CREATE INDEX "idx_campus_oracle_student" ON "public"."campus_oracle_conversations" USING "btree" ("student_id");



CREATE INDEX "idx_college_lists_student_id" ON "public"."college_lists" USING "btree" ("student_id");



CREATE INDEX "idx_college_suggestions_status" ON "public"."college_suggestions" USING "btree" ("status") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_college_suggestions_student_id" ON "public"."college_suggestions" USING "btree" ("student_id");



CREATE INDEX "idx_comments_parent_id" ON "public"."comments" USING "btree" ("parent_id") WHERE ("parent_id" IS NOT NULL);



CREATE INDEX "idx_comments_student_id" ON "public"."comments" USING "btree" ("student_id");



CREATE INDEX "idx_comments_target" ON "public"."comments" USING "btree" ("target_type", "target_id") WHERE ("target_type" IS NOT NULL);



CREATE INDEX "idx_counselor_invites_email" ON "public"."counselor_invites" USING "btree" ("email");



CREATE UNIQUE INDEX "idx_counselor_invites_pending" ON "public"."counselor_invites" USING "btree" ("email") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_counselor_invites_token" ON "public"."counselor_invites" USING "btree" ("token");



CREATE INDEX "idx_courses_document_id" ON "public"."courses" USING "btree" ("document_id");



CREATE INDEX "idx_courses_student_id" ON "public"."courses" USING "btree" ("student_id");



CREATE INDEX "idx_documents_student_id" ON "public"."documents" USING "btree" ("student_id");



CREATE INDEX "idx_google_calendar_tokens_user" ON "public"."google_calendar_tokens" USING "btree" ("user_id");



CREATE INDEX "idx_narrative_annotations_student_id" ON "public"."narrative_annotations" USING "btree" ("student_id");



CREATE INDEX "idx_narrative_annotations_target" ON "public"."narrative_annotations" USING "btree" ("target_type", "target_key");



CREATE INDEX "idx_narrative_arcs_student_id" ON "public"."narrative_arcs" USING "btree" ("student_id");



CREATE INDEX "idx_notifications_booking" ON "public"."notifications_log" USING "btree" ("booking_id");



CREATE INDEX "idx_scenarios_student_id" ON "public"."scenarios" USING "btree" ("student_id");



CREATE INDEX "idx_school_knowledge_embedding" ON "public"."school_knowledge_chunks" USING "hnsw" ("embedding" "public"."vector_cosine_ops");



CREATE INDEX "idx_school_url_index_school" ON "public"."school_url_index" USING "btree" ("school_name");



CREATE INDEX "idx_session_notes_booking" ON "public"."session_notes" USING "btree" ("booking_id");



CREATE INDEX "idx_student_deadlines_due_date" ON "public"."student_deadlines" USING "btree" ("due_date") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_student_deadlines_student" ON "public"."student_deadlines" USING "btree" ("student_id");



CREATE INDEX "idx_students_counselor_id" ON "public"."students" USING "btree" ("counselor_id");



CREATE INDEX "idx_students_user_id" ON "public"."students" USING "btree" ("user_id");



CREATE INDEX "idx_universities_name" ON "public"."universities" USING "btree" ("name");



CREATE INDEX "idx_universities_state" ON "public"."universities" USING "btree" ("state");



CREATE OR REPLACE TRIGGER "bookings_updated_at" BEFORE UPDATE ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "college_lists_timeline_stale" AFTER INSERT OR DELETE OR UPDATE ON "public"."college_lists" FOR EACH ROW EXECUTE FUNCTION "public"."mark_timeline_stale"();



CREATE OR REPLACE TRIGGER "profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "set_activities_updated_at" BEFORE UPDATE ON "public"."activities" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_awards_updated_at" BEFORE UPDATE ON "public"."awards" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_campus_oracle_conversations_updated_at" BEFORE UPDATE ON "public"."campus_oracle_conversations" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_college_lists_updated_at" BEFORE UPDATE ON "public"."college_lists" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "set_courses_updated_at" BEFORE UPDATE ON "public"."courses" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_school_deadlines_updated_at" BEFORE UPDATE ON "public"."school_deadlines" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_school_knowledge_chunks_updated_at" BEFORE UPDATE ON "public"."school_knowledge_chunks" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_school_url_index_updated_at" BEFORE UPDATE ON "public"."school_url_index" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_strategic_timelines_updated_at" BEFORE UPDATE ON "public"."strategic_timelines" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_student_deadlines_updated_at" BEFORE UPDATE ON "public"."student_deadlines" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_students_updated_at" BEFORE UPDATE ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "set_universities_updated_at" BEFORE UPDATE ON "public"."universities" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "students_derive_application_cycle" BEFORE INSERT OR UPDATE ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."derive_application_cycle"();



CREATE OR REPLACE TRIGGER "trg_activities_delete_comments" AFTER DELETE ON "public"."activities" FOR EACH ROW EXECUTE FUNCTION "public"."delete_comments_for_target"('activity');



CREATE OR REPLACE TRIGGER "trg_activities_stale_profile" AFTER INSERT OR DELETE ON "public"."activities" FOR EACH ROW EXECUTE FUNCTION "public"."set_profile_stale"();



CREATE OR REPLACE TRIGGER "trg_awards_delete_comments" AFTER DELETE ON "public"."awards" FOR EACH ROW EXECUTE FUNCTION "public"."delete_comments_for_target"('award');



CREATE OR REPLACE TRIGGER "trg_awards_stale_profile" AFTER INSERT OR DELETE ON "public"."awards" FOR EACH ROW EXECUTE FUNCTION "public"."set_profile_stale"();



CREATE OR REPLACE TRIGGER "trg_courses_delete_comments" AFTER DELETE ON "public"."courses" FOR EACH ROW EXECUTE FUNCTION "public"."delete_comments_for_target"('course');



CREATE OR REPLACE TRIGGER "trg_courses_stale_profile" AFTER INSERT OR DELETE ON "public"."courses" FOR EACH ROW EXECUTE FUNCTION "public"."set_profile_stale"();



CREATE OR REPLACE TRIGGER "trg_students_stale_profile" BEFORE UPDATE ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."set_profile_stale_on_student_update"();



CREATE OR REPLACE TRIGGER "update_action_items_updated_at" BEFORE UPDATE ON "public"."action_items" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "update_comments_updated_at" BEFORE UPDATE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "update_google_calendar_tokens_updated_at" BEFORE UPDATE ON "public"."google_calendar_tokens" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "update_narrative_annotations_updated_at" BEFORE UPDATE ON "public"."narrative_annotations" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "update_narrative_arcs_updated_at" BEFORE UPDATE ON "public"."narrative_arcs" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "update_session_notes_updated_at" BEFORE UPDATE ON "public"."session_notes" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



ALTER TABLE ONLY "public"."action_items"
    ADD CONSTRAINT "action_items_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."action_items"
    ADD CONSTRAINT "action_items_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."action_items"
    ADD CONSTRAINT "action_items_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."action_items"
    ADD CONSTRAINT "action_items_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."action_items"
    ADD CONSTRAINT "action_items_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ai_usage_log"
    ADD CONSTRAINT "ai_usage_log_caller_id_fkey" FOREIGN KEY ("caller_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ai_usage_log"
    ADD CONSTRAINT "ai_usage_log_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."awards"
    ADD CONSTRAINT "awards_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_students"
    ADD CONSTRAINT "booking_students_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_students"
    ADD CONSTRAINT "booking_students_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."campus_oracle_conversations"
    ADD CONSTRAINT "campus_oracle_conversations_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."college_data_corrections"
    ADD CONSTRAINT "college_data_corrections_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."college_data_corrections"
    ADD CONSTRAINT "college_data_corrections_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."college_suggestions"
    ADD CONSTRAINT "college_suggestions_college_list_id_fkey" FOREIGN KEY ("college_list_id") REFERENCES "public"."college_lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."college_suggestions"
    ADD CONSTRAINT "college_suggestions_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."college_suggestions"
    ADD CONSTRAINT "college_suggestions_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."college_suggestions"
    ADD CONSTRAINT "college_suggestions_suggested_by_fkey" FOREIGN KEY ("suggested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."counselor_invites"
    ADD CONSTRAINT "counselor_invites_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_calendar_tokens"
    ADD CONSTRAINT "google_calendar_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."narrative_annotations"
    ADD CONSTRAINT "narrative_annotations_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."narrative_annotations"
    ADD CONSTRAINT "narrative_annotations_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."narrative_arcs"
    ADD CONSTRAINT "narrative_arcs_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications_log"
    ADD CONSTRAINT "notifications_log_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications_log"
    ADD CONSTRAINT "notifications_log_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."notifications_log"
    ADD CONSTRAINT "notifications_log_student_deadline_id_fkey" FOREIGN KEY ("student_deadline_id") REFERENCES "public"."student_deadlines"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scenarios"
    ADD CONSTRAINT "scenarios_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."scenarios"
    ADD CONSTRAINT "scenarios_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."school_deadlines"
    ADD CONSTRAINT "school_deadlines_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."session_notes"
    ADD CONSTRAINT "session_notes_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."session_notes"
    ADD CONSTRAINT "session_notes_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."strategic_timelines"
    ADD CONSTRAINT "strategic_timelines_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_deadlines"
    ADD CONSTRAINT "student_deadlines_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."student_deadlines"
    ADD CONSTRAINT "student_deadlines_school_deadline_id_fkey" FOREIGN KEY ("school_deadline_id") REFERENCES "public"."school_deadlines"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."student_deadlines"
    ADD CONSTRAINT "student_deadlines_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



CREATE POLICY "Admins can delete students" ON "public"."students" FOR DELETE USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage action items" ON "public"."action_items" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage all bookings" ON "public"."bookings" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage availability slots" ON "public"."availability_slots" USING (("public"."current_user_role"() = 'admin'::"public"."user_role")) WITH CHECK (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage booking students" ON "public"."booking_students" USING (("public"."current_user_role"() = 'admin'::"public"."user_role")) WITH CHECK (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage invites" ON "public"."counselor_invites" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage session notes" ON "public"."session_notes" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can read all bookings" ON "public"."bookings" FOR SELECT USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can read notifications" ON "public"."notifications_log" FOR SELECT USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can update any profile" ON "public"."profiles" FOR UPDATE USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can update corrections" ON "public"."college_data_corrections" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"public"."user_role", 'counselor'::"public"."user_role"]))))));



CREATE POLICY "Admins see all corrections" ON "public"."college_data_corrections" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"public"."user_role", 'counselor'::"public"."user_role"]))))) OR ("submitted_by" = "auth"."uid"())));



CREATE POLICY "Anyone can read profiles" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Anyone can submit corrections" ON "public"."college_data_corrections" FOR INSERT TO "authenticated" WITH CHECK (("submitted_by" = "auth"."uid"()));



CREATE POLICY "Anyone can view universities" ON "public"."universities" FOR SELECT USING (true);



CREATE POLICY "Authenticated users can read URL index" ON "public"."school_url_index" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authors can delete own annotations" ON "public"."narrative_annotations" FOR DELETE TO "authenticated" USING (("author_id" = "auth"."uid"()));



CREATE POLICY "Authors can update own annotations" ON "public"."narrative_annotations" FOR UPDATE TO "authenticated" USING (("author_id" = "auth"."uid"())) WITH CHECK (("author_id" = "auth"."uid"()));



CREATE POLICY "Clients can cancel own bookings" ON "public"."bookings" FOR UPDATE USING (("client_id" = "auth"."uid"())) WITH CHECK ((("client_id" = "auth"."uid"()) AND ("status" = 'cancelled_by_client'::"public"."booking_status")));



CREATE POLICY "Clients can create bookings" ON "public"."bookings" FOR INSERT WITH CHECK ((("client_id" = "auth"."uid"()) AND ("public"."current_user_role"() = 'student_parent'::"public"."user_role")));



CREATE POLICY "Clients can read action items" ON "public"."action_items" FOR SELECT USING (("client_id" = "auth"."uid"()));



CREATE POLICY "Clients can read own bookings" ON "public"."bookings" FOR SELECT USING (("client_id" = "auth"."uid"()));



CREATE POLICY "Clients can read session notes" ON "public"."session_notes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "session_notes"."booking_id") AND ("b"."client_id" = "auth"."uid"())))));



CREATE POLICY "Clients can update action item status" ON "public"."action_items" FOR UPDATE USING (("client_id" = "auth"."uid"())) WITH CHECK (("client_id" = "auth"."uid"()));



CREATE POLICY "Counselors and admins can delete URL index" ON "public"."school_url_index" FOR DELETE TO "authenticated" USING (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors and admins can delete conversations" ON "public"."campus_oracle_conversations" FOR DELETE USING (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors and admins can insert annotations" ON "public"."narrative_annotations" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors and admins can insert narrative arcs" ON "public"."narrative_arcs" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors and admins can insert/update timelines" ON "public"."strategic_timelines" USING (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))) WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors and admins can manage URL index" ON "public"."school_url_index" FOR INSERT TO "authenticated" WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors and admins can update URL index" ON "public"."school_url_index" FOR UPDATE TO "authenticated" USING (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors and admins can update conversations" ON "public"."campus_oracle_conversations" FOR UPDATE USING (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors and admins can update narrative arcs" ON "public"."narrative_arcs" FOR UPDATE TO "authenticated" USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])))) WITH CHECK (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors and admins can view annotations" ON "public"."narrative_annotations" FOR SELECT TO "authenticated" USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors and admins can view narrative arcs" ON "public"."narrative_arcs" FOR SELECT TO "authenticated" USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors can add to college list" ON "public"."college_lists" FOR INSERT WITH CHECK (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors can delete action items" ON "public"."action_items" FOR DELETE USING (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can delete session notes" ON "public"."session_notes" FOR DELETE USING ((("author_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "session_notes"."booking_id") AND ("b"."counselor_id" = "auth"."uid"()))))));



CREATE POLICY "Counselors can insert action items" ON "public"."action_items" FOR INSERT WITH CHECK ((("counselor_id" = "auth"."uid"()) AND ("created_by" = "auth"."uid"())));



CREATE POLICY "Counselors can insert session notes" ON "public"."session_notes" FOR INSERT WITH CHECK ((("author_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "session_notes"."booking_id") AND ("b"."counselor_id" = "auth"."uid"()))))));



CREATE POLICY "Counselors can insert students" ON "public"."students" FOR INSERT WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors can manage booking students" ON "public"."booking_students" USING ((("public"."current_user_role"() = 'counselor'::"public"."user_role") AND "public"."can_access_student"("student_id"))) WITH CHECK ((("public"."current_user_role"() = 'counselor'::"public"."user_role") AND "public"."can_access_student"("student_id")));



CREATE POLICY "Counselors can manage universities" ON "public"."universities" USING (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors can read action items" ON "public"."action_items" FOR SELECT USING (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can read assigned bookings" ON "public"."bookings" FOR SELECT USING (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can read session notes" ON "public"."session_notes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "session_notes"."booking_id") AND ("b"."counselor_id" = "auth"."uid"())))));



CREATE POLICY "Counselors can remove from college list" ON "public"."college_lists" FOR DELETE USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors can resolve suggestions" ON "public"."college_suggestions" FOR UPDATE USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors can update action items" ON "public"."action_items" FOR UPDATE USING (("counselor_id" = "auth"."uid"())) WITH CHECK (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can update assigned bookings" ON "public"."bookings" FOR UPDATE USING (("counselor_id" = "auth"."uid"())) WITH CHECK (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can update assigned students" ON "public"."students" FOR UPDATE USING ("public"."can_access_student"("id")) WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors can update college list" ON "public"."college_lists" FOR UPDATE USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors can update session notes" ON "public"."session_notes" FOR UPDATE USING ((("author_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "session_notes"."booking_id") AND ("b"."counselor_id" = "auth"."uid"())))))) WITH CHECK ((("author_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "session_notes"."booking_id") AND ("b"."counselor_id" = "auth"."uid"()))))));



CREATE POLICY "Counselors can view suggestions" ON "public"."college_suggestions" FOR SELECT USING (("public"."can_access_student"("student_id") AND ("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))));



CREATE POLICY "Counselors manage own availability slots" ON "public"."availability_slots" USING ((("owner_type" = 'counselor'::"text") AND ("owner_id" = "auth"."uid"()))) WITH CHECK ((("owner_type" = 'counselor'::"text") AND ("owner_id" = "auth"."uid"())));



CREATE POLICY "Counselors read student availability slots" ON "public"."availability_slots" FOR SELECT USING ((("owner_type" = 'student'::"text") AND ("owner_id" IN ( SELECT "students"."id"
   FROM "public"."students"
  WHERE ("students"."counselor_id" = "auth"."uid"())))));



CREATE POLICY "Only admins can delete timelines" ON "public"."strategic_timelines" FOR DELETE USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Parents can add schools to own student lists" ON "public"."college_lists" FOR INSERT WITH CHECK ((("public"."current_user_role"() = 'student_parent'::"public"."user_role") AND "public"."can_access_student"("student_id")));



CREATE POLICY "Parents can insert students" ON "public"."students" FOR INSERT WITH CHECK ((("public"."current_user_role"() = 'student_parent'::"public"."user_role") AND ("user_id" = "auth"."uid"()) AND ("status" = 'pending_approval'::"public"."student_status")));



CREATE POLICY "Parents can read booking students" ON "public"."booking_students" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Parents can update unassigned students" ON "public"."students" FOR UPDATE USING ((("public"."current_user_role"() = 'student_parent'::"public"."user_role") AND ("user_id" = "auth"."uid"()) AND ("counselor_id" IS NULL) AND ("status" = 'pending_approval'::"public"."student_status"))) WITH CHECK ((("public"."current_user_role"() = 'student_parent'::"public"."user_role") AND ("user_id" = "auth"."uid"()) AND ("status" = 'pending_approval'::"public"."student_status")));



CREATE POLICY "Parents manage child availability slots" ON "public"."availability_slots" USING ((("owner_type" = 'student'::"text") AND ("owner_id" IN ( SELECT "students"."id"
   FROM "public"."students"
  WHERE ("students"."user_id" = "auth"."uid"()))))) WITH CHECK ((("owner_type" = 'student'::"text") AND ("owner_id" IN ( SELECT "students"."id"
   FROM "public"."students"
  WHERE ("students"."user_id" = "auth"."uid"())))));



CREATE POLICY "Parents read counselor availability slots" ON "public"."availability_slots" FOR SELECT USING ((("owner_type" = 'counselor'::"text") AND ("owner_id" IN ( SELECT DISTINCT "students"."counselor_id"
   FROM "public"."students"
  WHERE ("students"."user_id" = "auth"."uid"())))));



CREATE POLICY "Public can verify pending invite" ON "public"."counselor_invites" FOR SELECT USING (("status" = 'pending'::"text"));



CREATE POLICY "Users can add comments for accessible students" ON "public"."comments" FOR INSERT WITH CHECK (("public"."can_access_student"("student_id") AND ("author_id" = "auth"."uid"())));



CREATE POLICY "Users can create conversations for accessible students" ON "public"."campus_oracle_conversations" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can create suggestions" ON "public"."college_suggestions" FOR INSERT WITH CHECK (("public"."can_access_student"("student_id") AND ("suggested_by" = "auth"."uid"())));



CREATE POLICY "Users can delete activities for accessible students" ON "public"."activities" FOR DELETE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can delete awards for accessible students" ON "public"."awards" FOR DELETE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can delete courses for accessible students" ON "public"."courses" FOR DELETE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can delete own calendar tokens" ON "public"."google_calendar_tokens" FOR DELETE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can delete own comments" ON "public"."comments" FOR DELETE USING (("author_id" = "auth"."uid"()));



CREATE POLICY "Users can delete own documents" ON "public"."documents" FOR DELETE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can edit own comments" ON "public"."comments" FOR UPDATE USING (("author_id" = "auth"."uid"())) WITH CHECK (("author_id" = "auth"."uid"()));



CREATE POLICY "Users can insert activities for accessible students" ON "public"."activities" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can insert awards for accessible students" ON "public"."awards" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can insert courses for accessible students" ON "public"."courses" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can insert own calendar tokens" ON "public"."google_calendar_tokens" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own calendar tokens" ON "public"."google_calendar_tokens" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own student conversations" ON "public"."campus_oracle_conversations" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can read own student timelines" ON "public"."strategic_timelines" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update activities for accessible students" ON "public"."activities" FOR UPDATE USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update awards for accessible students" ON "public"."awards" FOR UPDATE USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update courses for accessible students" ON "public"."courses" FOR UPDATE USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update own calendar tokens" ON "public"."google_calendar_tokens" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own documents" ON "public"."documents" FOR UPDATE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update own profile (not role)" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK ((("id" = "auth"."uid"()) AND ("role" = ( SELECT "profiles_1"."role"
   FROM "public"."profiles" "profiles_1"
  WHERE ("profiles_1"."id" = "auth"."uid"())))));



CREATE POLICY "Users can upload documents" ON "public"."documents" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view awards for accessible students" ON "public"."awards" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view comments for accessible students" ON "public"."comments" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own activities" ON "public"."activities" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own college list" ON "public"."college_lists" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own courses" ON "public"."courses" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own documents" ON "public"."documents" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own student record" ON "public"."students" FOR SELECT USING ("public"."can_access_student"("id"));



CREATE POLICY "Users can view relevant suggestions" ON "public"."college_suggestions" FOR SELECT USING ((("suggested_by" = "auth"."uid"()) OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."action_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admins_delete_scenarios" ON "public"."scenarios" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



ALTER TABLE "public"."ai_usage_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ai_usage_log_admin_select" ON "public"."ai_usage_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



ALTER TABLE "public"."availability_slots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."awards" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."booking_students" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."campus_oracle_conversations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."college_data_corrections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."college_lists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."college_suggestions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."counselor_invites" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "counselors_read_scenarios" ON "public"."scenarios" FOR SELECT USING ((("student_id" IN ( SELECT "students"."id"
   FROM "public"."students"
  WHERE ("students"."counselor_id" = "auth"."uid"()))) OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role"))))));



CREATE POLICY "counselors_write_scenarios" ON "public"."scenarios" FOR INSERT WITH CHECK ((("student_id" IN ( SELECT "students"."id"
   FROM "public"."students"
  WHERE ("students"."counselor_id" = "auth"."uid"()))) OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role"))))));



ALTER TABLE "public"."courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."google_calendar_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."narrative_annotations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."narrative_arcs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scenarios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."school_deadlines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "school_deadlines_delete" ON "public"."school_deadlines" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



CREATE POLICY "school_deadlines_insert" ON "public"."school_deadlines" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))))));



CREATE POLICY "school_deadlines_select" ON "public"."school_deadlines" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "school_deadlines_update" ON "public"."school_deadlines" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"]))))));



ALTER TABLE "public"."school_knowledge_chunks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "school_knowledge_chunks_delete" ON "public"."school_knowledge_chunks" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



CREATE POLICY "school_knowledge_chunks_insert" ON "public"."school_knowledge_chunks" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



CREATE POLICY "school_knowledge_chunks_select" ON "public"."school_knowledge_chunks" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "school_knowledge_chunks_update" ON "public"."school_knowledge_chunks" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



ALTER TABLE "public"."school_url_index" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."session_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."strategic_timelines" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_deadlines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_deadlines_all" ON "public"."student_deadlines" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."students" "s"
  WHERE (("s"."id" = "student_deadlines"."student_id") AND (("s"."counselor_id" = "auth"."uid"()) OR ("s"."user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
           FROM "public"."profiles"
          WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))))))));



ALTER TABLE "public"."students" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."universities" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."append_oracle_messages"("conv_id" "uuid", "new_messages" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."append_oracle_messages"("conv_id" "uuid", "new_messages" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."append_oracle_messages"("conv_id" "uuid", "new_messages" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_comments_for_target"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_comments_for_target"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_comments_for_target"() TO "service_role";



GRANT ALL ON FUNCTION "public"."derive_application_cycle"() TO "anon";
GRANT ALL ON FUNCTION "public"."derive_application_cycle"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."derive_application_cycle"() TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_timeline_stale"() TO "anon";
GRANT ALL ON FUNCTION "public"."mark_timeline_stale"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_timeline_stale"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."send_auth_email"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."send_auth_email"("event" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."send_auth_email"("event" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_auth_email"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."send_auth_email"("event" "jsonb") TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."set_profile_stale"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_profile_stale"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_profile_stale"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_profile_stale_on_student_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_profile_stale_on_student_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_profile_stale_on_student_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";















GRANT ALL ON TABLE "public"."action_items" TO "anon";
GRANT ALL ON TABLE "public"."action_items" TO "authenticated";
GRANT ALL ON TABLE "public"."action_items" TO "service_role";



GRANT ALL ON TABLE "public"."activities" TO "anon";
GRANT ALL ON TABLE "public"."activities" TO "authenticated";
GRANT ALL ON TABLE "public"."activities" TO "service_role";



GRANT ALL ON TABLE "public"."ai_usage_log" TO "anon";
GRANT ALL ON TABLE "public"."ai_usage_log" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_usage_log" TO "service_role";



GRANT ALL ON TABLE "public"."availability_slots" TO "anon";
GRANT ALL ON TABLE "public"."availability_slots" TO "authenticated";
GRANT ALL ON TABLE "public"."availability_slots" TO "service_role";



GRANT ALL ON TABLE "public"."awards" TO "anon";
GRANT ALL ON TABLE "public"."awards" TO "authenticated";
GRANT ALL ON TABLE "public"."awards" TO "service_role";



GRANT ALL ON TABLE "public"."booking_students" TO "anon";
GRANT ALL ON TABLE "public"."booking_students" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_students" TO "service_role";



GRANT ALL ON TABLE "public"."bookings" TO "anon";
GRANT ALL ON TABLE "public"."bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."bookings" TO "service_role";



GRANT ALL ON TABLE "public"."campus_oracle_conversations" TO "anon";
GRANT ALL ON TABLE "public"."campus_oracle_conversations" TO "authenticated";
GRANT ALL ON TABLE "public"."campus_oracle_conversations" TO "service_role";



GRANT ALL ON TABLE "public"."college_data_corrections" TO "anon";
GRANT ALL ON TABLE "public"."college_data_corrections" TO "authenticated";
GRANT ALL ON TABLE "public"."college_data_corrections" TO "service_role";



GRANT ALL ON TABLE "public"."college_lists" TO "anon";
GRANT ALL ON TABLE "public"."college_lists" TO "authenticated";
GRANT ALL ON TABLE "public"."college_lists" TO "service_role";



GRANT ALL ON TABLE "public"."college_suggestions" TO "anon";
GRANT ALL ON TABLE "public"."college_suggestions" TO "authenticated";
GRANT ALL ON TABLE "public"."college_suggestions" TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON TABLE "public"."counselor_invites" TO "anon";
GRANT ALL ON TABLE "public"."counselor_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."counselor_invites" TO "service_role";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";



GRANT ALL ON TABLE "public"."documents" TO "anon";
GRANT ALL ON TABLE "public"."documents" TO "authenticated";
GRANT ALL ON TABLE "public"."documents" TO "service_role";



GRANT ALL ON TABLE "public"."google_calendar_tokens" TO "anon";
GRANT ALL ON TABLE "public"."google_calendar_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."google_calendar_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."narrative_annotations" TO "anon";
GRANT ALL ON TABLE "public"."narrative_annotations" TO "authenticated";
GRANT ALL ON TABLE "public"."narrative_annotations" TO "service_role";



GRANT ALL ON TABLE "public"."narrative_arcs" TO "anon";
GRANT ALL ON TABLE "public"."narrative_arcs" TO "authenticated";
GRANT ALL ON TABLE "public"."narrative_arcs" TO "service_role";



GRANT ALL ON TABLE "public"."notifications_log" TO "anon";
GRANT ALL ON TABLE "public"."notifications_log" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications_log" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."scenarios" TO "anon";
GRANT ALL ON TABLE "public"."scenarios" TO "authenticated";
GRANT ALL ON TABLE "public"."scenarios" TO "service_role";



GRANT ALL ON TABLE "public"."school_deadlines" TO "anon";
GRANT ALL ON TABLE "public"."school_deadlines" TO "authenticated";
GRANT ALL ON TABLE "public"."school_deadlines" TO "service_role";



GRANT ALL ON TABLE "public"."school_knowledge_chunks" TO "anon";
GRANT ALL ON TABLE "public"."school_knowledge_chunks" TO "authenticated";
GRANT ALL ON TABLE "public"."school_knowledge_chunks" TO "service_role";



GRANT ALL ON TABLE "public"."school_url_index" TO "anon";
GRANT ALL ON TABLE "public"."school_url_index" TO "authenticated";
GRANT ALL ON TABLE "public"."school_url_index" TO "service_role";



GRANT ALL ON TABLE "public"."session_notes" TO "anon";
GRANT ALL ON TABLE "public"."session_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."session_notes" TO "service_role";



GRANT ALL ON TABLE "public"."strategic_timelines" TO "anon";
GRANT ALL ON TABLE "public"."strategic_timelines" TO "authenticated";
GRANT ALL ON TABLE "public"."strategic_timelines" TO "service_role";



GRANT ALL ON TABLE "public"."student_deadlines" TO "anon";
GRANT ALL ON TABLE "public"."student_deadlines" TO "authenticated";
GRANT ALL ON TABLE "public"."student_deadlines" TO "service_role";



GRANT ALL ON TABLE "public"."students" TO "anon";
GRANT ALL ON TABLE "public"."students" TO "authenticated";
GRANT ALL ON TABLE "public"."students" TO "service_role";



GRANT ALL ON TABLE "public"."universities" TO "anon";
GRANT ALL ON TABLE "public"."universities" TO "authenticated";
GRANT ALL ON TABLE "public"."universities" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































