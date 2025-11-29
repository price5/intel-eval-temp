-- Create assessments table for instructor-created tests
CREATE TABLE public.assessments (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  problem_statement text NOT NULL,
  problem_description text NOT NULL,
  test_cases jsonb NOT NULL DEFAULT '[]'::jsonb,
  hidden_test_cases jsonb NOT NULL DEFAULT '[]'::jsonb,
  time_limit integer NOT NULL DEFAULT 60, -- in minutes
  difficulty text NOT NULL CHECK (difficulty IN ('easy', 'medium', 'hard')),
  points integer NOT NULL DEFAULT 100,
  deadline timestamp with time zone,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Create student assessment submissions table
CREATE TABLE public.assessment_submissions (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  assessment_id uuid NOT NULL REFERENCES public.assessments(id) ON DELETE CASCADE,
  student_id uuid NOT NULL,
  code text NOT NULL,
  language text NOT NULL DEFAULT 'python',
  score integer,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'completed', 'error')),
  submitted_at timestamp with time zone NOT NULL DEFAULT now(),
  evaluated_at timestamp with time zone,
  test_results jsonb DEFAULT '[]'::jsonb
);

-- Enable Row Level Security
ALTER TABLE public.assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_submissions ENABLE ROW LEVEL SECURITY;

-- Policies for assessments table
CREATE POLICY "Instructors can manage their assessments" 
ON public.assessments 
FOR ALL 
USING (created_by = auth.uid());

CREATE POLICY "Students can view active assessments" 
ON public.assessments 
FOR SELECT 
USING (is_active = true AND (deadline IS NULL OR deadline > now()));

-- Policies for assessment_submissions table
CREATE POLICY "Students can manage their own submissions" 
ON public.assessment_submissions 
FOR ALL 
USING (student_id = auth.uid());

CREATE POLICY "Instructors can view submissions for their assessments" 
ON public.assessment_submissions 
FOR SELECT 
USING (assessment_id IN (
  SELECT id FROM public.assessments WHERE created_by = auth.uid()
));

-- Add triggers for automatic timestamp updates
CREATE TRIGGER update_assessments_updated_at
BEFORE UPDATE ON public.assessments
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Update the profiles table to add days_active field
ALTER TABLE public.profiles 
ADD COLUMN days_active integer DEFAULT 1;