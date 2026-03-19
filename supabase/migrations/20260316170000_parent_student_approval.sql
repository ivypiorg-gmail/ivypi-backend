-- Add pending_approval to student_status enum
-- This must be in its own transaction; policies using this value go in the next migration.
ALTER TYPE student_status ADD VALUE IF NOT EXISTS 'pending_approval';
