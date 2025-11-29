-- ============================================
-- XP-BASED WEEKLY LEAGUE SYSTEM - COMPLETE
-- ============================================

-- 1. Create weekly leagues table
CREATE TABLE IF NOT EXISTS weekly_leagues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_start DATE NOT NULL,
  week_end DATE NOT NULL,
  tier TEXT NOT NULL CHECK (tier IN ('initiate', 'thinker', 'strategist', 'analyst', 'prodigy', 'mastermind')),
  league_number INTEGER NOT NULL,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(week_start, tier, league_number)
);

-- 2. Create league memberships table
CREATE TABLE IF NOT EXISTS league_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  league_id UUID NOT NULL REFERENCES weekly_leagues(id) ON DELETE CASCADE,
  week_start DATE NOT NULL,
  starting_xp INTEGER DEFAULT 0,
  week_xp INTEGER DEFAULT 0,
  final_rank INTEGER,
  promotion_status TEXT CHECK (promotion_status IN ('promoted', 'stayed', 'demoted', 'pending')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, week_start)
);

-- 3. Create XP transactions table
CREATE TABLE IF NOT EXISTS xp_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  xp_amount INTEGER NOT NULL,
  activity_type TEXT NOT NULL CHECK (activity_type IN ('practice_problem', 'assessment', 'streak_bonus', 'clean_explanation', 'first_try', 'perfect_score', 'booster', 'weekend_challenge')),
  activity_id UUID,
  multiplier NUMERIC DEFAULT 1.0,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Create user XP boosters table
CREATE TABLE IF NOT EXISTS user_xp_boosters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  booster_type TEXT NOT NULL CHECK (booster_type IN ('streak_7day', 'double_xp_hour', 'weekend_challenge')),
  multiplier NUMERIC NOT NULL DEFAULT 1.0,
  is_active BOOLEAN DEFAULT true,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Create indices for performance
CREATE INDEX IF NOT EXISTS idx_xp_transactions_user_created ON xp_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_league_memberships_user_week ON league_memberships(user_id, week_start);
CREATE INDEX IF NOT EXISTS idx_league_memberships_league ON league_memberships(league_id, week_xp DESC);
CREATE INDEX IF NOT EXISTS idx_weekly_leagues_active ON weekly_leagues(week_start, is_active);
CREATE INDEX IF NOT EXISTS idx_user_xp_boosters_active ON user_xp_boosters(user_id, is_active, expires_at);

-- 6. Enable RLS on new tables
ALTER TABLE weekly_leagues ENABLE ROW LEVEL SECURITY;
ALTER TABLE league_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE xp_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_xp_boosters ENABLE ROW LEVEL SECURITY;

-- 7. RLS Policies for weekly_leagues
CREATE POLICY "Everyone can view leagues"
  ON weekly_leagues FOR SELECT
  USING (true);

CREATE POLICY "System can manage leagues"
  ON weekly_leagues FOR ALL
  USING (auth.uid() IS NOT NULL);

-- 8. RLS Policies for league_memberships
CREATE POLICY "Everyone can view league memberships"
  ON league_memberships FOR SELECT
  USING (true);

CREATE POLICY "System can manage league memberships"
  ON league_memberships FOR ALL
  USING (auth.uid() IS NOT NULL);

-- 9. RLS Policies for xp_transactions
CREATE POLICY "Users can view their own XP transactions"
  ON xp_transactions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "System can insert XP transactions"
  ON xp_transactions FOR INSERT
  WITH CHECK (true);

-- 10. RLS Policies for user_xp_boosters
CREATE POLICY "Users can view their own boosters"
  ON user_xp_boosters FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "System can manage boosters"
  ON user_xp_boosters FOR ALL
  USING (auth.uid() IS NOT NULL);

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Get lower tier for promotion
CREATE OR REPLACE FUNCTION get_lower_tier(current_tier TEXT)
RETURNS TEXT AS $$
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
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get higher tier for demotion
CREATE OR REPLACE FUNCTION get_higher_tier(current_tier TEXT)
RETURNS TEXT AS $$
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
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================
-- XP AWARD FUNCTION
-- ============================================

CREATE OR REPLACE FUNCTION award_xp(
  p_user_id UUID,
  p_activity_type TEXT,
  p_activity_id UUID,
  p_base_xp INTEGER,
  p_description TEXT DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
  v_multiplier NUMERIC := 1.0;
  v_final_xp INTEGER;
  v_week_start DATE;
BEGIN
  -- Get current week start (Monday)
  v_week_start := date_trunc('week', NOW())::DATE;
  
  -- Check for active boosters
  SELECT COALESCE(SUM(multiplier - 1.0) + 1.0, 1.0) INTO v_multiplier
  FROM user_xp_boosters
  WHERE user_id = p_user_id
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > NOW());
  
  -- Calculate final XP
  v_final_xp := FLOOR(p_base_xp * v_multiplier);
  
  -- Insert transaction
  INSERT INTO xp_transactions (
    user_id, xp_amount, activity_type, activity_id, multiplier, description
  ) VALUES (
    p_user_id, v_final_xp, p_activity_type, p_activity_id, v_multiplier, p_description
  );
  
  -- Update user_stats
  UPDATE user_stats
  SET 
    current_xp = current_xp + v_final_xp,
    total_xp = total_xp + v_final_xp,
    updated_at = NOW()
  WHERE user_id = p_user_id;
  
  -- Update weekly league XP (only if membership exists)
  UPDATE league_memberships
  SET 
    week_xp = week_xp + v_final_xp,
    updated_at = NOW()
  WHERE user_id = p_user_id
    AND week_start = v_week_start;
  
  RETURN v_final_xp;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- LEAGUE CREATION FUNCTION
-- ============================================

CREATE OR REPLACE FUNCTION create_weekly_leagues() RETURNS void AS $$
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
  -- Get all active users who don't have a league for this week
  SELECT ARRAY_AGG(user_id) INTO v_all_users
  FROM profiles
  WHERE user_id NOT IN (
    SELECT user_id FROM league_memberships WHERE week_start = v_week_start
  );
  
  -- If no users need placement, check last week's leagues
  IF v_all_users IS NULL OR ARRAY_LENGTH(v_all_users, 1) = 0 THEN
    -- Process each tier
    FOR v_tier IN SELECT unnest(ARRAY['initiate', 'thinker', 'strategist', 'analyst', 'prodigy', 'mastermind'])
    LOOP
      -- Get users for this tier based on last week
      SELECT ARRAY_AGG(lm.user_id ORDER BY lm.week_xp DESC) INTO v_users_in_tier
      FROM league_memberships lm
      JOIN weekly_leagues wl ON lm.league_id = wl.id
      WHERE wl.week_start = v_week_start - INTERVAL '7 days'
        AND wl.tier = v_tier
        AND lm.promotion_status IS NOT NULL;
      
      -- Handle promotions/demotions
      IF v_users_in_tier IS NOT NULL AND ARRAY_LENGTH(v_users_in_tier, 1) > 0 THEN
        -- Create leagues and assign users
        v_league_number := 1;
        FOR i IN 1..CEIL(ARRAY_LENGTH(v_users_in_tier, 1)::NUMERIC / 27.0) LOOP
          v_chunk_start := (i-1)*27+1;
          v_chunk_end := LEAST(i*27, ARRAY_LENGTH(v_users_in_tier, 1));
          
          -- Create league
          INSERT INTO weekly_leagues (week_start, week_end, tier, league_number, is_active)
          VALUES (v_week_start, v_week_end, v_tier, v_league_number, true)
          RETURNING id INTO v_league_id;
          
          -- Assign users to league
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
    -- First time setup: place all users in Initiate tier
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- WEEKLY PROMOTIONS FUNCTION
-- ============================================

CREATE OR REPLACE FUNCTION process_weekly_promotions() RETURNS void AS $$
DECLARE
  v_last_week_start DATE := date_trunc('week', NOW() - INTERVAL '7 days')::DATE;
  v_league RECORD;
  v_ranked_users RECORD;
  v_total_users INTEGER;
  v_rank_position INTEGER;
  v_promotion_threshold INTEGER;
  v_demotion_threshold INTEGER;
BEGIN
  -- For each league from last week
  FOR v_league IN 
    SELECT id, tier FROM weekly_leagues 
    WHERE week_start = v_last_week_start AND is_active = true
  LOOP
    -- Get total users in league
    SELECT COUNT(*) INTO v_total_users
    FROM league_memberships
    WHERE league_id = v_league.id;
    
    -- Calculate thresholds
    v_promotion_threshold := LEAST(5, GREATEST(1, FLOOR(v_total_users * 0.2)));
    v_demotion_threshold := v_total_users - LEAST(5, GREATEST(1, FLOOR(v_total_users * 0.2)));
    
    -- Rank users and assign promotion status
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
  
  -- Mark leagues as processed
  UPDATE weekly_leagues
  SET is_active = false
  WHERE week_start = v_last_week_start;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- XP TRIGGERS FOR PRACTICE PROBLEMS
-- ============================================

CREATE OR REPLACE FUNCTION trigger_xp_for_practice() RETURNS TRIGGER AS $$
DECLARE
  v_base_xp INTEGER;
  v_problem_difficulty TEXT;
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    -- Get difficulty
    SELECT difficulty INTO v_problem_difficulty
    FROM practice_problems
    WHERE id = NEW.problem_id;
    
    -- Base XP by difficulty
    v_base_xp := CASE v_problem_difficulty
      WHEN 'easy' THEN 30
      WHEN 'medium' THEN 50
      WHEN 'hard' THEN 80
      ELSE 40
    END;
    
    -- Award base XP
    PERFORM award_xp(
      NEW.student_id,
      'practice_problem',
      NEW.id,
      v_base_xp,
      'Completed ' || v_problem_difficulty || ' practice problem'
    );
    
    -- Bonus for clean explanation
    IF NEW.explanation_score >= 80 THEN
      PERFORM award_xp(
        NEW.student_id,
        'clean_explanation',
        NEW.id,
        15,
        'Clean explanation bonus'
      );
    END IF;
    
    -- Bonus for perfect score
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS xp_for_practice_trigger ON practice_problem_submissions;
CREATE TRIGGER xp_for_practice_trigger
  AFTER INSERT OR UPDATE ON practice_problem_submissions
  FOR EACH ROW
  EXECUTE FUNCTION trigger_xp_for_practice();

-- ============================================
-- XP TRIGGERS FOR ASSESSMENTS
-- ============================================

CREATE OR REPLACE FUNCTION trigger_xp_for_assessment() RETURNS TRIGGER AS $$
DECLARE
  v_base_xp INTEGER := 100;
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    -- Award base XP
    PERFORM award_xp(
      NEW.student_id,
      'assessment',
      NEW.id,
      v_base_xp,
      'Completed assessment'
    );
    
    -- Bonus for clean explanation
    IF NEW.explanation_score >= 80 THEN
      PERFORM award_xp(
        NEW.student_id,
        'clean_explanation',
        NEW.id,
        15,
        'Clean explanation bonus'
      );
    END IF;
    
    -- Bonus for perfect score
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS xp_for_assessment_trigger ON assessment_submissions;
CREATE TRIGGER xp_for_assessment_trigger
  AFTER INSERT OR UPDATE ON assessment_submissions
  FOR EACH ROW
  EXECUTE FUNCTION trigger_xp_for_assessment();

-- ============================================
-- STREAK BOOSTER TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION check_streak_booster() RETURNS TRIGGER AS $$
BEGIN
  -- Award 7-day streak booster
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS streak_booster_trigger ON profiles;
CREATE TRIGGER streak_booster_trigger
  AFTER UPDATE ON profiles
  FOR EACH ROW
  WHEN (NEW.streak_count IS DISTINCT FROM OLD.streak_count)
  EXECUTE FUNCTION check_streak_booster();