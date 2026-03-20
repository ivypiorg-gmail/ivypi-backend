-- Fix critical issues from backend audit

-- 1. Add missing indexes on frequently queried FK columns
CREATE INDEX IF NOT EXISTS idx_notifications_log_student_deadline
  ON notifications_log(student_deadline_id) WHERE student_deadline_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notifications_log_recipient
  ON notifications_log(recipient_id) WHERE recipient_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_college_suggestions_college_list
  ON college_suggestions(college_list_id) WHERE college_list_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_comments_author
  ON comments(author_id);
