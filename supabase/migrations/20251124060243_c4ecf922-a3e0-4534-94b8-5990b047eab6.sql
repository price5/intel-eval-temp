-- Step 1: Drop all existing award_xp function versions
DROP FUNCTION IF EXISTS public.award_xp(uuid, text, integer, uuid, text);
DROP FUNCTION IF EXISTS public.award_xp(uuid, text, uuid, integer, text);
DROP FUNCTION IF EXISTS public.award_xp(uuid, text, integer, text, uuid);

-- Step 2: Create single canonical award_xp function with correct Sunday 08:30 UTC boundaries
CREATE OR REPLACE FUNCTION public.award_xp(
  p_user_id uuid,
  p_activity_type text,
  p_base_xp integer,
  p_activity_id uuid DEFAULT NULL,
  p_description text DEFAULT NULL
)
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

  -- Get user's tier from total XP
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

      -- Find first available league for user's tier with matching week_start
      SELECT id INTO v_league_id
      FROM weekly_leagues
      WHERE tier = v_user_tier
        AND week_start = v_week_start
        AND is_active = true
        AND (
          SELECT COUNT(*) 
          FROM league_memberships 
          WHERE league_id = weekly_leagues.id
        ) < 27
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

-- Step 3: Update trigger for practice problems
CREATE OR REPLACE FUNCTION public.trigger_xp_for_practice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
      v_base_xp,
      NEW.id,
      'Completed ' || v_problem_difficulty || ' practice problem'
    );
    
    IF NEW.explanation_score >= 80 THEN
      PERFORM award_xp(
        NEW.student_id,
        'clean_explanation',
        15,
        NEW.id,
        'Clean explanation bonus'
      );
    END IF;
    
    IF NEW.overall_score = 100 THEN
      PERFORM award_xp(
        NEW.student_id,
        'perfect_score',
        50,
        NEW.id,
        'Perfect score bonus'
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Update trigger for assessments
CREATE OR REPLACE FUNCTION public.trigger_xp_for_assessment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_base_xp INTEGER := 100;
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    PERFORM award_xp(
      NEW.student_id,
      'assessment',
      v_base_xp,
      NEW.id,
      'Completed assessment'
    );
    
    IF NEW.explanation_score >= 80 THEN
      PERFORM award_xp(
        NEW.student_id,
        'clean_explanation',
        15,
        NEW.id,
        'Clean explanation bonus'
      );
    END IF;
    
    IF NEW.overall_score = 100 THEN
      PERFORM award_xp(
        NEW.student_id,
        'perfect_score',
        50,
        NEW.id,
        'Perfect score bonus'
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Update check_streak_booster trigger
CREATE OR REPLACE FUNCTION public.check_extended_streak_boosters()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.streak_count = 7 AND (OLD.streak_count IS NULL OR OLD.streak_count < 7) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_7day', 1.10, NOW() + INTERVAL '24 hours')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      50,
      NULL,
      '7-day streak bonus! +10% XP boost for 24h'
    );
  END IF;
  
  IF NEW.streak_count = 30 AND (OLD.streak_count IS NULL OR OLD.streak_count < 30) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_30day', 1.20, NOW() + INTERVAL '48 hours')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      200,
      NULL,
      '30-day streak bonus! +20% XP boost for 48h'
    );
  END IF;
  
  IF NEW.streak_count = 60 AND (OLD.streak_count IS NULL OR OLD.streak_count < 60) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_60day', 1.30, NOW() + INTERVAL '72 hours')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      500,
      NULL,
      '60-day streak bonus! +30% XP boost for 72h'
    );
  END IF;
  
  IF NEW.streak_count = 100 AND (OLD.streak_count IS NULL OR OLD.streak_count < 100) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_100day', 1.50, NOW() + INTERVAL '7 days')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      1000,
      NULL,
      '100-day streak bonus! +50% XP boost for 7 days!'
    );
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Step 4: Clean up incorrect league data
-- Deactivate leagues with incorrect week boundaries (Monday 00:00:00)
UPDATE weekly_leagues
SET is_active = false
WHERE week_start = '2025-11-24 00:00:00+00'::timestamptz;

-- Transfer XP from incorrect league to correct league for affected users
WITH incorrect_memberships AS (
  SELECT lm.user_id, lm.week_xp, lm.league_id
  FROM league_memberships lm
  JOIN weekly_leagues wl ON wl.id = lm.league_id
  WHERE wl.week_start = '2025-11-24 00:00:00+00'::timestamptz
),
correct_leagues AS (
  SELECT id, tier
  FROM weekly_leagues
  WHERE week_start = '2025-11-23 08:30:00+00'::timestamptz
  AND is_active = true
)
INSERT INTO league_memberships (user_id, league_id, week_start, starting_xp, week_xp)
SELECT 
  im.user_id,
  (SELECT id FROM correct_leagues WHERE tier = 'initiate' LIMIT 1),
  '2025-11-23 08:30:00+00'::timestamptz,
  0,
  im.week_xp
FROM incorrect_memberships im
ON CONFLICT (user_id, week_start) 
DO UPDATE SET week_xp = league_memberships.week_xp + EXCLUDED.week_xp;

-- Delete incorrect league memberships
DELETE FROM league_memberships lm
USING weekly_leagues wl
WHERE lm.league_id = wl.id
AND wl.week_start = '2025-11-24 00:00:00+00'::timestamptz;