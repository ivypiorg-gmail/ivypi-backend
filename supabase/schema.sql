


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
    'activity_list'
);


ALTER TYPE "public"."document_type" OWNER TO "postgres";


CREATE TYPE "public"."notification_type" AS ENUM (
    'confirmation',
    'reminder_24h',
    'cancellation',
    'reminder_30m'
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
    'deferred'
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
    'admin'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."get_available_slots"("p_counselor_id" "uuid", "p_start_date" "date", "p_end_date" "date") RETURNS TABLE("slot_date" "date", "start_time" time without time zone, "end_time" time without time zone)
    LANGUAGE "plpgsql" STABLE
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


ALTER FUNCTION "public"."get_available_slots"("p_counselor_id" "uuid", "p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


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
    "depth_narrative" "text"
);


ALTER TABLE "public"."activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."availability_overrides" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "counselor_id" "uuid" NOT NULL,
    "override_date" "date" NOT NULL,
    "start_time" time without time zone,
    "end_time" time without time zone,
    "is_available" boolean DEFAULT false NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."availability_overrides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."availability_windows" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "counselor_id" "uuid" NOT NULL,
    "day_of_week" smallint NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "slot_duration" smallint DEFAULT 60 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "availability_windows_day_of_week_check" CHECK ((("day_of_week" >= 0) AND ("day_of_week" <= 6))),
    CONSTRAINT "valid_time_range" CHECK (("end_time" > "start_time"))
);


ALTER TABLE "public"."availability_windows" OWNER TO "postgres";


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
    CONSTRAINT "valid_booking_range" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."bookings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."college_lists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "school_name" "text" NOT NULL,
    "affinity_report" "jsonb" DEFAULT '{}'::"jsonb",
    "counselor_notes" "text",
    "app_status" "public"."app_status" DEFAULT 'considering'::"public"."app_status" NOT NULL,
    "decision_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."college_lists" OWNER TO "postgres";


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
    "semester" "text"
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


CREATE TABLE IF NOT EXISTS "public"."notifications_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid",
    "type" "public"."notification_type" NOT NULL,
    "recipient" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'sent'::"text" NOT NULL
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
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."students" OWNER TO "postgres";


ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."availability_overrides"
    ADD CONSTRAINT "availability_overrides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."availability_windows"
    ADD CONSTRAINT "availability_windows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_student_id_school_name_key" UNIQUE ("student_id", "school_name");



ALTER TABLE ONLY "public"."counselor_invites"
    ADD CONSTRAINT "counselor_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."counselor_invites"
    ADD CONSTRAINT "counselor_invites_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications_log"
    ADD CONSTRAINT "notifications_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scenarios"
    ADD CONSTRAINT "scenarios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_user_id_key" UNIQUE ("user_id");



CREATE INDEX "idx_activities_document_id" ON "public"."activities" USING "btree" ("document_id");



CREATE INDEX "idx_activities_student_id" ON "public"."activities" USING "btree" ("student_id");



CREATE INDEX "idx_availability_overrides_counselor_date" ON "public"."availability_overrides" USING "btree" ("counselor_id", "override_date");



CREATE INDEX "idx_availability_windows_counselor" ON "public"."availability_windows" USING "btree" ("counselor_id");



CREATE INDEX "idx_bookings_client" ON "public"."bookings" USING "btree" ("client_id");



CREATE INDEX "idx_bookings_counselor_starts" ON "public"."bookings" USING "btree" ("counselor_id", "starts_at");



CREATE INDEX "idx_bookings_recurrence_group" ON "public"."bookings" USING "btree" ("recurrence_group_id") WHERE ("recurrence_group_id" IS NOT NULL);



CREATE INDEX "idx_college_lists_student_id" ON "public"."college_lists" USING "btree" ("student_id");



CREATE INDEX "idx_counselor_invites_email" ON "public"."counselor_invites" USING "btree" ("email");



CREATE UNIQUE INDEX "idx_counselor_invites_pending" ON "public"."counselor_invites" USING "btree" ("email") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_counselor_invites_token" ON "public"."counselor_invites" USING "btree" ("token");



CREATE INDEX "idx_courses_document_id" ON "public"."courses" USING "btree" ("document_id");



CREATE INDEX "idx_courses_student_id" ON "public"."courses" USING "btree" ("student_id");



CREATE INDEX "idx_documents_student_id" ON "public"."documents" USING "btree" ("student_id");



CREATE INDEX "idx_notifications_booking" ON "public"."notifications_log" USING "btree" ("booking_id");



CREATE INDEX "idx_scenarios_student_id" ON "public"."scenarios" USING "btree" ("student_id");



CREATE INDEX "idx_students_counselor_id" ON "public"."students" USING "btree" ("counselor_id");



CREATE INDEX "idx_students_user_id" ON "public"."students" USING "btree" ("user_id");



CREATE OR REPLACE TRIGGER "bookings_updated_at" BEFORE UPDATE ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "set_college_lists_updated_at" BEFORE UPDATE ON "public"."college_lists" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "set_students_updated_at" BEFORE UPDATE ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."availability_overrides"
    ADD CONSTRAINT "availability_overrides_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."availability_windows"
    ADD CONSTRAINT "availability_windows_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."college_lists"
    ADD CONSTRAINT "college_lists_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."counselor_invites"
    ADD CONSTRAINT "counselor_invites_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications_log"
    ADD CONSTRAINT "notifications_log_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scenarios"
    ADD CONSTRAINT "scenarios_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."scenarios"
    ADD CONSTRAINT "scenarios_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_counselor_id_fkey" FOREIGN KEY ("counselor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



CREATE POLICY "Admins can delete students" ON "public"."students" FOR DELETE USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage all availability" ON "public"."availability_windows" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage all bookings" ON "public"."bookings" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage all overrides" ON "public"."availability_overrides" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can manage invites" ON "public"."counselor_invites" USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can read all bookings" ON "public"."bookings" FOR SELECT USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can read notifications" ON "public"."notifications_log" FOR SELECT USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Admins can update any profile" ON "public"."profiles" FOR UPDATE USING (("public"."current_user_role"() = 'admin'::"public"."user_role"));



CREATE POLICY "Anyone can read availability" ON "public"."availability_windows" FOR SELECT USING (true);



CREATE POLICY "Anyone can read overrides" ON "public"."availability_overrides" FOR SELECT USING (true);



CREATE POLICY "Anyone can read profiles" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Clients can cancel own bookings" ON "public"."bookings" FOR UPDATE USING (("client_id" = "auth"."uid"())) WITH CHECK ((("client_id" = "auth"."uid"()) AND ("status" = 'cancelled_by_client'::"public"."booking_status")));



CREATE POLICY "Clients can create bookings" ON "public"."bookings" FOR INSERT WITH CHECK ((("client_id" = "auth"."uid"()) AND ("public"."current_user_role"() = 'student_parent'::"public"."user_role")));



CREATE POLICY "Clients can read own bookings" ON "public"."bookings" FOR SELECT USING (("client_id" = "auth"."uid"()));



CREATE POLICY "Counselors can insert students" ON "public"."students" FOR INSERT WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors can manage activities" ON "public"."activities" USING ("public"."can_access_student"("student_id")) WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors can manage courses" ON "public"."courses" USING ("public"."can_access_student"("student_id")) WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Counselors can manage own availability" ON "public"."availability_windows" USING ((("counselor_id" = "auth"."uid"()) AND ("public"."current_user_role"() = 'counselor'::"public"."user_role"))) WITH CHECK (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can manage own overrides" ON "public"."availability_overrides" USING ((("counselor_id" = "auth"."uid"()) AND ("public"."current_user_role"() = 'counselor'::"public"."user_role"))) WITH CHECK (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can read assigned bookings" ON "public"."bookings" FOR SELECT USING (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can update assigned bookings" ON "public"."bookings" FOR UPDATE USING (("counselor_id" = "auth"."uid"())) WITH CHECK (("counselor_id" = "auth"."uid"()));



CREATE POLICY "Counselors can update assigned students" ON "public"."students" FOR UPDATE USING ("public"."can_access_student"("id")) WITH CHECK (("public"."current_user_role"() = ANY (ARRAY['counselor'::"public"."user_role", 'admin'::"public"."user_role"])));



CREATE POLICY "Public can verify pending invite" ON "public"."counselor_invites" FOR SELECT USING (("status" = 'pending'::"text"));



CREATE POLICY "Users can add to college list" ON "public"."college_lists" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can delete own documents" ON "public"."documents" FOR DELETE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can remove from college list" ON "public"."college_lists" FOR DELETE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update college list" ON "public"."college_lists" FOR UPDATE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update own documents" ON "public"."documents" FOR UPDATE USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can update own profile (not role)" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK ((("id" = "auth"."uid"()) AND ("role" = ( SELECT "profiles_1"."role"
   FROM "public"."profiles" "profiles_1"
  WHERE ("profiles_1"."id" = "auth"."uid"())))));



CREATE POLICY "Users can upload documents" ON "public"."documents" FOR INSERT WITH CHECK ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own activities" ON "public"."activities" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own college list" ON "public"."college_lists" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own courses" ON "public"."courses" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own documents" ON "public"."documents" FOR SELECT USING ("public"."can_access_student"("student_id"));



CREATE POLICY "Users can view own student record" ON "public"."students" FOR SELECT USING ("public"."can_access_student"("id"));



ALTER TABLE "public"."activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admins_delete_scenarios" ON "public"."scenarios" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"public"."user_role")))));



ALTER TABLE "public"."availability_overrides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."availability_windows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."college_lists" ENABLE ROW LEVEL SECURITY;


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


ALTER TABLE "public"."notifications_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scenarios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."students" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

















































































































































































GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_available_slots"("p_counselor_id" "uuid", "p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_available_slots"("p_counselor_id" "uuid", "p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_available_slots"("p_counselor_id" "uuid", "p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";
























GRANT ALL ON TABLE "public"."activities" TO "anon";
GRANT ALL ON TABLE "public"."activities" TO "authenticated";
GRANT ALL ON TABLE "public"."activities" TO "service_role";



GRANT ALL ON TABLE "public"."availability_overrides" TO "anon";
GRANT ALL ON TABLE "public"."availability_overrides" TO "authenticated";
GRANT ALL ON TABLE "public"."availability_overrides" TO "service_role";



GRANT ALL ON TABLE "public"."availability_windows" TO "anon";
GRANT ALL ON TABLE "public"."availability_windows" TO "authenticated";
GRANT ALL ON TABLE "public"."availability_windows" TO "service_role";



GRANT ALL ON TABLE "public"."bookings" TO "anon";
GRANT ALL ON TABLE "public"."bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."bookings" TO "service_role";



GRANT ALL ON TABLE "public"."college_lists" TO "anon";
GRANT ALL ON TABLE "public"."college_lists" TO "authenticated";
GRANT ALL ON TABLE "public"."college_lists" TO "service_role";



GRANT ALL ON TABLE "public"."counselor_invites" TO "anon";
GRANT ALL ON TABLE "public"."counselor_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."counselor_invites" TO "service_role";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";



GRANT ALL ON TABLE "public"."documents" TO "anon";
GRANT ALL ON TABLE "public"."documents" TO "authenticated";
GRANT ALL ON TABLE "public"."documents" TO "service_role";



GRANT ALL ON TABLE "public"."notifications_log" TO "anon";
GRANT ALL ON TABLE "public"."notifications_log" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications_log" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."scenarios" TO "anon";
GRANT ALL ON TABLE "public"."scenarios" TO "authenticated";
GRANT ALL ON TABLE "public"."scenarios" TO "service_role";



GRANT ALL ON TABLE "public"."students" TO "anon";
GRANT ALL ON TABLE "public"."students" TO "authenticated";
GRANT ALL ON TABLE "public"."students" TO "service_role";









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































