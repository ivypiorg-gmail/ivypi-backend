-- Add published_at column (NULL = draft, non-null = published/sent)
ALTER TABLE shared_insights ADD COLUMN published_at timestamptz;

-- Backfill existing rows so they remain visible to parents
UPDATE shared_insights SET published_at = created_at WHERE published_at IS NULL;

-- Add 'oracle' to source_type CHECK constraint
ALTER TABLE shared_insights DROP CONSTRAINT shared_insights_source_type_check;
ALTER TABLE shared_insights ADD CONSTRAINT shared_insights_source_type_check
  CHECK (source_type = ANY(ARRAY['affinity','simulation','deadline','narrative','manual','oracle']));

-- Update parent policy: only see published insights
DROP POLICY IF EXISTS "parent_read_insights" ON shared_insights;
CREATE POLICY "parent_read_insights" ON shared_insights
  FOR SELECT USING (can_access_student(student_id) AND published_at IS NOT NULL);
