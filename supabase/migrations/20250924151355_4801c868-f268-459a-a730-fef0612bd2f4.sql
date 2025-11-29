-- Add foreign key relationship between assessment_submissions and profiles
-- This will allow PostgREST to automatically join the tables

-- First, let's add the foreign key constraint
ALTER TABLE public.assessment_submissions 
ADD CONSTRAINT fk_assessment_submissions_student_profile 
FOREIGN KEY (student_id) REFERENCES public.profiles(user_id);

-- Add index for better performance on joins
CREATE INDEX IF NOT EXISTS idx_assessment_submissions_student_id 
ON public.assessment_submissions(student_id);