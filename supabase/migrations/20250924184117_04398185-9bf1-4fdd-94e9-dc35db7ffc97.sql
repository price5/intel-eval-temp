-- Create badge definitions table
CREATE TABLE public.badge_definitions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL,
  category TEXT NOT NULL, -- 'tier', 'specialty', 'achievement'
  criteria JSONB NOT NULL, -- Criteria for earning the badge
  icon TEXT, -- Icon identifier or emoji
  color TEXT, -- Badge color theme
  tier_order INTEGER, -- For tier-based badges (1=lowest, 5=highest)
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create user badges table
CREATE TABLE public.user_badges (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  badge_id UUID NOT NULL REFERENCES public.badge_definitions(id) ON DELETE CASCADE,
  earned_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  season TEXT, -- e.g., '2024-01' for monthly seasons
  UNIQUE(user_id, badge_id, season)
);

-- Create leaderboard history table
CREATE TABLE public.leaderboard_history (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  season TEXT NOT NULL, -- e.g., '2024-01'
  rank_overall INTEGER,
  rank_code INTEGER,
  rank_explanation INTEGER,
  score_overall DECIMAL(5,2),
  score_code DECIMAL(5,2),
  score_explanation DECIMAL(5,2),
  total_submissions INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, season)
);

-- Create user rankings cache table
CREATE TABLE public.user_rankings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  current_rank_overall INTEGER,
  current_rank_code INTEGER,
  current_rank_explanation INTEGER,
  highest_rank_overall INTEGER,
  highest_rank_code INTEGER,
  highest_rank_explanation INTEGER,
  avg_score_overall DECIMAL(5,2),
  avg_score_code DECIMAL(5,2),
  avg_score_explanation DECIMAL(5,2),
  total_submissions INTEGER NOT NULL DEFAULT 0,
  last_updated TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id)
);

-- Add badge tier to profiles
ALTER TABLE public.profiles 
ADD COLUMN current_badge_tier TEXT DEFAULT 'Novice Coder',
ADD COLUMN highest_rank_overall INTEGER,
ADD COLUMN highest_rank_code INTEGER,
ADD COLUMN highest_rank_explanation INTEGER;

-- Enable RLS on new tables
ALTER TABLE public.badge_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leaderboard_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_rankings ENABLE ROW LEVEL SECURITY;

-- RLS policies for badge_definitions (everyone can read)
CREATE POLICY "Everyone can view badge definitions" 
ON public.badge_definitions 
FOR SELECT 
USING (true);

-- RLS policies for user_badges
CREATE POLICY "Users can view all badges" 
ON public.user_badges 
FOR SELECT 
USING (true);

CREATE POLICY "System can manage badges" 
ON public.user_badges 
FOR ALL 
USING (auth.uid() IS NOT NULL);

-- RLS policies for leaderboard_history
CREATE POLICY "Everyone can view leaderboard history" 
ON public.leaderboard_history 
FOR SELECT 
USING (true);

CREATE POLICY "System can manage leaderboard history" 
ON public.leaderboard_history 
FOR ALL 
USING (auth.uid() IS NOT NULL);

-- RLS policies for user_rankings
CREATE POLICY "Everyone can view user rankings" 
ON public.user_rankings 
FOR SELECT 
USING (true);

CREATE POLICY "System can manage user rankings" 
ON public.user_rankings 
FOR ALL 
USING (auth.uid() IS NOT NULL);

-- Insert initial badge definitions
INSERT INTO public.badge_definitions (name, description, category, criteria, icon, color, tier_order) VALUES
-- Tier-based badges
('Novice Coder', 'Starting your coding journey', 'tier', '{"min_avg_score": 0, "max_avg_score": 50}', '🌱', 'gray', 1),
('Apprentice Developer', 'Developing solid programming skills', 'tier', '{"min_avg_score": 51, "max_avg_score": 70}', '⚡', 'blue', 2),
('Skilled Programmer', 'Demonstrating advanced coding abilities', 'tier', '{"min_avg_score": 71, "max_avg_score": 85}', '🔥', 'purple', 3),
('Expert Coder', 'Mastery of programming concepts', 'tier', '{"min_avg_score": 86, "max_avg_score": 95}', '💎', 'gold', 4),
('Code Master', 'Exceptional programming excellence', 'tier', '{"min_avg_score": 96, "max_avg_score": 100}', '👑', 'rainbow', 5),

-- Specialty badges
('Logic Lord', 'Top 10% in Code Masters category', 'specialty', '{"category": "code", "percentile": 90}', '🧠', 'blue', NULL),
('Word Wizard', 'Top 10% in Wordsmiths category', 'specialty', '{"category": "explanation", "percentile": 90}', '📝', 'green', NULL),
('Balanced Brain', 'Top 10% in Balanced Thinkers category', 'specialty', '{"category": "overall", "percentile": 90}', '⚖️', 'purple', NULL),
('Streak Sage', 'Maintained 30+ day streak', 'specialty', '{"min_streak": 30}', '🔥', 'orange', NULL),
('Assessment Ace', '5+ perfect assessment scores', 'specialty', '{"perfect_scores": 5}', '🎯', 'red', NULL),
('Practice Pioneer', '50+ practice sessions completed', 'specialty', '{"min_practice_sessions": 50}', '🚀', 'cyan', NULL),

-- Achievement badges
('First Steps', 'Completed first assessment', 'achievement', '{"first_assessment": true}', '👶', 'green', NULL),
('Daily Grind', 'Login 7 days in a row', 'achievement', '{"consecutive_days": 7}', '📅', 'blue', NULL),
('Monthly Legend', '#1 in any monthly leaderboard', 'achievement', '{"monthly_rank": 1}', '🏆', 'gold', NULL),
('Triple Threat', 'Top 10 in all three categories', 'achievement', '{"all_categories_top_10": true}', '🎖️', 'rainbow', NULL);

-- Create indexes for performance
CREATE INDEX idx_user_badges_user_id ON public.user_badges(user_id);
CREATE INDEX idx_user_badges_badge_id ON public.user_badges(badge_id);
CREATE INDEX idx_user_badges_season ON public.user_badges(season);
CREATE INDEX idx_leaderboard_history_season ON public.leaderboard_history(season);
CREATE INDEX idx_leaderboard_history_user_id ON public.leaderboard_history(user_id);
CREATE INDEX idx_user_rankings_overall ON public.user_rankings(current_rank_overall);
CREATE INDEX idx_user_rankings_code ON public.user_rankings(current_rank_code);
CREATE INDEX idx_user_rankings_explanation ON public.user_rankings(current_rank_explanation);

-- Function to calculate user rankings
CREATE OR REPLACE FUNCTION public.calculate_user_rankings()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  user_record RECORD;
  rank_overall INTEGER;
  rank_code INTEGER;
  rank_explanation INTEGER;
BEGIN
  -- Clear existing rankings
  DELETE FROM public.user_rankings;
  
  -- Calculate rankings for each user with at least 3 submissions
  FOR user_record IN 
    SELECT 
      p.user_id,
      COALESCE(AVG(COALESCE(ps.overall_score, 0) + COALESCE(asub.overall_score, 0)), 0) as avg_overall,
      COALESCE(AVG(COALESCE(ps.code_score, 0) + COALESCE(asub.code_score, 0)), 0) as avg_code,
      COALESCE(AVG(COALESCE(ps.explanation_score, 0) + COALESCE(asub.explanation_score, 0)), 0) as avg_explanation,
      COUNT(ps.id) + COUNT(asub.id) as total_subs
    FROM public.profiles p
    LEFT JOIN public.practice_sessions ps ON p.user_id = ps.student_id
    LEFT JOIN public.assessment_submissions asub ON p.user_id = asub.student_id
    GROUP BY p.user_id
    HAVING COUNT(ps.id) + COUNT(asub.id) >= 3
    ORDER BY avg_overall DESC
  LOOP
    -- Calculate ranks
    SELECT COUNT(*) + 1 INTO rank_overall 
    FROM public.user_rankings 
    WHERE avg_score_overall > user_record.avg_overall;
    
    SELECT COUNT(*) + 1 INTO rank_code 
    FROM public.user_rankings 
    WHERE avg_score_code > user_record.avg_code;
    
    SELECT COUNT(*) + 1 INTO rank_explanation 
    FROM public.user_rankings 
    WHERE avg_score_explanation > user_record.avg_explanation;
    
    -- Insert ranking
    INSERT INTO public.user_rankings (
      user_id, 
      current_rank_overall, 
      current_rank_code, 
      current_rank_explanation,
      avg_score_overall,
      avg_score_code,
      avg_score_explanation,
      total_submissions
    ) VALUES (
      user_record.user_id,
      rank_overall,
      rank_code,
      rank_explanation,
      user_record.avg_overall,
      user_record.avg_code,
      user_record.avg_explanation,
      user_record.total_subs
    );
  END LOOP;
  
  -- Update highest ranks in profiles
  UPDATE public.profiles 
  SET 
    highest_rank_overall = LEAST(COALESCE(highest_rank_overall, 999999), ur.current_rank_overall),
    highest_rank_code = LEAST(COALESCE(highest_rank_code, 999999), ur.current_rank_code),
    highest_rank_explanation = LEAST(COALESCE(highest_rank_explanation, 999999), ur.current_rank_explanation)
  FROM public.user_rankings ur
  WHERE profiles.user_id = ur.user_id;
END;
$$;