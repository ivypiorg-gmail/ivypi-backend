-- Shared Insights — counselor-curated insights shared with families
-- Spec: docs/superpowers/specs/2026-03-20-college-flow-restructuring-design.md

CREATE TABLE IF NOT EXISTS "public"."shared_insights" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "school_name" "text",
    "body" "text" NOT NULL,
    "source_type" "text" NOT NULL,
    "source_id" "uuid",
    "source_field" "text",
    "shared_by" "uuid" NOT NULL,
    "archived_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "shared_insights_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "shared_insights_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE,
    CONSTRAINT "shared_insights_shared_by_fkey" FOREIGN KEY ("shared_by") REFERENCES "public"."profiles"("id"),
    CONSTRAINT "shared_insights_source_type_check" CHECK (("source_type" = ANY (ARRAY['affinity'::"text", 'simulation'::"text", 'deadline'::"text", 'narrative'::"text", 'manual'::"text"])))
);

CREATE INDEX IF NOT EXISTS "idx_shared_insights_student_school"
    ON "public"."shared_insights" ("student_id", "school_name");

CREATE TRIGGER "set_shared_insights_updated_at"
    BEFORE UPDATE ON "public"."shared_insights"
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE "public"."shared_insights" ENABLE ROW LEVEL SECURITY;

-- Parents: can read all insights for their students (both active and archived)
CREATE POLICY "parent_read_insights" ON "public"."shared_insights"
    FOR SELECT USING (
        can_access_student(student_id)
    );

-- Counselors: full CRUD for their assigned students
CREATE POLICY "counselor_manage_insights" ON "public"."shared_insights"
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM "public"."students"
            WHERE "students"."id" = "shared_insights"."student_id"
            AND "students"."counselor_id" = "auth"."uid"()
        )
    );

-- Admins: full access
CREATE POLICY "admin_all_insights" ON "public"."shared_insights"
    FOR ALL USING (current_user_role() = 'admin');
