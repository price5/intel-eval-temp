-- Drop existing functions to recreate them
DROP FUNCTION IF EXISTS get_current_league_week_boundaries();
DROP FUNCTION IF EXISTS award_xp(uuid, integer, text, uuid, text);
DROP FUNCTION IF EXISTS process_weekly_promotions();
DROP FUNCTION IF EXISTS create_weekly_leagues();

-- Create helper function to get consistent week boundaries (Sunday 2pm IST = Sunday 08:30 UTC)
CREATE OR REPLACE FUNCTION get_current_league_week_boundaries()
RETURNS TABLE(week_start TIMESTAMPTZ, week_end TIMESTAMPTZ) AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_current_week_start TIMESTAMPTZ;
BEGIN
  -- Calculate the most recent Sunday at 08:30 UTC (2pm IST)
  v_current_week_start := date_trunc('week', v_now) + INTERVAL '08:30:00';
  
  -- If we're before Sunday 08:30 UTC, go back one week
  IF v_now < v_current_week_start THEN
    v_current_week_start := v_current_week_start - INTERVAL '7 days';
  END IF;
  
  RETURN QUERY SELECT 
    v_current_week_start,
    v_current_week_start + INTERVAL '7 days' - INTERVAL '1 second';
END;
$$ LANGUAGE plpgsql STABLE;

-- Rewrite award_xp to use new week boundaries and backfill logic
CREATE OR REPLACE FUNCTION award_xp(
  p_user_id UUID,
  p_base_xp INTEGER,
  p_activity_type TEXT,
  p_activity_id UUID DEFAULT NULL,
  p_description TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
  v_multiplier NUMERIC := 1.0;
  v_final_xp INTEGER;
  v_week_start TIMESTAMPTZ;
  v_week_end TIMESTAMPTZ;
  v_league_id UUID;
  v_membership_exists BOOLEAN;
  v_backfill_xp INTEGER := 0;
BEGIN
  -- Get current week boundaries
  SELECT * INTO v_week_start, v_week_end FROM get_current_league_week_boundaries();
  
  -- Apply any active XP boosters
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
    WHERE user_id = p_user_id 
      AND week_start = v_week_start::DATE
  ) INTO v_membership_exists;
  
  -- If no membership exists, place user in initiate league and backfill XP
  IF NOT v_membership_exists THEN
    -- Calculate backfill XP (all XP earned since week_start)
    SELECT COALESCE(SUM(xp_amount), 0) INTO v_backfill_xp
    FROM xp_transactions
    WHERE user_id = p_user_id
      AND created_at >= v_week_start
      AND created_at <= v_week_end;
    
    -- Find or create an active initiate league for this week with < 20 users
    SELECT id INTO v_league_id
    FROM weekly_leagues
    WHERE tier = 'initiate'
      AND week_start = v_week_start::DATE
      AND is_active = true
      AND (
        SELECT COUNT(*) FROM league_memberships 
        WHERE league_id = weekly_leagues.id
      ) < 20
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
          WHERE tier = 'initiate' AND week_start = v_week_start::DATE
        ), 1),
        v_week_start::DATE,
        v_week_end::DATE,
        true
      )
      RETURNING id INTO v_league_id;
    END IF;
    
    -- Create league membership with backfilled XP
    INSERT INTO league_memberships (
      user_id, league_id, week_start, week_xp, starting_xp
    )
    SELECT 
      p_user_id, 
      v_league_id, 
      v_week_start::DATE, 
      v_backfill_xp,
      COALESCE(total_xp, 0) - v_backfill_xp
    FROM user_stats
    WHERE user_id = p_user_id;
  ELSE
    -- Update existing league membership
    UPDATE league_memberships
    SET 
      week_xp = week_xp + v_final_xp,
      updated_at = NOW()
    WHERE user_id = p_user_id
      AND week_start = v_week_start::DATE;
  END IF;
  
  RETURN v_final_xp;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Rewrite process_weekly_promotions to calculate final ranks
CREATE OR REPLACE FUNCTION process_weekly_promotions()
RETURNS VOID AS $$
DECLARE
  v_week_boundaries RECORD;
  v_last_week_start DATE;
  v_league RECORD;
  v_ranked_users RECORD;
  v_total_users INTEGER;
  v_rank_position INTEGER;
  v_promotion_threshold INTEGER;
  v_demotion_threshold INTEGER;
BEGIN
  -- Get last week's boundaries
  SELECT * INTO v_week_boundaries FROM get_current_league_week_boundaries();
  v_last_week_start := (v_week_boundaries.week_start - INTERVAL '7 days')::DATE;
  
  -- Process each active league from last week
  FOR v_league IN 
    SELECT id, tier FROM weekly_leagues 
    WHERE week_start = v_last_week_start AND is_active = true
  LOOP
    SELECT COUNT(*) INTO v_total_users
    FROM league_memberships
    WHERE league_id = v_league.id;
    
    -- Calculate promotion/demotion thresholds (top 25%, bottom 25%)
    v_promotion_threshold := GREATEST(1, FLOOR(v_total_users * 0.25));
    v_demotion_threshold := v_total_users - GREATEST(1, FLOOR(v_total_users * 0.25));
    
    -- Rank users and update promotion status
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
  
  -- Mark all last week's leagues as inactive
  UPDATE weekly_leagues
  SET is_active = false
  WHERE week_start = v_last_week_start;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Rewrite create_weekly_leagues with Option A: Rebalance ALL users
CREATE OR REPLACE FUNCTION create_weekly_leagues()
RETURNS VOID AS $$
DECLARE
  v_week_boundaries RECORD;
  v_week_start DATE;
  v_week_end DATE;
  v_last_week_start DATE;
  v_tier TEXT;
  v_users_in_tier UUID[];
  v_league_number INTEGER;
  v_league_id UUID;
  v_chunk_start INTEGER;
  v_chunk_end INTEGER;
  v_total_users INTEGER;
BEGIN
  -- Get current week boundaries
  SELECT * INTO v_week_boundaries FROM get_current_league_week_boundaries();
  v_week_start := v_week_boundaries.week_start::DATE;
  v_week_end := v_week_boundaries.week_end::DATE;
  v_last_week_start := (v_week_boundaries.week_start - INTERVAL '7 days')::DATE;
  
  -- Process each tier
  FOR v_tier IN SELECT unnest(ARRAY['initiate', 'thinker', 'strategist', 'analyst', 'prodigy', 'mastermind'])
  LOOP
    -- Collect ALL users for this tier (promoted, demoted, stayed)
    -- For Initiate tier, include new users + demoted users
    IF v_tier = 'initiate' THEN
      SELECT ARRAY_AGG(user_id ORDER BY final_rank NULLS LAST, week_xp DESC) INTO v_users_in_tier
      FROM (
        -- Demoted users from Thinker tier
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = 'thinker'
          AND lm.promotion_status = 'demoted'
        
        UNION ALL
        
        -- Users who stayed in Initiate tier
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = 'initiate'
          AND lm.promotion_status = 'stayed'
      ) all_users;
    
    -- For Mastermind tier, include promoted + stayed users
    ELSIF v_tier = 'mastermind' THEN
      SELECT ARRAY_AGG(user_id ORDER BY final_rank NULLS LAST, week_xp DESC) INTO v_users_in_tier
      FROM (
        -- Promoted users from Prodigy tier
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = 'prodigy'
          AND lm.promotion_status = 'promoted'
        
        UNION ALL
        
        -- Users who stayed in Mastermind tier
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = 'mastermind'
          AND lm.promotion_status = 'stayed'
      ) all_users;
    
    -- For middle tiers, include promoted + demoted + stayed users
    ELSE
      SELECT ARRAY_AGG(user_id ORDER BY final_rank NULLS LAST, week_xp DESC) INTO v_users_in_tier
      FROM (
        -- Promoted users from tier below
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = get_lower_tier(v_tier)
          AND lm.promotion_status = 'promoted'
        
        UNION ALL
        
        -- Demoted users from tier above
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = get_higher_tier(v_tier)
          AND lm.promotion_status = 'demoted'
        
        UNION ALL
        
        -- Users who stayed in current tier
        SELECT lm.user_id, lm.final_rank, lm.week_xp
        FROM league_memberships lm
        JOIN weekly_leagues wl ON lm.league_id = wl.id
        WHERE wl.week_start = v_last_week_start
          AND wl.tier = v_tier
          AND lm.promotion_status = 'stayed'
      ) all_users;
    END IF;
    
    -- Create balanced leagues if we have users
    IF v_users_in_tier IS NOT NULL AND ARRAY_LENGTH(v_users_in_tier, 1) > 0 THEN
      v_total_users := ARRAY_LENGTH(v_users_in_tier, 1);
      v_league_number := 1;
      
      -- Chunk users into groups of 20 and create leagues
      FOR i IN 1..CEIL(v_total_users::NUMERIC / 20.0) LOOP
        v_chunk_start := (i-1)*20+1;
        v_chunk_end := LEAST(i*20, v_total_users);
        
        INSERT INTO weekly_leagues (week_start, week_end, tier, league_number, is_active)
        VALUES (v_week_start, v_week_end, v_tier, v_league_number, true)
        RETURNING id INTO v_league_id;
        
        -- Place users into this league
        INSERT INTO league_memberships (user_id, league_id, week_start, starting_xp, week_xp, promotion_status)
        SELECT 
          uid,
          v_league_id,
          v_week_start,
          COALESCE((SELECT total_xp FROM user_stats WHERE user_stats.user_id = uid), 0),
          0,
          NULL
        FROM unnest(v_users_in_tier[v_chunk_start:v_chunk_end]) AS uid;
        
        v_league_number := v_league_number + 1;
      END LOOP;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- One-time cleanup and backfill script
DO $$
DECLARE
  v_week_boundaries RECORD;
  v_week_start TIMESTAMPTZ;
  v_week_end TIMESTAMPTZ;
  v_user RECORD;
  v_backfill_xp INTEGER;
  v_league_id UUID;
  v_current_league_number INTEGER := 1;
  v_users_in_current_league INTEGER := 0;
BEGIN
  -- Get current week boundaries
  SELECT * INTO v_week_boundaries FROM get_current_league_week_boundaries();
  v_week_start := v_week_boundaries.week_start;
  v_week_end := v_week_boundaries.week_end;
  
  -- Delete all existing league memberships and leagues
  DELETE FROM league_memberships;
  DELETE FROM weekly_leagues;
  
  -- Create first Initiate league
  INSERT INTO weekly_leagues (tier, league_number, week_start, week_end, is_active)
  VALUES ('initiate', v_current_league_number, v_week_start::DATE, v_week_end::DATE, true)
  RETURNING id INTO v_league_id;
  
  -- Backfill all users with XP earned since week_start
  FOR v_user IN 
    SELECT DISTINCT user_id FROM user_stats ORDER BY user_id
  LOOP
    -- Calculate backfill XP
    SELECT COALESCE(SUM(xp_amount), 0) INTO v_backfill_xp
    FROM xp_transactions
    WHERE user_id = v_user.user_id
      AND created_at >= v_week_start
      AND created_at <= v_week_end;
    
    -- If current league is full, create a new one
    IF v_users_in_current_league >= 20 THEN
      v_current_league_number := v_current_league_number + 1;
      INSERT INTO weekly_leagues (tier, league_number, week_start, week_end, is_active)
      VALUES ('initiate', v_current_league_number, v_week_start::DATE, v_week_end::DATE, true)
      RETURNING id INTO v_league_id;
      v_users_in_current_league := 0;
    END IF;
    
    -- Place user in league with backfilled XP
    INSERT INTO league_memberships (user_id, league_id, week_start, week_xp, starting_xp)
    SELECT 
      v_user.user_id,
      v_league_id,
      v_week_start::DATE,
      v_backfill_xp,
      COALESCE(total_xp, 0) - v_backfill_xp
    FROM user_stats
    WHERE user_id = v_user.user_id;
    
    v_users_in_current_league := v_users_in_current_league + 1;
  END LOOP;
END $$;