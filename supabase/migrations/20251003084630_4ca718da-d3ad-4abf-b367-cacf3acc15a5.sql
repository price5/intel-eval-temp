-- Create achievements table
CREATE TABLE IF NOT EXISTS public.achievements (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('consistency', 'quality', 'growth', 'community', 'special')),
  tier TEXT NOT NULL CHECK (tier IN ('bronze', 'silver', 'gold', 'platinum')),
  icon TEXT NOT NULL,
  criteria JSONB NOT NULL,
  points INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create user_achievements table (tracks which achievements users have earned)
CREATE TABLE IF NOT EXISTS public.user_achievements (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  achievement_id UUID NOT NULL REFERENCES public.achievements(id) ON DELETE CASCADE,
  earned_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  progress INTEGER DEFAULT 0,
  progress_max INTEGER DEFAULT 1,
  UNIQUE(user_id, achievement_id)
);

-- Create user_stats table (for tracking XP and levels)
CREATE TABLE IF NOT EXISTS public.user_stats (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  level INTEGER NOT NULL DEFAULT 1,
  current_xp INTEGER NOT NULL DEFAULT 0,
  total_xp INTEGER NOT NULL DEFAULT 0,
  submissions_count INTEGER NOT NULL DEFAULT 0,
  perfect_scores INTEGER NOT NULL DEFAULT 0,
  first_try_success INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_stats ENABLE ROW LEVEL SECURITY;

-- RLS Policies for achievements (public read)
CREATE POLICY "Anyone can view achievements"
  ON public.achievements FOR SELECT
  USING (true);

-- RLS Policies for user_achievements
CREATE POLICY "Users can view their own achievements"
  ON public.user_achievements FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own achievements"
  ON public.user_achievements FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own achievements"
  ON public.user_achievements FOR UPDATE
  USING (auth.uid() = user_id);

-- RLS Policies for user_stats
CREATE POLICY "Users can view their own stats"
  ON public.user_stats FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own stats"
  ON public.user_stats FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own stats"
  ON public.user_stats FOR UPDATE
  USING (auth.uid() = user_id);

-- Create function to initialize user stats
CREATE OR REPLACE FUNCTION public.initialize_user_stats()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.user_stats (user_id)
  VALUES (NEW.user_id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger to initialize stats when profile is created
CREATE TRIGGER on_profile_created_init_stats
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.initialize_user_stats();

-- Insert default achievements
INSERT INTO public.achievements (name, description, category, tier, icon, criteria, points) VALUES
-- Consistency Achievements
('First Steps', 'Complete your first assessment', 'consistency', 'bronze', '🎯', '{"type": "submissions_count", "value": 1}', 10),
('Getting Started', 'Complete 5 assessments', 'consistency', 'silver', '🚀', '{"type": "submissions_count", "value": 5}', 25),
('Dedicated Learner', 'Complete 25 assessments', 'consistency', 'gold', '📚', '{"type": "submissions_count", "value": 25}', 50),
('Assessment Master', 'Complete 100 assessments', 'consistency', 'platinum', '👑', '{"type": "submissions_count", "value": 100}', 200),
('Fire Starter', 'Maintain a 3-day streak', 'consistency', 'bronze', '🔥', '{"type": "streak", "value": 3}', 15),
('Flame Keeper', 'Maintain a 7-day streak', 'consistency', 'silver', '🔥', '{"type": "streak", "value": 7}', 30),
('Inferno Builder', 'Maintain a 30-day streak', 'consistency', 'gold', '🔥', '{"type": "streak", "value": 30}', 100),
('Eternal Flame', 'Maintain a 100-day streak', 'consistency', 'platinum', '🔥', '{"type": "streak", "value": 100}', 500),

-- Quality Achievements
('Code Craftsman', 'Score 90+ on code in 5 assessments', 'quality', 'bronze', '⚡', '{"type": "high_code_scores", "threshold": 90, "count": 5}', 20),
('Logic Legend', 'Score 95+ on code in 10 assessments', 'quality', 'silver', '🧠', '{"type": "high_code_scores", "threshold": 95, "count": 10}', 40),
('Perfect Programmer', 'Score 100 on code in any assessment', 'quality', 'gold', '💎', '{"type": "perfect_code_score", "value": 1}', 75),
('Code Perfectionist', 'Score 100 on code in 5 assessments', 'quality', 'platinum', '💎', '{"type": "perfect_code_score", "value": 5}', 250),
('Clear Communicator', 'Score 90+ on explanation in 5 assessments', 'quality', 'bronze', '💬', '{"type": "high_explanation_scores", "threshold": 90, "count": 5}', 20),
('Master Explainer', 'Score 95+ on explanation in 10 assessments', 'quality', 'silver', '🎓', '{"type": "high_explanation_scores", "threshold": 95, "count": 10}', 40),
('First Try Success', 'Get 90+ overall score on first attempt', 'quality', 'gold', '🎯', '{"type": "first_try_success", "value": 1}', 50),

-- Growth Achievements
('Fast Learner', 'Improve your average score by 10 points', 'growth', 'bronze', '📈', '{"type": "score_improvement", "value": 10}', 25),
('Rising Star', 'Improve your average score by 25 points', 'growth', 'silver', '⭐', '{"type": "score_improvement", "value": 25}', 50),
('Transformation', 'Go from below 50 to above 80 average', 'growth', 'gold', '🦋', '{"type": "major_improvement", "from": 50, "to": 80}', 100),
('Problem Explorer', 'Attempt 10 different problem types', 'growth', 'silver', '🗺️', '{"type": "problem_variety", "value": 10}', 30),
('Renaissance Coder', 'Score 80+ in all problem categories', 'growth', 'platinum', '🎨', '{"type": "category_mastery", "threshold": 80}', 200),

-- Community Achievements
('Team Player', 'Participate in 5 class assessments', 'community', 'bronze', '🤝', '{"type": "class_participation", "value": 5}', 15),
('Class Leader', 'Rank in top 10 of your class', 'community', 'silver', '🏆', '{"type": "class_rank", "value": 10}', 50),
('Campus Champion', 'Rank in top 5 of your college', 'community', 'gold', '👑', '{"type": "college_rank", "value": 5}', 100),
('Global Elite', 'Rank in top 100 globally', 'community', 'platinum', '🌟', '{"type": "global_rank", "value": 100}', 300),

-- Special Achievements
('Night Owl', 'Complete assessment between 12 AM - 4 AM', 'special', 'bronze', '🦉', '{"type": "time_based", "hours": [0, 1, 2, 3]}', 10),
('Early Bird', 'Complete assessment between 5 AM - 7 AM', 'special', 'bronze', '🌅', '{"type": "time_based", "hours": [5, 6]}', 10),
('Weekend Warrior', 'Complete 10 assessments on weekends', 'special', 'silver', '⚔️', '{"type": "weekend_completions", "value": 10}', 30),
('Never Give Up', 'Complete assessment after 5+ attempts', 'special', 'gold', '💪', '{"type": "perseverance", "attempts": 5}', 50),
('Speed Demon', 'Complete assessment in under 5 minutes with 90+ score', 'special', 'platinum', '⚡', '{"type": "speed_quality", "time": 300, "score": 90}', 150),
('Comeback King', 'Improve from 50 to 90+ on retry', 'special', 'gold', '👑', '{"type": "comeback", "from": 50, "to": 90}', 75);

-- Create function to check and award achievements
CREATE OR REPLACE FUNCTION public.check_and_award_achievements(user_id_param UUID)
RETURNS void AS $$
DECLARE
  user_submissions_count INTEGER;
  user_streak INTEGER;
BEGIN
  -- Get user's current stats
  SELECT 
    COALESCE(submissions_count, 0),
    COALESCE((SELECT streak_count FROM profiles WHERE user_id = user_id_param), 0)
  INTO user_submissions_count, user_streak
  FROM user_stats
  WHERE user_id = user_id_param;

  -- Check submission count achievements
  INSERT INTO user_achievements (user_id, achievement_id, progress, progress_max)
  SELECT 
    user_id_param,
    a.id,
    user_submissions_count,
    (a.criteria->>'value')::INTEGER
  FROM achievements a
  WHERE a.criteria->>'type' = 'submissions_count'
    AND user_submissions_count >= (a.criteria->>'value')::INTEGER
    AND NOT EXISTS (
      SELECT 1 FROM user_achievements ua 
      WHERE ua.user_id = user_id_param AND ua.achievement_id = a.id
    )
  ON CONFLICT (user_id, achievement_id) DO NOTHING;

  -- Check streak achievements
  INSERT INTO user_achievements (user_id, achievement_id, progress, progress_max)
  SELECT 
    user_id_param,
    a.id,
    user_streak,
    (a.criteria->>'value')::INTEGER
  FROM achievements a
  WHERE a.criteria->>'type' = 'streak'
    AND user_streak >= (a.criteria->>'value')::INTEGER
    AND NOT EXISTS (
      SELECT 1 FROM user_achievements ua 
      WHERE ua.user_id = user_id_param AND ua.achievement_id = a.id
    )
  ON CONFLICT (user_id, achievement_id) DO NOTHING;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
