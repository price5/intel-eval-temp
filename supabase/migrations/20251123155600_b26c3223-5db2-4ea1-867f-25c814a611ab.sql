-- 1. Replace award_xp function with league placement logic
CREATE OR REPLACE FUNCTION public.award_xp(
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
  v_week_end DATE;
  v_league_id UUID;
  v_membership_exists BOOLEAN;
BEGIN
  -- Calculate week boundaries
  v_week_start := date_trunc('week', CURRENT_DATE)::DATE + CASE 
    WHEN EXTRACT(DOW FROM date_trunc('week', CURRENT_DATE)::DATE) = 0 THEN 1 
    ELSE 0 
  END;
  v_week_end := v_week_start + INTERVAL '6 days';
  
  -- Apply any active XP boosters
  SELECT COALESCE(SUM(multiplier - 1.0) + 1.0, 1.0)
  INTO v_multiplier
  FROM user_xp_boosters
  WHERE user_id = p_user_id
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > NOW());
  
  v_final_xp := FLOOR(p_base_xp * v_multiplier);
  
  -- Record XP transaction
  INSERT INTO xp_transactions (
    user_id, xp_amount, activity_type, activity_id, multiplier, description
  )
  VALUES (
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
      ) < 27  -- Max 27 users per league
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

-- 2. Update create_weekly_leagues to not auto-place all users
CREATE OR REPLACE FUNCTION public.create_weekly_leagues()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_week_start DATE := date_trunc('week', CURRENT_DATE)::DATE + CASE 
    WHEN EXTRACT(DOW FROM date_trunc('week', CURRENT_DATE)::DATE) = 0 THEN 1 
    ELSE 0 
  END;
  v_week_end DATE := v_week_start + INTERVAL '6 days';
  v_tier TEXT;
  v_users_in_tier UUID[];
  v_league_number INTEGER;
  v_league_id UUID;
  v_chunk_start INTEGER;
  v_chunk_end INTEGER;
BEGIN
  -- Only process promotions from last week if leagues existed
  FOR v_tier IN SELECT unnest(ARRAY['initiate', 'thinker', 'strategist', 'analyst', 'prodigy', 'mastermind'])
  LOOP
    SELECT ARRAY_AGG(lm.user_id ORDER BY lm.week_xp DESC) INTO v_users_in_tier
    FROM league_memberships lm
    JOIN weekly_leagues wl ON lm.league_id = wl.id
    WHERE wl.week_start = v_week_start - INTERVAL '7 days'
      AND wl.tier = v_tier
      AND lm.promotion_status IS NOT NULL
      AND lm.week_xp > 0;  -- Only users who earned XP
    
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
  
  -- Note: New users will be placed in leagues when they earn their first XP via award_xp()
END;
$$;

-- 3. Clean up existing 0 XP memberships
DELETE FROM league_memberships
WHERE week_xp = 0
  AND user_id IN (
    SELECT user_id FROM user_stats WHERE total_xp = 0
  );