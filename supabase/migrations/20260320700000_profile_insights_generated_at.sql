-- Add a timestamp for when profile insights were last generated
ALTER TABLE students
  ADD COLUMN profile_insights_generated_at TIMESTAMPTZ;
