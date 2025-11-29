-- Update the RLS policy to allow both students and instructors to view assessments
-- Students need to see assessments to take them, instructors need to manage them
-- Hidden test cases will be restricted at the application level

DROP POLICY IF EXISTS "Only instructors can view full assessments" ON public.assessments;

CREATE POLICY "Authenticated users can view assessments" 
ON public.assessments 
FOR SELECT 
USING (auth.uid() IS NOT NULL);