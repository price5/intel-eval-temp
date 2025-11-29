-- Fix security warnings by setting search_path for functions

-- Drop and recreate initialize_user_stats with proper security settings
DROP TRIGGER IF EXISTS on_profile_created_init_stats ON public.profiles;
DROP FUNCTION IF EXISTS public.initialize_user_stats();

CREATE OR REPLACE FUNCTION public.initialize_user_stats()
RETURNS TRIGGER 
LANGUAGE plpgsql 
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_stats (user_id)
  VALUES (NEW.user_id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_profile_created_init_stats
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.initialize_user_stats();

-- Drop and recreate check_and_award_achievements with proper security settings
DROP FUNCTION IF EXISTS public.check_and_award_achievements(UUID);

CREATE OR REPLACE FUNCTION public.check_and_award_achievements(user_id_param UUID)
RETURNS void 
LANGUAGE plpgsql 
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;
