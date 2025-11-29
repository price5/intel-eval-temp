-- Add evaluation results and explanation columns to assessment_submissions
ALTER TABLE public.assessment_submissions 
ADD COLUMN explanation text,
ADD COLUMN code_score integer,
ADD COLUMN explanation_score integer,
ADD COLUMN overall_score integer,
ADD COLUMN strengths jsonb DEFAULT '[]'::jsonb,
ADD COLUMN improvements jsonb DEFAULT '[]'::jsonb,
ADD COLUMN recommendations jsonb DEFAULT '[]'::jsonb,
ADD COLUMN code_feedback text,
ADD COLUMN explanation_feedback text;

-- Create a table to store practice session results for students
CREATE TABLE public.practice_sessions (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  student_id uuid NOT NULL,
  language text NOT NULL,
  code text NOT NULL,
  explanation text NOT NULL,
  code_score integer NOT NULL,
  explanation_score integer NOT NULL,
  overall_score integer NOT NULL,
  code_weight integer NOT NULL DEFAULT 70,
  strengths jsonb NOT NULL DEFAULT '[]'::jsonb,
  improvements jsonb NOT NULL DEFAULT '[]'::jsonb,
  recommendations jsonb NOT NULL DEFAULT '[]'::jsonb,
  code_feedback text NOT NULL,
  explanation_feedback text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Enable RLS on practice_sessions
ALTER TABLE public.practice_sessions ENABLE ROW LEVEL SECURITY;

-- Create policies for practice_sessions
CREATE POLICY "Students can manage their own practice sessions" 
ON public.practice_sessions 
FOR ALL 
USING (student_id = auth.uid());

-- Create trigger for updated_at on assessment_submissions
CREATE TRIGGER update_assessment_submissions_updated_at
BEFORE UPDATE ON public.assessment_submissions
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();