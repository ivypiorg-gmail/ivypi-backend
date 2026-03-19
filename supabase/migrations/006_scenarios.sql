-- Scenario Modeling
-- Allows counselors to create "what-if" scenarios for students
-- and see projected profile changes.

CREATE TABLE public.scenarios (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id           UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  name                 TEXT NOT NULL,
  modifications        JSONB NOT NULL DEFAULT '[]',
  projected_insights   JSONB,
  projected_affinities JSONB,
  scenario_narrative   TEXT,
  created_by           UUID REFERENCES auth.users(id),
  created_at           TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_scenarios_student_id ON public.scenarios(student_id);

-- RLS
ALTER TABLE public.scenarios ENABLE ROW LEVEL SECURITY;

CREATE POLICY "counselors_read_scenarios" ON public.scenarios
  FOR SELECT USING (
    student_id IN (SELECT id FROM public.students WHERE counselor_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "counselors_write_scenarios" ON public.scenarios
  FOR INSERT WITH CHECK (
    student_id IN (SELECT id FROM public.students WHERE counselor_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "admins_delete_scenarios" ON public.scenarios
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );
