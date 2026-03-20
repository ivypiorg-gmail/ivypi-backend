-- Committee Simulator tables
-- Spec: docs/superpowers/specs/2026-03-20-committee-simulator-design.md

-- 1. Base role templates (generic archetypes)
CREATE TABLE IF NOT EXISTS "public"."committee_prompt_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role" "text" NOT NULL,
    "base_system_prompt" "text" NOT NULL,
    "context_instructions" "text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "committee_prompt_templates_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "committee_prompt_templates_role_key" UNIQUE ("role")
);

-- 2. Per-school curated committee personas
CREATE TABLE IF NOT EXISTS "public"."committee_member_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "school_name" "text" NOT NULL,
    "role" "text" NOT NULL,
    "persona_prompt" "text" NOT NULL,
    "institutional_context" "jsonb" DEFAULT '{}'::jsonb NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "committee_member_profiles_pkey" PRIMARY KEY ("id")
);

CREATE INDEX IF NOT EXISTS "idx_committee_member_profiles_school_role"
    ON "public"."committee_member_profiles" ("school_name", "role");

-- 3. Simulation results
CREATE TABLE IF NOT EXISTS "public"."committee_simulations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "school_name" "text" NOT NULL,
    "target_major" "text" NOT NULL,
    "mode" "text" NOT NULL,
    "panel_composition" "jsonb" DEFAULT '[]'::jsonb NOT NULL,
    "assessments" "jsonb",
    "winner_role" "text",
    "synthesis" "jsonb",
    "essay_analysis" "jsonb",
    "outcome" "text",
    "status" "text" DEFAULT 'generating'::"text" NOT NULL,
    "error_phase" "text",
    "run_number" integer DEFAULT 1 NOT NULL,
    "generated_at" timestamp with time zone,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "committee_simulations_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "committee_simulations_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE,
    CONSTRAINT "committee_simulations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id"),
    CONSTRAINT "committee_simulations_mode_check" CHECK (("mode" = ANY (ARRAY['pre_essay'::"text", 'post_essay'::"text"]))),
    -- 'partial' is unique to committee_simulations; see error_phase for which phase failed
    CONSTRAINT "committee_simulations_status_check" CHECK (("status" = ANY (ARRAY['generating'::"text", 'idle'::"text", 'failed'::"text", 'partial'::"text"]))),
    CONSTRAINT "committee_simulations_outcome_check" CHECK (("outcome" IS NULL OR "outcome" = ANY (ARRAY['admit'::"text", 'waitlist'::"text", 'deny'::"text"]))),
    CONSTRAINT "committee_simulations_run_unique" UNIQUE ("student_id", "school_name", "target_major", "run_number")
);

CREATE INDEX IF NOT EXISTS "idx_committee_simulations_student_school_major"
    ON "public"."committee_simulations" ("student_id", "school_name", "target_major");

-- updated_at triggers (reuse existing trigger function)
CREATE TRIGGER "set_committee_prompt_templates_updated_at"
    BEFORE UPDATE ON "public"."committee_prompt_templates"
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER "set_committee_member_profiles_updated_at"
    BEFORE UPDATE ON "public"."committee_member_profiles"
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER "set_committee_simulations_updated_at"
    BEFORE UPDATE ON "public"."committee_simulations"
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- RLS
ALTER TABLE "public"."committee_prompt_templates" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."committee_member_profiles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."committee_simulations" ENABLE ROW LEVEL SECURITY;

-- Templates and profiles: read-only for counselors and admins
CREATE POLICY "counselor_admin_read_templates" ON "public"."committee_prompt_templates"
    FOR SELECT USING (current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "counselor_admin_read_profiles" ON "public"."committee_member_profiles"
    FOR SELECT USING (current_user_role() IN ('counselor', 'admin'));

-- Simulations: counselors see their students' sims, admins see all
CREATE POLICY "counselor_read_simulations" ON "public"."committee_simulations"
    FOR SELECT USING (
        can_access_student(student_id) OR current_user_role() = 'admin'
    );

-- Simulations: insert allowed for counselors/admins (edge function uses service role, but this covers direct access)
CREATE POLICY "counselor_admin_insert_simulations" ON "public"."committee_simulations"
    FOR INSERT WITH CHECK (current_user_role() IN ('counselor', 'admin'));

-- Simulations: update allowed for counselors (own students) and admins
CREATE POLICY "counselor_admin_update_simulations" ON "public"."committee_simulations"
    FOR UPDATE USING (
        can_access_student(student_id) OR current_user_role() = 'admin'
    );
