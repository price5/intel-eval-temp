-- Fix user_stats and achievement tracking

-- 1. Ensure all users have a user_stats row and populate with current data
INSERT INTO user_stats (user_id, submissions_count, perfect_scores, first_try_success)
SELECT 
  p.user_id,
  COALESCE(
    (SELECT COUNT(*) FROM assessment_submissions WHERE student_id = p.user_id) +
    (SELECT COUNT(*) FROM practice_sessions WHERE student_id = p.user_id),
    0
  ) as submissions_count,
  COALESCE(
    (SELECT COUNT(*) FROM assessment_submissions WHERE student_id = p.user_id AND overall_score = 100) +
    (SELECT COUNT(*) FROM practice_sessions WHERE student_id = p.user_id AND overall_score = 100),
    0
  ) as perfect_scores,
  0 as first_try_success
FROM profiles p
ON CONFLICT (user_id) 
DO UPDATE SET 
  submissions_count = EXCLUDED.submissions_count,
  perfect_scores = EXCLUDED.perfect_scores,
  updated_at = now();

-- 2. Create function to update user_stats when assessment is submitted
CREATE OR REPLACE FUNCTION update_user_stats_on_assessment()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3. Create function to update user_stats when practice session is submitted
CREATE OR REPLACE FUNCTION update_user_stats_on_practice()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 4. Create triggers for both assessment submissions and practice sessions
DROP TRIGGER IF EXISTS trigger_update_stats_on_assessment ON assessment_submissions;
CREATE TRIGGER trigger_update_stats_on_assessment
  AFTER INSERT ON assessment_submissions
  FOR EACH ROW
  EXECUTE FUNCTION update_user_stats_on_assessment();

DROP TRIGGER IF EXISTS trigger_update_stats_on_practice ON practice_sessions;
CREATE TRIGGER trigger_update_stats_on_practice
  AFTER INSERT ON practice_sessions
  FOR EACH ROW
  EXECUTE FUNCTION update_user_stats_on_practice();

-- 5. Run achievement evaluation for all users who now have updated stats
DO $$
DECLARE
  user_record RECORD;
BEGIN
  FOR user_record IN SELECT user_id FROM user_stats WHERE submissions_count > 0
  LOOP
    PERFORM evaluate_and_award_achievements(user_record.user_id);
  END LOOP;
END $$;