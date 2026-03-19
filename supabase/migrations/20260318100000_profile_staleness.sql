-- Add profile_stale flag to students
ALTER TABLE students ADD COLUMN IF NOT EXISTS profile_stale BOOLEAN NOT NULL DEFAULT false;

-- Trigger function: mark student profile as stale
CREATE OR REPLACE FUNCTION set_profile_stale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE students SET profile_stale = true WHERE id = OLD.student_id;
    RETURN OLD;
  ELSE
    UPDATE students SET profile_stale = true WHERE id = NEW.student_id;
    RETURN NEW;
  END IF;
END;
$$;

-- Trigger on courses INSERT/DELETE
CREATE TRIGGER trg_courses_stale_profile
  AFTER INSERT OR DELETE ON courses
  FOR EACH ROW EXECUTE FUNCTION set_profile_stale();

-- Trigger on activities INSERT/DELETE
CREATE TRIGGER trg_activities_stale_profile
  AFTER INSERT OR DELETE ON activities
  FOR EACH ROW EXECUTE FUNCTION set_profile_stale();

-- Trigger on awards INSERT/DELETE
CREATE TRIGGER trg_awards_stale_profile
  AFTER INSERT OR DELETE ON awards
  FOR EACH ROW EXECUTE FUNCTION set_profile_stale();

-- Trigger function: mark stale when test_scores or survey_responses change on students
CREATE OR REPLACE FUNCTION set_profile_stale_on_student_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF (OLD.test_scores IS DISTINCT FROM NEW.test_scores)
     OR (OLD.survey_responses IS DISTINCT FROM NEW.survey_responses) THEN
    NEW.profile_stale := true;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_students_stale_profile
  BEFORE UPDATE ON students
  FOR EACH ROW EXECUTE FUNCTION set_profile_stale_on_student_update();
