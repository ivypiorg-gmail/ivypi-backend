-- New demographic and profile fields on students
ALTER TABLE students
  ADD COLUMN first_name TEXT,
  ADD COLUMN last_name TEXT,
  ADD COLUMN date_of_birth DATE,
  ADD COLUMN gender TEXT,
  ADD COLUMN ethnicity TEXT,
  ADD COLUMN ability_to_pay TEXT,
  ADD COLUMN education_status TEXT,
  ADD COLUMN education_status_detail TEXT,
  ADD COLUMN class_rank TEXT,
  ADD COLUMN college_start_year INTEGER,
  ADD COLUMN college_start_semester TEXT,
  ADD COLUMN country TEXT DEFAULT 'United States',
  ADD COLUMN state TEXT,
  ADD COLUMN zip_code TEXT;

-- Backfill first_name/last_name from full_name where possible
UPDATE students
SET
  first_name = split_part(full_name, ' ', 1),
  last_name = CASE
    WHEN position(' ' IN full_name) > 0
    THEN substring(full_name FROM position(' ' IN full_name) + 1)
    ELSE NULL
  END
WHERE first_name IS NULL;
