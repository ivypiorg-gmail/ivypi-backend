-- Add suggested_scenarios columns to students table
ALTER TABLE "public"."students"
  ADD COLUMN IF NOT EXISTS "suggested_scenarios" jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS "suggested_scenarios_generated_at" timestamptz;

-- Migrate existing data from narrative_arcs to students
UPDATE "public"."students" s
SET
  suggested_scenarios = na.suggested_scenarios,
  suggested_scenarios_generated_at = na.updated_at
FROM "public"."narrative_arcs" na
WHERE na.student_id = s.id
  AND na.suggested_scenarios IS NOT NULL
  AND na.suggested_scenarios != '[]'::jsonb;

-- Leave narrative_arcs.suggested_scenarios in place for now (deprecate, drop in follow-up)
COMMENT ON COLUMN "public"."narrative_arcs"."suggested_scenarios" IS 'DEPRECATED — migrated to students.suggested_scenarios';
