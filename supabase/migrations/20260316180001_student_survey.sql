-- Add survey columns to students table
ALTER TABLE public.students
  ADD COLUMN survey_token TEXT UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
  ADD COLUMN survey_responses JSONB DEFAULT NULL,
  ADD COLUMN survey_completed_at TIMESTAMPTZ DEFAULT NULL;
