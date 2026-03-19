CREATE TABLE college_data_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_name text NOT NULL,
  submitted_by uuid REFERENCES auth.users(id) NOT NULL,
  note text NOT NULL,
  status text DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'dismissed')),
  resolved_by uuid REFERENCES auth.users(id),
  created_at timestamptz DEFAULT now(),
  resolved_at timestamptz
);

ALTER TABLE college_data_corrections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can submit corrections"
  ON college_data_corrections FOR INSERT
  TO authenticated WITH CHECK (submitted_by = auth.uid());

CREATE POLICY "Admins see all corrections"
  ON college_data_corrections FOR SELECT
  TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'counselor'))
    OR submitted_by = auth.uid()
  );

CREATE POLICY "Admins can update corrections"
  ON college_data_corrections FOR UPDATE
  TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'counselor'))
  );
