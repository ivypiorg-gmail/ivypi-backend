-- Portfolio Optimizer: enums, tables, columns, function, RLS, indexes

-- 1. app_round enum + column on college_lists
CREATE TYPE app_round AS ENUM ('ed', 'ed2', 'ea', 'rea', 'rd');
ALTER TABLE college_lists ADD COLUMN app_round app_round;

-- 2. portfolio_alerts enums + table
CREATE TYPE portfolio_alert_type AS ENUM (
  'ed_conflict',
  'school_overlap',
  'deadline_cluster',
  'positioning_collision',
  'opportunity',
  'timing_risk'
);

CREATE TYPE alert_severity AS ENUM ('high', 'medium', 'low');

CREATE TABLE portfolio_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  counselor_id UUID NOT NULL REFERENCES profiles(id),
  alert_type portfolio_alert_type NOT NULL,
  severity alert_severity NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  student_ids UUID[] NOT NULL,
  school_names TEXT[] DEFAULT '{}',
  recommendation TEXT,
  alert_scenarios JSONB DEFAULT '[]',
  dismissed_at TIMESTAMPTZ,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_portfolio_alerts_counselor ON portfolio_alerts(counselor_id);
CREATE INDEX idx_portfolio_alerts_undismissed ON portfolio_alerts(counselor_id)
  WHERE dismissed_at IS NULL;

CREATE TRIGGER set_portfolio_alerts_updated_at
  BEFORE UPDATE ON portfolio_alerts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 3. RLS on portfolio_alerts
ALTER TABLE portfolio_alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Counselors read own alerts"
  ON portfolio_alerts FOR SELECT
  USING (counselor_id = auth.uid());

CREATE POLICY "Counselors dismiss own alerts"
  ON portfolio_alerts FOR UPDATE
  USING (counselor_id = auth.uid())
  WITH CHECK (counselor_id = auth.uid());

CREATE POLICY "Admins read all alerts"
  ON portfolio_alerts FOR SELECT
  USING (public.current_user_role() = 'admin');

-- 4. Extend scenarios table
ALTER TABLE scenarios
  ADD COLUMN source_alert_id UUID REFERENCES portfolio_alerts(id) ON DELETE SET NULL,
  ADD COLUMN suggested_by TEXT NOT NULL DEFAULT 'counselor'
    CHECK (suggested_by IN ('counselor', 'ai'));

-- Allow counselors to update their own scenarios (for setting suggested_by after creation)
CREATE POLICY "Counselors update own student scenarios"
  ON scenarios FOR UPDATE
  USING (
    student_id IN (SELECT id FROM students WHERE counselor_id = auth.uid())
    OR public.current_user_role() = 'admin'
  );

-- 5. Extend narrative_arcs table
ALTER TABLE narrative_arcs
  ADD COLUMN suggested_scenarios JSONB DEFAULT '[]';

-- 6. detect_portfolio_alerts function
CREATE OR REPLACE FUNCTION detect_portfolio_alerts(p_counselor_id UUID)
RETURNS TABLE (
  alert_type portfolio_alert_type,
  severity alert_severity,
  title TEXT,
  description TEXT,
  student_ids UUID[],
  school_names TEXT[]
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  -- ED conflicts: 2+ students applying ED/ED2 to the same school
  RETURN QUERY
  SELECT
    'ed_conflict'::public.portfolio_alert_type,
    'high'::public.alert_severity,
    format('ED Conflict at %s', cl.school_name),
    format('%s students targeting %s for Early Decision',
           array_length(array_agg(DISTINCT s.id), 1), cl.school_name),
    array_agg(DISTINCT s.id),
    ARRAY[cl.school_name]
  FROM public.college_lists cl
  JOIN public.students s ON cl.student_id = s.id
  WHERE s.counselor_id = p_counselor_id
    AND s.status = 'active'
    AND cl.app_round IN ('ed', 'ed2')
    AND cl.app_status IN ('considering', 'applying', 'applied')
  GROUP BY cl.school_name
  HAVING count(DISTINCT s.id) >= 2;

  -- School overlap: 3+ students targeting the same school (any round/status)
  RETURN QUERY
  SELECT
    'school_overlap'::public.portfolio_alert_type,
    'medium'::public.alert_severity,
    format('School Overlap: %s', cl.school_name),
    format('%s students have %s on their list',
           array_length(array_agg(DISTINCT s.id), 1), cl.school_name),
    array_agg(DISTINCT s.id),
    ARRAY[cl.school_name]
  FROM public.college_lists cl
  JOIN public.students s ON cl.student_id = s.id
  WHERE s.counselor_id = p_counselor_id
    AND s.status = 'active'
  GROUP BY cl.school_name
  HAVING count(DISTINCT s.id) >= 3;

  -- Deadline clusters: 3+ pending deadlines within any 5-day sliding window
  RETURN QUERY
  WITH upcoming AS (
    SELECT sd.student_id, sd.due_date, sd.school_name
    FROM public.student_deadlines sd
    JOIN public.students s ON sd.student_id = s.id
    WHERE s.counselor_id = p_counselor_id
      AND s.status = 'active'
      AND sd.status = 'pending'
      AND sd.due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'
  ),
  windowed AS (
    SELECT
      a.student_id,
      a.due_date AS window_start,
      a.due_date + 5 AS window_end,
      count(*) AS cnt,
      array_agg(DISTINCT b.school_name) AS schools
    FROM upcoming a
    JOIN upcoming b ON a.student_id = b.student_id
      AND b.due_date BETWEEN a.due_date AND a.due_date + 5
    GROUP BY a.student_id, a.due_date
    HAVING count(*) >= 3
  )
  SELECT DISTINCT ON (w.student_id)
    'deadline_cluster'::public.portfolio_alert_type,
    'medium'::public.alert_severity,
    format('Deadline Cluster: %s', s.full_name),
    format('%s has %s deadlines in a 5-day window starting %s',
           s.full_name, w.cnt, w.window_start::TEXT),
    ARRAY[w.student_id],
    w.schools
  FROM windowed w
  JOIN public.students s ON w.student_id = s.id
  ORDER BY w.student_id, w.cnt DESC;
END;
$$;
