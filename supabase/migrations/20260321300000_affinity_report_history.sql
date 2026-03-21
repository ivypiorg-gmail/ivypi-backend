-- Track when the current affinity report was generated
ALTER TABLE college_lists ADD COLUMN affinity_generated_at timestamptz;

-- Store previous generations as a JSONB array of {report, generated_at}
ALTER TABLE college_lists ADD COLUMN affinity_report_history jsonb DEFAULT '[]'::jsonb;
