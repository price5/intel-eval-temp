-- Create practice_problems table for pre-defined coding problems
CREATE TABLE public.practice_problems (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  problem_statement TEXT NOT NULL,
  problem_description TEXT NOT NULL,
  difficulty TEXT NOT NULL CHECK (difficulty IN ('easy', 'medium', 'hard')),
  topic TEXT NOT NULL CHECK (topic IN ('Data Structures', 'Algorithms', 'OOP', 'DBMS', 'Web Development', 'Problem-solving')),
  test_cases JSONB NOT NULL DEFAULT '[]'::jsonb,
  hidden_test_cases JSONB NOT NULL DEFAULT '[]'::jsonb,
  points INTEGER NOT NULL DEFAULT 100,
  created_by UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  is_active BOOLEAN NOT NULL DEFAULT true
);

-- Enable RLS
ALTER TABLE public.practice_problems ENABLE ROW LEVEL SECURITY;

-- Policy: All authenticated users can view active practice problems
CREATE POLICY "Authenticated users can view active practice problems"
ON public.practice_problems
FOR SELECT
USING (auth.uid() IS NOT NULL AND is_active = true);

-- Policy: Admins can manage practice problems
CREATE POLICY "Admins can manage practice problems"
ON public.practice_problems
FOR ALL
USING (has_role(auth.uid(), 'admin'::app_role));

-- Create trigger to update updated_at
CREATE TRIGGER update_practice_problems_updated_at
BEFORE UPDATE ON public.practice_problems
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Create index for faster queries
CREATE INDEX idx_practice_problems_topic ON public.practice_problems(topic);
CREATE INDEX idx_practice_problems_difficulty ON public.practice_problems(difficulty);
CREATE INDEX idx_practice_problems_active ON public.practice_problems(is_active);

-- Create practice_problem_submissions table to track student attempts
CREATE TABLE public.practice_problem_submissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  problem_id UUID NOT NULL REFERENCES public.practice_problems(id) ON DELETE CASCADE,
  student_id UUID NOT NULL,
  code TEXT NOT NULL,
  language TEXT NOT NULL DEFAULT 'python',
  explanation TEXT,
  code_score INTEGER,
  explanation_score INTEGER,
  overall_score INTEGER,
  code_feedback TEXT,
  explanation_feedback TEXT,
  code_heatmap JSONB DEFAULT '[]'::jsonb,
  explanation_heatmap JSONB DEFAULT '[]'::jsonb,
  test_results JSONB DEFAULT '[]'::jsonb,
  strengths JSONB DEFAULT '[]'::jsonb,
  improvements JSONB DEFAULT '[]'::jsonb,
  recommendations JSONB DEFAULT '[]'::jsonb,
  status TEXT NOT NULL DEFAULT 'pending',
  submitted_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  evaluated_at TIMESTAMP WITH TIME ZONE
);

-- Enable RLS on submissions
ALTER TABLE public.practice_problem_submissions ENABLE ROW LEVEL SECURITY;

-- Policy: Students can manage their own submissions
CREATE POLICY "Students can manage their own problem submissions"
ON public.practice_problem_submissions
FOR ALL
USING (student_id = auth.uid());

-- Policy: Admins can view all submissions
CREATE POLICY "Admins can view all problem submissions"
ON public.practice_problem_submissions
FOR SELECT
USING (has_role(auth.uid(), 'admin'::app_role));

-- Create indexes for submissions
CREATE INDEX idx_practice_problem_submissions_student ON public.practice_problem_submissions(student_id);
CREATE INDEX idx_practice_problem_submissions_problem ON public.practice_problem_submissions(problem_id);

-- Trigger to update user stats on practice problem submission
CREATE OR REPLACE FUNCTION public.update_user_stats_on_practice_problem()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Increment submissions count
  INSERT INTO user_stats (user_id, submissions_count)
  VALUES (NEW.student_id, 1)
  ON CONFLICT (user_id)
  DO UPDATE SET 
    submissions_count = user_stats.submissions_count + 1,
    updated_at = now();
    
  -- Check if it's a perfect score
  IF NEW.overall_score = 100 THEN
    UPDATE user_stats 
    SET 
      perfect_scores = perfect_scores + 1,
      updated_at = now()
    WHERE user_id = NEW.student_id;
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_update_stats_practice_problem
AFTER INSERT ON public.practice_problem_submissions
FOR EACH ROW
WHEN (NEW.status = 'completed')
EXECUTE FUNCTION public.update_user_stats_on_practice_problem();