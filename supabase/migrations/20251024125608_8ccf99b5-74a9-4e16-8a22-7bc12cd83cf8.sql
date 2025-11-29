-- Fix the calculate_user_rankings function to properly handle DELETE
CREATE OR REPLACE FUNCTION calculate_user_rankings()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Delete old rankings only for users who will get new ones
  DELETE FROM user_rankings 
  WHERE user_id IN (
    SELECT DISTINCT user_id 
    FROM (
      SELECT student_id as user_id FROM assessment_submissions
      UNION
      SELECT student_id as user_id FROM practice_sessions
    ) active_users
  );

  -- Insert updated rankings
  WITH user_scores AS (
    SELECT 
      COALESCE(a.student_id, p.student_id) as user_id,
      COALESCE(AVG(a.overall_score), 0) as avg_assessment_overall,
      COALESCE(AVG(a.code_score), 0) as avg_assessment_code,
      COALESCE(AVG(a.explanation_score), 0) as avg_assessment_explanation,
      COALESCE(AVG(p.overall_score), 0) as avg_practice_overall,
      COALESCE(AVG(p.code_score), 0) as avg_practice_code,
      COALESCE(AVG(p.explanation_score), 0) as avg_practice_explanation,
      COUNT(DISTINCT a.id) as assessment_count,
      COUNT(DISTINCT p.id) as practice_count
    FROM assessment_submissions a
    FULL OUTER JOIN practice_sessions p ON a.student_id = p.student_id
    WHERE (a.status = 'completed' OR p.id IS NOT NULL)
    GROUP BY COALESCE(a.student_id, p.student_id)
    HAVING COUNT(DISTINCT a.id) + COUNT(DISTINCT p.id) >= 3
  ),
  combined_scores AS (
    SELECT 
      user_id,
      (avg_assessment_overall + avg_practice_overall) / 2 as avg_score_overall,
      (avg_assessment_code + avg_practice_code) / 2 as avg_score_code,
      (avg_assessment_explanation + avg_practice_explanation) / 2 as avg_score_explanation,
      assessment_count + practice_count as total_submissions
    FROM user_scores
  ),
  ranked_overall AS (
    SELECT user_id, RANK() OVER (ORDER BY avg_score_overall DESC) as rank
    FROM combined_scores
  ),
  ranked_code AS (
    SELECT user_id, RANK() OVER (ORDER BY avg_score_code DESC) as rank
    FROM combined_scores
  ),
  ranked_explanation AS (
    SELECT user_id, RANK() OVER (ORDER BY avg_score_explanation DESC) as rank
    FROM combined_scores
  )
  INSERT INTO user_rankings (
    user_id,
    avg_score_overall,
    avg_score_code,
    avg_score_explanation,
    current_rank_overall,
    current_rank_code,
    current_rank_explanation,
    total_submissions
  )
  SELECT 
    cs.user_id,
    cs.avg_score_overall,
    cs.avg_score_code,
    cs.avg_score_explanation,
    ro.rank,
    rc.rank,
    re.rank,
    cs.total_submissions
  FROM combined_scores cs
  JOIN ranked_overall ro ON cs.user_id = ro.user_id
  JOIN ranked_code rc ON cs.user_id = rc.user_id
  JOIN ranked_explanation re ON cs.user_id = re.user_id;

  -- Update highest ranks in profiles
  UPDATE profiles p
  SET 
    highest_rank_overall = LEAST(COALESCE(p.highest_rank_overall, ur.current_rank_overall), ur.current_rank_overall),
    highest_rank_code = LEAST(COALESCE(p.highest_rank_code, ur.current_rank_code), ur.current_rank_code),
    highest_rank_explanation = LEAST(COALESCE(p.highest_rank_explanation, ur.current_rank_explanation), ur.current_rank_explanation)
  FROM user_rankings ur
  WHERE p.user_id = ur.user_id;
END;
$$;

-- Add foreign key from user_rankings to profiles
ALTER TABLE user_rankings
ADD CONSTRAINT user_rankings_user_id_fkey 
FOREIGN KEY (user_id) 
REFERENCES profiles(user_id) 
ON DELETE CASCADE;

-- Add foreign key from leaderboard_history to profiles
ALTER TABLE leaderboard_history
ADD CONSTRAINT leaderboard_history_user_id_fkey 
FOREIGN KEY (user_id) 
REFERENCES profiles(user_id) 
ON DELETE CASCADE;