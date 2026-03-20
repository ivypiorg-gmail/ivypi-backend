-- Shared Resources — bidirectional link/file sharing between parents and counselors

CREATE TABLE IF NOT EXISTS "public"."shared_resources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "added_by" "uuid" NOT NULL,
    "resource_type" "text" NOT NULL,
    "url" "text",
    "storage_path" "text",
    "file_name" "text",
    "file_size" integer,
    "title" "text",
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "shared_resources_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "shared_resources_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE,
    CONSTRAINT "shared_resources_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id"),
    CONSTRAINT "shared_resources_resource_type_check" CHECK ("resource_type" IN ('link', 'file')),
    CONSTRAINT "shared_resources_type_fields" CHECK (
        ("resource_type" = 'link' AND "url" IS NOT NULL AND "storage_path" IS NULL)
        OR ("resource_type" = 'file' AND "storage_path" IS NOT NULL AND "file_name" IS NOT NULL AND "url" IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS "idx_shared_resources_student_id"
    ON "public"."shared_resources" ("student_id");

CREATE TRIGGER "set_shared_resources_updated_at"
    BEFORE UPDATE ON "public"."shared_resources"
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE "public"."shared_resources" ENABLE ROW LEVEL SECURITY;

-- Anyone with student access can read resources
CREATE POLICY "read_resources" ON "public"."shared_resources"
    FOR SELECT USING (can_access_student(student_id));

-- Anyone with student access can add resources (must set added_by to own id)
CREATE POLICY "insert_resources" ON "public"."shared_resources"
    FOR INSERT WITH CHECK (
        can_access_student(student_id) AND added_by = auth.uid()
    );

-- Users can update their own resources only
CREATE POLICY "update_own_resources" ON "public"."shared_resources"
    FOR UPDATE USING (added_by = auth.uid())
    WITH CHECK (added_by = auth.uid());

-- Users can delete their own resources only
CREATE POLICY "delete_own_resources" ON "public"."shared_resources"
    FOR DELETE USING (added_by = auth.uid());

-- Admins get full access
CREATE POLICY "admin_all_resources" ON "public"."shared_resources"
    FOR ALL USING (current_user_role() = 'admin');
