-- Fix week start calculation to always use Monday
-- Update create_weekly_leagues function to explicitly calculate Monday as week start
CREATE OR REPLACE FUNCTION public.create_weekly_leagues()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- Fix existing league data: update week_start from Sunday to Monday
UPDATE weekly_leagues
SET 
  week_start = week_start + INTERVAL '1 day',
  week_end = week_end + INTERVAL '1 day'
WHERE week_start = '2025-11-17';

-- Fix existing league membership data
UPDATE league_memberships
SET week_start = week_start + INTERVAL '1 day'
WHERE week_start = '2025-11-17';