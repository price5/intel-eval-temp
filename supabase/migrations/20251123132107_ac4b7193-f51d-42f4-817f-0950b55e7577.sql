-- Update award_xp function to automatically place users in leagues when they gain XP
CREATE OR REPLACE FUNCTION public.award_xp(
  p_user_id UUID,
  p_base_xp INTEGER,
  p_activity_type TEXT,
  p_activity_id UUID DEFAULT NULL,
  p_description TEXT DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_multiplier NUMERIC := 1.0;
  v_final_xp INTEGER;
  v_week_start DATE;
  v_week_end DATE;
  v_league_id UUID;
  v_membership_exists BOOLEAN;
BEGIN
  v_week_start := date_trunc('week', CURRENT_DATE)::DATE + CASE 
    WHEN EXTRACT(DOW FROM date_trunc('week', CURRENT_DATE)::DATE) = 0 THEN 1 
    ELSE 0 
  END;
  v_week_end := v_week_start + INTERVAL '6 days';
  
  -- Check for active XP boosters
  SELECT COALESCE(SUM(multiplier - 1.0) + 1.0, 1.0) INTO v_multiplier
  FROM user_xp_boosters
  WHERE user_id = p_user_id
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > NOW());
  
  v_final_xp := FLOOR(p_base_xp * v_multiplier);
  
  -- Record XP transaction
  INSERT INTO xp_transactions (
    user_id, xp_amount, activity_type, activity_id, multiplier, description
  ) VALUES (
    p_user_id, v_final_xp, p_activity_type, p_activity_id, v_multiplier, p_description
  );
  
  -- Update user stats
  UPDATE user_stats
  SET 
    current_xp = current_xp + v_final_xp,
    total_xp = total_xp + v_final_xp,
    updated_at = NOW()
  WHERE user_id = p_user_id;
  
  -- Check if user has a league membership for this week
  SELECT EXISTS (
    SELECT 1 FROM league_memberships
    WHERE user_id = p_user_id AND week_start = v_week_start
  ) INTO v_membership_exists;
  
  -- If no membership exists, place user in initiate league
  IF NOT v_membership_exists THEN
    -- Find or create an active initiate league for this week
    SELECT id INTO v_league_id
    FROM weekly_leagues
    WHERE tier = 'initiate'
      AND week_start = v_week_start
      AND is_active = true
      AND (
        SELECT COUNT(*) FROM league_memberships 
        WHERE league_id = weekly_leagues.id
      ) < 20  -- Max 20 users per league
    ORDER BY league_number
    LIMIT 1;
    
    -- If no suitable league found, create a new one
    IF v_league_id IS NULL THEN
      INSERT INTO weekly_leagues (tier, league_number, week_start, week_end, is_active)
      VALUES (
        'initiate',
        COALESCE((
          SELECT MAX(league_number) + 1 
          FROM weekly_leagues 
          WHERE tier = 'initiate' AND week_start = v_week_start
        ), 1),
        v_week_start,
        v_week_end,
        true
      )
      RETURNING id INTO v_league_id;
    END IF;
    
    -- Create league membership with starting XP
    INSERT INTO league_memberships (
      user_id, league_id, week_start, week_xp, starting_xp
    )
    SELECT 
      p_user_id, 
      v_league_id, 
      v_week_start, 
      v_final_xp,
      COALESCE(total_xp, 0) - v_final_xp
    FROM user_stats
    WHERE user_id = p_user_id;
  ELSE
    -- Update existing league membership
    UPDATE league_memberships
    SET 
      week_xp = week_xp + v_final_xp,
      updated_at = NOW()
    WHERE user_id = p_user_id
      AND week_start = v_week_start;
  END IF;
  
  RETURN v_final_xp;
END;
$$;