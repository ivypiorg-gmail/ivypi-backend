-- Create the student-documents storage bucket (private, no public access)
INSERT INTO storage.buckets (id, name, public)
VALUES ('student-documents', 'student-documents', false)
ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to upload files for students they can access
CREATE POLICY "Authenticated users can upload student documents"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'student-documents'
  AND public.can_access_student(split_part(name, '/', 1)::uuid)
);

-- Allow authenticated users to view/download files for students they can access
CREATE POLICY "Authenticated users can read student documents"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'student-documents'
  AND public.can_access_student(split_part(name, '/', 1)::uuid)
);

-- Allow authenticated users to update files for students they can access
CREATE POLICY "Authenticated users can update student documents"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'student-documents'
  AND public.can_access_student(split_part(name, '/', 1)::uuid)
);

-- Allow authenticated users to delete files for students they can access
CREATE POLICY "Authenticated users can delete student documents"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'student-documents'
  AND public.can_access_student(split_part(name, '/', 1)::uuid)
);
