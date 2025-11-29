-- ============================================
-- XP BOOSTER ENHANCEMENTS (Stage 2)
-- ============================================

-- 1. Enhanced streak booster function with 30/60/100 day milestones
CREATE OR REPLACE FUNCTION public.check_extended_streak_boosters()
RETURNS TRIGGER AS $$
BEGIN
  -- 7-day streak: +10% for 24 hours
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
  
  -- 30-day streak: +20% for 48 hours
  IF NEW.streak_count = 30 AND (OLD.streak_count IS NULL OR OLD.streak_count < 30) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_30day', 1.20, NOW() + INTERVAL '48 hours')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      NULL,
      200,
      '30-day streak bonus! +20% XP boost for 48h'
    );
  END IF;
  
  -- 60-day streak: +30% for 72 hours
  IF NEW.streak_count = 60 AND (OLD.streak_count IS NULL OR OLD.streak_count < 60) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_60day', 1.30, NOW() + INTERVAL '72 hours')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      NULL,
      500,
      '60-day streak bonus! +30% XP boost for 72h'
    );
  END IF;
  
  -- 100-day streak: +50% for 7 days
  IF NEW.streak_count = 100 AND (OLD.streak_count IS NULL OR OLD.streak_count < 100) THEN
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (NEW.user_id, 'streak_100day', 1.50, NOW() + INTERVAL '7 days')
    ON CONFLICT DO NOTHING;
    
    PERFORM award_xp(
      NEW.user_id,
      'streak_bonus',
      NULL,
      1000,
      '100-day streak bonus! +50% XP boost for 7 days!'
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Replace the old check_streak_booster trigger with the new function
DROP TRIGGER IF EXISTS on_streak_update ON profiles;
CREATE TRIGGER on_streak_update
  AFTER UPDATE OF streak_count ON profiles
  FOR EACH ROW
  WHEN (NEW.streak_count IS DISTINCT FROM OLD.streak_count)
  EXECUTE FUNCTION check_extended_streak_boosters();

-- 2. Weekend Challenge booster (auto-activates on Saturdays and Sundays)
CREATE OR REPLACE FUNCTION public.activate_weekend_booster()
RETURNS void AS $$
DECLARE
  user_record RECORD;
BEGIN
  -- Only run on weekends (Saturday = 6, Sunday = 0)
  IF EXTRACT(DOW FROM NOW()) IN (0, 6) THEN
    -- Activate weekend booster for all users who don't have one yet
    FOR user_record IN 
      SELECT user_id FROM profiles
      WHERE NOT EXISTS (
        SELECT 1 FROM user_xp_boosters
        WHERE user_id = profiles.user_id
        AND booster_type = 'weekend_challenge'
        AND is_active = true
        AND expires_at > NOW()
      )
    LOOP
      INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
      VALUES (
        user_record.user_id, 
        'weekend_challenge', 
        1.25, 
        date_trunc('day', NOW()) + INTERVAL '1 day' + INTERVAL '23 hours 59 minutes'
      )
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3. Random Double XP Hour booster
CREATE OR REPLACE FUNCTION public.activate_random_double_xp_hour()
RETURNS void AS $$
DECLARE
  user_record RECORD;
  random_user_count INTEGER;
BEGIN
  -- Select 20% of active users randomly
  SELECT COUNT(*) INTO random_user_count
  FROM profiles
  WHERE last_login_date >= CURRENT_DATE - INTERVAL '7 days';
  
  random_user_count := GREATEST(1, FLOOR(random_user_count * 0.2));
  
  -- Activate double XP hour for random selection of users
  FOR user_record IN 
    SELECT user_id FROM profiles
    WHERE last_login_date >= CURRENT_DATE - INTERVAL '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM user_xp_boosters
      WHERE user_id = profiles.user_id
      AND booster_type = 'double_xp_hour'
      AND is_active = true
      AND expires_at > NOW()
    )
    ORDER BY RANDOM()
    LIMIT random_user_count
  LOOP
    INSERT INTO user_xp_boosters (user_id, booster_type, multiplier, expires_at)
    VALUES (user_record.user_id, 'double_xp_hour', 2.0, NOW() + INTERVAL '1 hour')
    ON CONFLICT DO NOTHING;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;