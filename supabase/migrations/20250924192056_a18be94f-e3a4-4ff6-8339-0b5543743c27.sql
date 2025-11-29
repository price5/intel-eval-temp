-- Remove current_badge_tier and add achievement_role to profiles
ALTER TABLE profiles DROP COLUMN IF EXISTS current_badge_tier;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS achievement_role TEXT DEFAULT 'Initiate';

-- Create user_achievement_roles table to track all earned roles
CREATE TABLE IF NOT EXISTS user_achievement_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(user_id) ON DELETE CASCADE,
  role_name TEXT NOT NULL,
  role_category TEXT NOT NULL,
  unlocked_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_id, role_name)
);

-- Create achievement_role_definitions table
CREATE TABLE IF NOT EXISTS achievement_role_definitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL,
  emoji TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL,
  criteria JSONB NOT NULL,
  tier_level INTEGER,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS on new tables
ALTER TABLE user_achievement_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE achievement_role_definitions ENABLE ROW LEVEL SECURITY;

-- RLS policies for user_achievement_roles
CREATE POLICY "Users can view all achievement roles" ON user_achievement_roles FOR SELECT USING (true);
CREATE POLICY "System can manage user achievement roles" ON user_achievement_roles FOR ALL USING (auth.uid() IS NOT NULL);

-- RLS policies for achievement_role_definitions
CREATE POLICY "Everyone can view role definitions" ON achievement_role_definitions FOR SELECT USING (true);

-- Insert role definitions
INSERT INTO achievement_role_definitions (name, emoji, description, category, criteria, tier_level) VALUES
-- Progression Roles
('Initiate', '🆕', 'Taking first steps in coding', 'progression', '{"min_submissions": 0, "max_submissions": 10}', 1),
('Debugger', '🐛', 'Learning from mistakes', 'progression', '{"fixed_failures": 5}', 2),
('Algorithm Adept', '🔧', 'Strong technical implementation', 'progression', '{"min_avg_code_score": 70}', 3),
('Logic Crafter', '🧠', 'Balanced problem solver', 'progression', '{"min_avg_overall_score": 75}', 4),
('Insight Scholar', '💡', 'Thoughtful programmer', 'progression', '{"min_avg_code_score": 80, "min_avg_explanation_score": 80}', 5),
('Architect of Thought', '🏗️', 'Advanced reasoning skills', 'progression', '{"top_percentile": 10}', 6),
('Grand Evaluator', '👑', 'Elite problem solver', 'progression', '{"top_percentile": 3}', 7),

-- Code Achievement Roles
('Bug Slayer', '🐞', 'Perfect solution on first try', 'code', '{"perfect_first_attempts": 3}', null),
('Efficiency Guru', '⚡', 'Optimal complexity solutions', 'code', '{"optimal_solutions": 5}', null),
('One-Liner Wizard', '🧙', 'Shortest working code master', 'code', '{"shortest_solutions": 3}', null),

-- Explanation Achievement Roles
('Clarity Champion', '🏆', 'Perfect explanation scores', 'explanation', '{"perfect_explanation_scores": 5}', null),
('Concept Weaver', '🕸️', 'Consistently detailed reasoning', 'explanation', '{"detailed_explanations": 10}', null),
('Teacher''s Voice', '👨‍🏫', 'Top explanations favorited by instructors', 'explanation', '{"instructor_favorites": 5}', null),

-- Balanced/Unique Achievement Roles
('Fusionist', '⚖️', 'Equal high scores in code + explanation', 'balanced', '{"equal_high_scores": 5}', null),
('Comeback Kid', '🔄', 'Improved dramatically over time', 'balanced', '{"score_improvement": 30}', null),
('Streak Holder', '🔥', 'Daily submissions for extended period', 'balanced', '{"daily_streak": 30}', null),
('Hall of Fame', '👑', 'Monthly leaderboard champion', 'balanced', '{"leaderboard_wins": 1}', null)
ON CONFLICT (name) DO NOTHING;

-- Create function to calculate and update user roles
CREATE OR REPLACE FUNCTION calculate_user_achievement_role(user_id_param UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  user_stats RECORD;
  highest_role TEXT := 'Initiate';
  highest_tier INTEGER := 0;
BEGIN
  -- Get user statistics
  SELECT 
    COUNT(*) as total_submissions,
    COALESCE(AVG(ps.overall_score), 0) + COALESCE(AVG(asub.overall_score), 0) as avg_overall,
    COALESCE(AVG(ps.code_score), 0) + COALESCE(AVG(asub.code_score), 0) as avg_code,
    COALESCE(AVG(ps.explanation_score), 0) + COALESCE(AVG(asub.explanation_score), 0) as avg_explanation
  INTO user_stats
  FROM profiles p
  LEFT JOIN practice_sessions ps ON p.user_id = ps.student_id
  LEFT JOIN assessment_submissions asub ON p.user_id = asub.student_id
  WHERE p.user_id = user_id_param
  GROUP BY p.user_id;
  
  -- Check progression roles (highest tier wins)
  IF user_stats.avg_overall >= 75 AND user_stats.avg_code >= 80 AND user_stats.avg_explanation >= 80 THEN
    highest_role := 'Insight Scholar';
    highest_tier := 5;
  ELSIF user_stats.avg_overall >= 75 THEN
    highest_role := 'Logic Crafter';
    highest_tier := 4;
  ELSIF user_stats.avg_code >= 70 THEN
    highest_role := 'Algorithm Adept';
    highest_tier := 3;
  ELSIF user_stats.total_submissions >= 5 THEN
    highest_role := 'Debugger';
    highest_tier := 2;
  ELSE
    highest_role := 'Initiate';
    highest_tier := 1;
  END IF;
  
  -- Update user's achievement role
  UPDATE profiles 
  SET achievement_role = highest_role, updated_at = NOW()
  WHERE profiles.user_id = user_id_param;
  
  -- Insert into user_achievement_roles if not already exists
  INSERT INTO user_achievement_roles (user_id, role_name, role_category)
  VALUES (user_id_param, highest_role, 'progression')
  ON CONFLICT (user_id, role_name) DO NOTHING;
  
  RETURN highest_role;
END;
$$;