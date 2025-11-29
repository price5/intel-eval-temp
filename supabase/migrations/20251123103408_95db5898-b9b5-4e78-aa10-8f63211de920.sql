-- Fix security warnings: Add SET search_path to all functions

CREATE OR REPLACE FUNCTION get_lower_tier(current_tier TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = 'public'
AS $$
BEGIN
  RETURN CASE current_tier
    WHEN 'thinker' THEN 'initiate'
    WHEN 'strategist' THEN 'thinker'
    WHEN 'analyst' THEN 'strategist'
    WHEN 'prodigy' THEN 'analyst'
    WHEN 'mastermind' THEN 'prodigy'
    ELSE NULL
  END;
END;
$$;

CREATE OR REPLACE FUNCTION get_higher_tier(current_tier TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = 'public'
AS $$
BEGIN
  RETURN CASE current_tier
    WHEN 'initiate' THEN 'thinker'
    WHEN 'thinker' THEN 'strategist'
    WHEN 'strategist' THEN 'analyst'
    WHEN 'analyst' THEN 'prodigy'
    WHEN 'prodigy' THEN 'mastermind'
    ELSE NULL
  END;
END;
$$;

CREATE OR REPLACE FUNCTION award_xp(
  p_user_id UUID,
  p_activity_type TEXT,
  p_activity_id UUID,
  p_base_xp INTEGER,
  p_description TEXT DEFAULT NULL
) 
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_multiplier NUMERIC := 1.0;
  v_final_xp INTEGER;
  v_week_start DATE;
BEGIN
  v_week_start := date_trunc('week', NOW())::DATE;
  
  SELECT COALESCE(SUM(multiplier - 1.0) + 1.0, 1.0) INTO v_multiplier
  FROM user_xp_boosters
  WHERE user_id = p_user_id
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > NOW());
  
  v_final_xp := FLOOR(p_base_xp * v_multiplier);
  
  INSERT INTO xp_transactions (
    user_id, xp_amount, activity_type, activity_id, multiplier, description
  ) VALUES (
    p_user_id, v_final_xp, p_activity_type, p_activity_id, v_multiplier, p_description
  );
  
  UPDATE user_stats
  SET 
    current_xp = current_xp + v_final_xp,
    total_xp = total_xp + v_final_xp,
    updated_at = NOW()
  WHERE user_id = p_user_id;
  
  UPDATE league_memberships
  SET 
    week_xp = week_xp + v_final_xp,
    updated_at = NOW()
  WHERE user_id = p_user_id
    AND week_start = v_week_start;
  
  RETURN v_final_xp;
END;
$$;

CREATE OR REPLACE FUNCTION create_weekly_leagues() 
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_week_start DATE := date_trunc('week', NOW())::DATE;
  v_week_end DATE := v_week_start + INTERVAL '6 days';
  v_tier TEXT;
  v_users_in_tier UUID[];
  v_league_number INTEGER;
  v_league_id UUID;
  v_chunk_start INTEGER;
  v_chunk_end INTEGER;
  v_all_users UUID[];
BEGIN
  SELECT ARRAY_AGG(user_id) INTO v_all_users
  FROM profiles
  WHERE user_id NOT IN (
    SELECT user_id FROM league_memberships WHERE week_start = v_week_start
  );
  
  IF v_all_users IS NULL OR ARRAY_LENGTH(v_all_users, 1) = 0 THEN
    FOR v_tier IN SELECT unnest(ARRAY['initiate', 'thinker', 'strategist', 'analyst', 'prodigy', 'mastermind'])
    LOOP
      SELECT ARRAY_AGG(lm.user_id ORDER BY lm.week_xp DESC) INTO v_users_in_tier
      FROM league_memberships lm
      JOIN weekly_leagues wl ON lm.league_id = wl.id
      WHERE wl.week_start = v_week_start - INTERVAL '7 days'
        AND wl.tier = v_tier
        AND lm.promotion_status IS NOT NULL;
      
      IF v_users_in_tier IS NOT NULL AND ARRAY_LENGTH(v_users_in_tier, 1) > 0 THEN
        v_league_number := 1;
        FOR i IN 1..CEIL(ARRAY_LENGTH(v_users_in_tier, 1)::NUMERIC / 27.0) LOOP
          v_chunk_start := (i-1)*27+1;
          v_chunk_end := LEAST(i*27, ARRAY_LENGTH(v_users_in_tier, 1));
          
          INSERT INTO weekly_leagues (week_start, week_end, tier, league_number, is_active)
          VALUES (v_week_start, v_week_end, v_tier, v_league_number, true)
          RETURNING id INTO v_league_id;
          
          INSERT INTO league_memberships (user_id, league_id, week_start, starting_xp, week_xp, promotion_status)
          SELECT 
            uid,
            v_league_id,
            v_week_start,
            COALESCE((SELECT total_xp FROM user_stats WHERE user_stats.user_id = uid), 0),
            0,
            'pending'
          FROM unnest(v_users_in_tier[v_chunk_start:v_chunk_end]) AS uid;
          
          v_league_number := v_league_number + 1;
        END LOOP;
      END IF;
    END LOOP;
  ELSE
    v_league_number := 1;
    FOR i IN 1..CEIL(ARRAY_LENGTH(v_all_users, 1)::NUMERIC / 27.0) LOOP
      v_chunk_start := (i-1)*27+1;
      v_chunk_end := LEAST(i*27, ARRAY_LENGTH(v_all_users, 1));
      
      INSERT INTO weekly_leagues (week_start, week_end, tier, league_number, is_active)
      VALUES (v_week_start, v_week_end, 'initiate', v_league_number, true)
      RETURNING id INTO v_league_id;
      
      INSERT INTO league_memberships (user_id, league_id, week_start, starting_xp, week_xp, promotion_status)
      SELECT 
        uid,
        v_league_id,
        v_week_start,
        COALESCE((SELECT total_xp FROM user_stats WHERE user_stats.user_id = uid), 0),
        0,
        'pending'
      FROM unnest(v_all_users[v_chunk_start:v_chunk_end]) AS uid;
      
      v_league_number := v_league_number + 1;
    END LOOP;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION process_weekly_promotions() 
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_last_week_start DATE := date_trunc('week', NOW() - INTERVAL '7 days')::DATE;
  v_league RECORD;
  v_ranked_users RECORD;
  v_total_users INTEGER;
  v_rank_position INTEGER;
  v_promotion_threshold INTEGER;
  v_demotion_threshold INTEGER;
BEGIN
  FOR v_league IN 
    SELECT id, tier FROM weekly_leagues 
    WHERE week_start = v_last_week_start AND is_active = true
  LOOP
    SELECT COUNT(*) INTO v_total_users
    FROM league_memberships
    WHERE league_id = v_league.id;
    
    v_promotion_threshold := LEAST(5, GREATEST(1, FLOOR(v_total_users * 0.2)));
    v_demotion_threshold := v_total_users - LEAST(5, GREATEST(1, FLOOR(v_total_users * 0.2)));
    
    v_rank_position := 1;
    FOR v_ranked_users IN
      SELECT user_id, week_xp
      FROM league_memberships
      WHERE league_id = v_league.id
      ORDER BY week_xp DESC, created_at ASC
    LOOP
      UPDATE league_memberships
      SET 
        final_rank = v_rank_position,
        promotion_status = CASE
          WHEN v_rank_position <= v_promotion_threshold AND v_league.tier != 'mastermind' THEN 'promoted'
          WHEN v_rank_position > v_demotion_threshold AND v_league.tier != 'initiate' THEN 'demoted'
          ELSE 'stayed'
        END,
        updated_at = NOW()
      WHERE user_id = v_ranked_users.user_id
        AND league_id = v_league.id;
      
      v_rank_position := v_rank_position + 1;
    END LOOP;
  END LOOP;
  
  UPDATE weekly_leagues
  SET is_active = false
  WHERE week_start = v_last_week_start;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_xp_for_practice() 
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_base_xp INTEGER;
  v_problem_difficulty TEXT;
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    SELECT difficulty INTO v_problem_difficulty
    FROM practice_problems
    WHERE id = NEW.problem_id;
    
    v_base_xp := CASE v_problem_difficulty
      WHEN 'easy' THEN 30
      WHEN 'medium' THEN 50
      WHEN 'hard' THEN 80
      ELSE 40
    END;
    
    PERFORM award_xp(
      NEW.student_id,
      'practice_problem',
      NEW.id,
      v_base_xp,
      'Completed ' || v_problem_difficulty || ' practice problem'
    );
    
    IF NEW.explanation_score >= 80 THEN
      PERFORM award_xp(
        NEW.student_id,
        'clean_explanation',
        NEW.id,
        15,
        'Clean explanation bonus'
      );
    END IF;
    
    IF NEW.overall_score = 100 THEN
      PERFORM award_xp(
        NEW.student_id,
        'perfect_score',
        NEW.id,
        50,
        'Perfect score bonus'
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_xp_for_assessment() 
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_base_xp INTEGER := 100;
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    PERFORM award_xp(
      NEW.student_id,
      'assessment',
      NEW.id,
      v_base_xp,
      'Completed assessment'
    );
    
    IF NEW.explanation_score >= 80 THEN
      PERFORM award_xp(
        NEW.student_id,
        'clean_explanation',
        NEW.id,
        15,
        'Clean explanation bonus'
      );
    END IF;
    
    IF NEW.overall_score = 100 THEN
      PERFORM award_xp(
        NEW.student_id,
        'perfect_score',
        NEW.id,
        50,
        'Perfect score bonus'
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION check_streak_booster() 
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  IF NEW.streak_count = 7 AND (OLD.streak_count IS NULL OR OLD.streak_count < 7) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_7day', 1.10, NOW() + INTERVAL '24 hours')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      NULL,
      50,
      '7-day streak bonus! +10% XP boost for 24h'
    );
  END IF;
  
  RETURN NEW;
END;
$$;