-- Add application_cycle to students with auto-derive trigger

ALTER TABLE students ADD COLUMN IF NOT EXISTS application_cycle INTEGER;

-- Auto-derive from grad_year when application_cycle is null
CREATE OR REPLACE FUNCTION derive_application_cycle() RETURNS trigger AS $$
BEGIN
  IF NEW.application_cycle IS NULL AND NEW.grad_year IS NOT NULL THEN
    NEW.application_cycle := NEW.grad_year;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER students_derive_application_cycle
  BEFORE INSERT OR UPDATE ON students
  FOR EACH ROW EXECUTE FUNCTION derive_application_cycle();

-- Backfill existing students
UPDATE students SET application_cycle = grad_year
WHERE application_cycle IS NULL AND grad_year IS NOT NULL;
