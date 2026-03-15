-- Student Profiles & AI Analytics Platform
-- Adds student management, document intake, AI-parsed transcripts,
-- profile generation, and college affinity reports.

-- ══════════════════════════════════════════════════════════════
-- 1. CUSTOM TYPES
-- ══════════════════════════════════════════════════════════════

CREATE TYPE public.student_status AS ENUM (
  'active', 'inactive', 'graduated', 'deferred'
);

CREATE TYPE public.document_type AS ENUM (
  'transcript', 'resume', 'activity_list'
);

CREATE TYPE public.parse_status AS ENUM (
  'pending', 'processing', 'complete', 'failed'
);

CREATE TYPE public.subject_area AS ENUM (
  'math', 'science', 'english', 'history', 'foreign_language',
  'arts', 'computer_science', 'social_science', 'other'
);

CREATE TYPE public.course_level AS ENUM (
  'regular', 'honors', 'ap', 'ib', 'dual_enrollment', 'other'
);

CREATE TYPE public.activity_category AS ENUM (
  'academic', 'arts', 'athletics', 'community_service',
  'leadership', 'work', 'research', 'other'
);

CREATE TYPE public.depth_tier AS ENUM (
  'exceptional', 'strong', 'moderate', 'introductory'
);

CREATE TYPE public.app_status AS ENUM (
  'considering', 'applying', 'applied', 'accepted',
  'rejected', 'waitlisted', 'deferred', 'committed'
);

-- ══════════════════════════════════════════════════════════════
-- 2. TABLES
-- ══════════════════════════════════════════════════════════════

-- Students
CREATE TABLE public.students (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES public.profiles(id),
  counselor_id  UUID REFERENCES public.profiles(id),
  full_name     TEXT NOT NULL,
  grad_year     INT,
  high_school   TEXT,
  gpa_unweighted NUMERIC(4,2),
  gpa_weighted   NUMERIC(4,2),
  test_scores   JSONB DEFAULT '{}',
  profile_insights JSONB DEFAULT '{}',
  status        public.student_status NOT NULL DEFAULT 'active',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id)
);

-- Documents
CREATE TABLE public.documents (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id    UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  type          public.document_type NOT NULL,
  file_name     TEXT NOT NULL,
  storage_path  TEXT,
  file_size     INT,
  parsed_data   JSONB DEFAULT '{}',
  parse_status  public.parse_status NOT NULL DEFAULT 'pending',
  parse_error   TEXT,
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Courses (parsed from transcripts)
CREATE TABLE public.courses (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id    UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  document_id   UUID REFERENCES public.documents(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  subject_area  public.subject_area,
  level         public.course_level DEFAULT 'regular',
  grade         TEXT,
  year          TEXT,
  semester      TEXT
);

-- Activities (parsed from resumes / activity lists)
CREATE TABLE public.activities (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id        UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  document_id       UUID REFERENCES public.documents(id) ON DELETE SET NULL,
  name              TEXT NOT NULL,
  category          public.activity_category DEFAULT 'other',
  role              TEXT,
  years_active      INT[],
  hours_per_week    NUMERIC(4,1),
  impact_description TEXT,
  depth_tier        public.depth_tier,
  depth_narrative   TEXT
);

-- College Lists
CREATE TABLE public.college_lists (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id      UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  school_name     TEXT NOT NULL,
  affinity_report JSONB DEFAULT '{}',
  counselor_notes TEXT,
  app_status      public.app_status NOT NULL DEFAULT 'considering',
  decision_date   DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(student_id, school_name)
);

-- ══════════════════════════════════════════════════════════════
-- 3. INDEXES
-- ══════════════════════════════════════════════════════════════

CREATE INDEX idx_students_user_id       ON public.students(user_id);
CREATE INDEX idx_students_counselor_id  ON public.students(counselor_id);
CREATE INDEX idx_documents_student_id   ON public.documents(student_id);
CREATE INDEX idx_courses_student_id     ON public.courses(student_id);
CREATE INDEX idx_courses_document_id    ON public.courses(document_id);
CREATE INDEX idx_activities_student_id  ON public.activities(student_id);
CREATE INDEX idx_activities_document_id ON public.activities(document_id);
CREATE INDEX idx_college_lists_student_id ON public.college_lists(student_id);

-- ══════════════════════════════════════════════════════════════
-- 4. UPDATED_AT TRIGGERS (reuse existing function)
-- ══════════════════════════════════════════════════════════════

CREATE TRIGGER set_students_updated_at
  BEFORE UPDATE ON public.students
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER set_college_lists_updated_at
  BEFORE UPDATE ON public.college_lists
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ══════════════════════════════════════════════════════════════
-- 5. RLS HELPER
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.can_access_student(p_student_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_role   TEXT;
  v_uid    UUID;
  v_match  BOOLEAN;
BEGIN
  v_uid  := auth.uid();
  v_role := public.current_user_role();

  -- Admins can access all students
  IF v_role = 'admin' THEN
    RETURN TRUE;
  END IF;

  -- Check if caller is the student or the assigned counselor
  SELECT EXISTS(
    SELECT 1 FROM public.students
    WHERE id = p_student_id
      AND (user_id = v_uid OR counselor_id = v_uid)
  ) INTO v_match;

  RETURN v_match;
END;
$$;

-- ══════════════════════════════════════════════════════════════
-- 6. ROW LEVEL SECURITY
-- ══════════════════════════════════════════════════════════════

-- Students table
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own student record"
  ON public.students FOR SELECT
  USING (public.can_access_student(id));

CREATE POLICY "Counselors can insert students"
  ON public.students FOR INSERT
  WITH CHECK (public.current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "Counselors can update assigned students"
  ON public.students FOR UPDATE
  USING (public.can_access_student(id))
  WITH CHECK (public.current_user_role() IN ('counselor', 'admin'));

CREATE POLICY "Admins can delete students"
  ON public.students FOR DELETE
  USING (public.current_user_role() = 'admin');

-- Documents table
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own documents"
  ON public.documents FOR SELECT
  USING (public.can_access_student(student_id));

CREATE POLICY "Users can upload documents"
  ON public.documents FOR INSERT
  WITH CHECK (public.can_access_student(student_id));

CREATE POLICY "Users can update own documents"
  ON public.documents FOR UPDATE
  USING (public.can_access_student(student_id));

CREATE POLICY "Users can delete own documents"
  ON public.documents FOR DELETE
  USING (public.can_access_student(student_id));

-- Courses table
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own courses"
  ON public.courses FOR SELECT
  USING (public.can_access_student(student_id));

CREATE POLICY "Counselors can manage courses"
  ON public.courses FOR ALL
  USING (public.can_access_student(student_id))
  WITH CHECK (public.current_user_role() IN ('counselor', 'admin'));

-- Activities table
ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own activities"
  ON public.activities FOR SELECT
  USING (public.can_access_student(student_id));

CREATE POLICY "Counselors can manage activities"
  ON public.activities FOR ALL
  USING (public.can_access_student(student_id))
  WITH CHECK (public.current_user_role() IN ('counselor', 'admin'));

-- College Lists table
ALTER TABLE public.college_lists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own college list"
  ON public.college_lists FOR SELECT
  USING (public.can_access_student(student_id));

CREATE POLICY "Users can add to college list"
  ON public.college_lists FOR INSERT
  WITH CHECK (public.can_access_student(student_id));

CREATE POLICY "Users can update college list"
  ON public.college_lists FOR UPDATE
  USING (public.can_access_student(student_id));

CREATE POLICY "Users can remove from college list"
  ON public.college_lists FOR DELETE
  USING (public.can_access_student(student_id));
