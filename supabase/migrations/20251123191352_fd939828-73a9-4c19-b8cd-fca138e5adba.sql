-- Fix week boundaries to be Sunday-to-Sunday instead of Monday-to-Monday

-- First, update the current active week to start on the most recent Sunday (Nov 23, 2025 at 08:30 UTC)
UPDATE weekly_leagues
SET 
  week_start = '2025-11-23 08:30:00+00'::timestamptz,
  week_end = '2025-11-30 08:29:59+00'::timestamptz
WHERE week_start = '2025-11-17 08:30:00+00'::timestamptz;

-- Update corresponding league memberships
UPDATE league_memberships
SET week_start = '2025-11-23 08:30:00+00'::timestamptz
WHERE week_start = '2025-11-17 08:30:00+00'::timestamptz;

-- Recreate create_weekly_leagues() to properly calculate Sunday boundaries
CREATE OR REPLACE FUNCTION public.create_weekly_leagues()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_week_start TIMESTAMPTZ;
  v_week_end TIMESTAMPTZ;
  v_tier TEXT;
  v_league_number INTEGER;
  v_league_id UUID;
  v_user RECORD;
  v_current_league_size INTEGER;
BEGIN
  -- Calculate current week boundaries (Sunday 08:30 UTC to next Sunday 08:30 UTC)
  -- date_trunc('week', ...) returns Monday, so we subtract 1 day to get Sunday
  v_week_start := date_trunc('week', CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - INTERVAL '1 day'
                  + INTERVAL '8 hours 30 minutes';
  
  -- If we're before this Sunday 08:30, go back to previous Sunday
  IF CURRENT_TIMESTAMP < v_week_start THEN
    v_week_start := v_week_start - INTERVAL '7 days';
  END IF;
  
  v_week_end := v_week_start + INTERVAL '7 days' - INTERVAL '1 second';

  -- For each tier, get all users and distribute them into leagues of 20
  FOR v_tier IN SELECT unnest(ARRAY['initiate', 'thinker', 'strategist', 'analyst', 'prodigy', 'mastermind']) LOOP
    v_league_number := 1;
    v_current_league_size := 0;
    v_league_id := NULL;

    -- Get users in this tier, ordered by last week's performance
    FOR v_user IN
      SELECT 
        p.user_id,
        COALESCE(
          (SELECT lm.week_xp 
           FROM league_memberships lm 
           JOIN weekly_leagues wl ON wl.id = lm.league_id
           WHERE lm.user_id = p.user_id 
             AND wl.week_start = v_week_start - INTERVAL '7 days'
           LIMIT 1),
          0
        ) as last_week_xp
      FROM profiles p
      WHERE p.achievement_role = v_tier
      ORDER BY last_week_xp DESC, p.created_at ASC
    LOOP
      -- Create new league if needed (every 20 users)
      IF v_current_league_size = 0 OR v_current_league_size >= 20 THEN
        INSERT INTO weekly_leagues (
          tier,
          league_number,
          week_start,
          week_end,
          is_active
        ) VALUES (
          v_tier,
          v_league_number,
          v_week_start,
          v_week_end,
          true
        ) RETURNING id INTO v_league_id;

        v_league_number := v_league_number + 1;
        v_current_league_size := 0;
      END IF;

      -- Add user to current league
      INSERT INTO league_memberships (
        user_id,
        league_id,
        week_start,
        starting_xp,
        week_xp
      ) VALUES (
        v_user.user_id,
        v_league_id,
        v_week_start,
        0,
        0
      ) ON CONFLICT (user_id, week_start) DO NOTHING;

      v_current_league_size := v_current_league_size + 1;
    END LOOP;
  END LOOP;
END;
$function$;

-- Recreate process_weekly_promotions() with correct Sunday calculation
CREATE OR REPLACE FUNCTION public.process_weekly_promotions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_last_week_start TIMESTAMPTZ;
  v_last_week_end TIMESTAMPTZ;
BEGIN
  -- Calculate last week's boundaries (Sunday to Sunday)
  v_last_week_start := date_trunc('week', CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - INTERVAL '1 day'
                       + INTERVAL '8 hours 30 minutes' - INTERVAL '7 days';
  
  IF CURRENT_TIMESTAMP < (v_last_week_start + INTERVAL '7 days') THEN
    v_last_week_start := v_last_week_start - INTERVAL '7 days';
  END IF;
  
  v_last_week_end := v_last_week_start + INTERVAL '7 days' - INTERVAL '1 second';

  -- Process promotions and demotions for each league
  WITH league_rankings AS (
    SELECT 
      lm.user_id,
      lm.league_id,
      wl.tier,
      lm.week_xp,
      ROW_NUMBER() OVER (PARTITION BY lm.league_id ORDER BY lm.week_xp DESC, lm.created_at ASC) as rank,
      COUNT(*) OVER (PARTITION BY lm.league_id) as total_users
    FROM league_memberships lm
    JOIN weekly_leagues wl ON wl.id = lm.league_id
    WHERE lm.week_start = v_last_week_start
      AND wl.is_active = true
  ),
  promotion_calculations AS (
    SELECT 
      *,
      FLOOR(total_users * 0.25) as promotion_count,
      FLOOR(total_users * 0.25) as demotion_count
    FROM league_rankings
  )
  UPDATE league_memberships lm
  SET 
    final_rank = pc.rank,
    promotion_status = CASE
      WHEN pc.rank <= pc.promotion_count AND pc.tier != 'mastermind' THEN 'promoted'
      WHEN pc.rank > (pc.total_users - pc.demotion_count) AND pc.tier != 'initiate' THEN 'demoted'
      ELSE 'stayed'
    END,
    updated_at = CURRENT_TIMESTAMP
  FROM promotion_calculations pc
  WHERE lm.user_id = pc.user_id
    AND lm.league_id = pc.league_id
    AND lm.week_start = v_last_week_start;

  -- Update user tiers in profiles based on promotion status
  UPDATE profiles p
  SET 
    achievement_role = CASE
      WHEN lm.promotion_status = 'promoted' THEN 
        (SELECT get_higher_tier(wl.tier) FROM weekly_leagues wl WHERE wl.id = lm.league_id)
      WHEN lm.promotion_status = 'demoted' THEN
        (SELECT get_lower_tier(wl.tier) FROM weekly_leagues wl WHERE wl.id = lm.league_id)
      ELSE p.achievement_role
    END
  FROM league_memberships lm
  WHERE p.user_id = lm.user_id
    AND lm.week_start = v_last_week_start
    AND lm.promotion_status IS NOT NULL;

  -- Deactivate last week's leagues
  UPDATE weekly_leagues
  SET is_active = false
  WHERE week_start = v_last_week_start;
END;
$function$;

-- Recreate award_xp() with correct Sunday calculation
CREATE OR REPLACE FUNCTION public.award_xp(p_user_id uuid, p_activity_type text, p_base_xp integer, p_activity_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_final_xp INTEGER;
  v_active_multiplier NUMERIC := 1.0;
  v_week_start TIMESTAMPTZ;
  v_week_end TIMESTAMPTZ;
  v_user_tier TEXT;
  v_league_id UUID;
BEGIN
  -- Calculate week boundaries (Sunday 08:30 UTC to next Sunday 08:30 UTC)
  v_week_start := date_trunc('week', CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - INTERVAL '1 day'
                  + INTERVAL '8 hours 30 minutes';
  
  IF CURRENT_TIMESTAMP < v_week_start THEN
    v_week_start := v_week_start - INTERVAL '7 days';
  END IF;
  
  v_week_end := v_week_start + INTERVAL '7 days' - INTERVAL '1 second';

  -- Get any active XP booster
  SELECT COALESCE(MAX(multiplier), 1.0) INTO v_active_multiplier
  FROM user_xp_boosters
  WHERE user_id = p_user_id 
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP);

  v_final_xp := FLOOR(p_base_xp * v_active_multiplier);

  -- Update user_stats
  INSERT INTO user_stats (user_id, total_xp, current_xp, level, updated_at)
  VALUES (p_user_id, v_final_xp, v_final_xp, 1, CURRENT_TIMESTAMP)
  ON CONFLICT (user_id) DO UPDATE SET
    total_xp = user_stats.total_xp + v_final_xp,
    current_xp = user_stats.current_xp + v_final_xp,
    level = FLOOR((user_stats.total_xp + v_final_xp) / 1000.0) + 1,
    updated_at = CURRENT_TIMESTAMP;

  -- Record XP transaction
  INSERT INTO xp_transactions (
    user_id,
    xp_amount,
    activity_type,
    activity_id,
    description,
    multiplier
  ) VALUES (
    p_user_id,
    v_final_xp,
    p_activity_type,
    p_activity_id,
    p_description,
    v_active_multiplier
  );

  -- Get user's tier from profiles
  SELECT 
    CASE 
      WHEN total_xp < 1000 THEN 'initiate'
      WHEN total_xp < 3000 THEN 'thinker'
      WHEN total_xp < 7000 THEN 'strategist'
      WHEN total_xp < 15000 THEN 'analyst'
      WHEN total_xp < 30000 THEN 'prodigy'
      ELSE 'mastermind'
    END INTO v_user_tier
  FROM user_stats
  WHERE user_id = p_user_id;

  -- Check if user is already in a league for this week
  SELECT lm.league_id INTO v_league_id
  FROM league_memberships lm
  WHERE lm.user_id = p_user_id
    AND lm.week_start = v_week_start;

  IF v_league_id IS NULL THEN
    -- Get total XP earned this week for backfilling
    DECLARE
      v_week_xp INTEGER;
    BEGIN
      SELECT COALESCE(SUM(xp_amount), 0) INTO v_week_xp
      FROM xp_transactions
      WHERE user_id = p_user_id
        AND created_at >= v_week_start
        AND created_at <= v_week_end;

      -- Find first available league for user's tier
      SELECT id INTO v_league_id
      FROM weekly_leagues
      WHERE tier = v_user_tier
        AND week_start = v_week_start
        AND is_active = true
        AND (
          SELECT COUNT(*) 
          FROM league_memberships 
          WHERE league_id = weekly_leagues.id
        ) < 20
      ORDER BY league_number
      LIMIT 1;

      -- If no available league exists, create new one
      IF v_league_id IS NULL THEN
        DECLARE
          v_next_league_number INTEGER;
        BEGIN
          SELECT COALESCE(MAX(league_number), 0) + 1 INTO v_next_league_number
          FROM weekly_leagues
          WHERE tier = v_user_tier
            AND week_start = v_week_start;

          INSERT INTO weekly_leagues (
            tier,
            league_number,
            week_start,
            week_end,
            is_active
          ) VALUES (
            v_user_tier,
            v_next_league_number,
            v_week_start,
            v_week_end,
            true
          ) RETURNING id INTO v_league_id;
        END;
      END IF;

      -- Add user to league with backfilled XP
      INSERT INTO league_memberships (
        user_id,
        league_id,
        week_start,
        starting_xp,
        week_xp
      ) VALUES (
        p_user_id,
        v_league_id,
        v_week_start,
        0,
        v_week_xp
      );
    END;
  ELSE
    -- Update existing membership
    UPDATE league_memberships
    SET 
      week_xp = week_xp + v_final_xp,
      updated_at = CURRENT_TIMESTAMP
    WHERE user_id = p_user_id
      AND week_start = v_week_start;
  END IF;

  RETURN v_final_xp;
END;
$function$;

-- Recreate get_current_league_week_boundaries() with correct Sunday calculation
CREATE OR REPLACE FUNCTION public.get_current_league_week_boundaries()
RETURNS TABLE(week_start timestamp with time zone, week_end timestamp with time zone)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_current_week_start TIMESTAMPTZ;
BEGIN
  -- Calculate the most recent Sunday at 08:30 UTC (2pm IST)
  -- date_trunc('week', ...) returns Monday, so subtract 1 day to get Sunday
  v_current_week_start := date_trunc('week', v_now) - INTERVAL '1 day' + INTERVAL '08:30:00';
  
  -- If we're before Sunday 08:30 UTC, go back one week
  IF v_now < v_current_week_start THEN
    v_current_week_start := v_current_week_start - INTERVAL '7 days';
  END IF;
  
  RETURN QUERY SELECT 
    v_current_week_start,
    v_current_week_start + INTERVAL '7 days' - INTERVAL '1 second';
END;
$function$;