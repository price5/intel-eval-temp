-- Create achievement_events table for tracking user events
CREATE TABLE IF NOT EXISTS public.achievement_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  event_data jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Add index for efficient querying
CREATE INDEX idx_achievement_events_user_type ON public.achievement_events(user_id, event_type);
CREATE INDEX idx_achievement_events_created_at ON public.achievement_events(created_at DESC);

-- Enable RLS
ALTER TABLE public.achievement_events ENABLE ROW LEVEL SECURITY;

-- RLS policies for achievement_events
CREATE POLICY "Users can insert their own events"
  ON public.achievement_events
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can view their own events"
  ON public.achievement_events
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Create user_event_counters table for optimized queries
CREATE TABLE IF NOT EXISTS public.user_event_counters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  counter_key text NOT NULL,
  counter_value integer NOT NULL DEFAULT 0,
  updated_at timestamp with time zone DEFAULT now(),
  UNIQUE(user_id, counter_key)
);

ALTER TABLE public.user_event_counters ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own counters"
  ON public.user_event_counters
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "System can manage counters"
  ON public.user_event_counters
  FOR ALL
  TO authenticated
  USING (true);

-- Enhanced achievement evaluation function
CREATE OR REPLACE FUNCTION public.evaluate_and_award_achievements(user_id_param uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  newly_awarded jsonb := '[]'::jsonb;
  achievement_record RECORD;
  criteria_type text;
  criteria_value integer;
  user_value integer;
  is_eligible boolean;
BEGIN
  -- Iterate through all active achievements
  FOR achievement_record IN 
    SELECT * FROM achievements WHERE criteria IS NOT NULL
  LOOP
    -- Check if user already has this achievement
    IF EXISTS (
      SELECT 1 FROM user_achievements 
      WHERE user_id = user_id_param 
      AND achievement_id = achievement_record.id
    ) THEN
      CONTINUE;
    END IF;
    
    -- Extract criteria
    criteria_type := achievement_record.criteria->>'type';
    criteria_value := (achievement_record.criteria->>'value')::integer;
    is_eligible := false;
    
    -- Evaluate based on criteria type
    CASE criteria_type
      WHEN 'submissions_count' THEN
        SELECT COALESCE(submissions_count, 0) INTO user_value
        FROM user_stats WHERE user_id = user_id_param;
        is_eligible := user_value >= criteria_value;
        
      WHEN 'streak' THEN
        SELECT COALESCE(streak_count, 0) INTO user_value
        FROM profiles WHERE user_id = user_id_param;
        is_eligible := user_value >= criteria_value;
        
      WHEN 'days_active' THEN
        SELECT COALESCE(days_active, 0) INTO user_value
        FROM profiles WHERE user_id = user_id_param;
        is_eligible := user_value >= criteria_value;
        
      WHEN 'event_count' THEN
        SELECT COUNT(*) INTO user_value
        FROM achievement_events
        WHERE user_id = user_id_param
        AND event_type = achievement_record.criteria->>'event';
        is_eligible := user_value >= criteria_value;
        
      WHEN 'perfect_scores' THEN
        SELECT COALESCE(perfect_scores, 0) INTO user_value
        FROM user_stats WHERE user_id = user_id_param;
        is_eligible := user_value >= criteria_value;
        
      WHEN 'score_threshold' THEN
        SELECT COALESCE(
          (SELECT AVG(overall_score) FROM practice_sessions WHERE student_id = user_id_param),
          0
        ) INTO user_value;
        is_eligible := user_value >= criteria_value;
        
      ELSE
        -- Unknown criteria type, skip
        CONTINUE;
    END CASE;
    
    -- Award achievement if eligible
    IF is_eligible THEN
      INSERT INTO user_achievements (user_id, achievement_id, progress, progress_max)
      VALUES (user_id_param, achievement_record.id, user_value, criteria_value)
      ON CONFLICT (user_id, achievement_id) DO NOTHING;
      
      -- Add to newly awarded list
      IF FOUND THEN
        newly_awarded := newly_awarded || jsonb_build_object(
          'id', achievement_record.id,
          'name', achievement_record.name,
          'icon', achievement_record.icon,
          'points', achievement_record.points
        );
      END IF;
    END IF;
  END LOOP;
  
  RETURN newly_awarded;
END;
$$;

-- Function to increment event counter
CREATE OR REPLACE FUNCTION public.increment_event_counter(
  user_id_param uuid,
  counter_key_param text,
  increment_by integer DEFAULT 1
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  INSERT INTO user_event_counters (user_id, counter_key, counter_value)
  VALUES (user_id_param, counter_key_param, increment_by)
  ON CONFLICT (user_id, counter_key)
  DO UPDATE SET 
    counter_value = user_event_counters.counter_value + increment_by,
    updated_at = now();
END;
$$;

-- Add method column to user_achievements if it doesn't exist
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'user_achievements' 
    AND column_name = 'method'
  ) THEN
    ALTER TABLE user_achievements ADD COLUMN method text DEFAULT 'auto';
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'user_achievements' 
    AND column_name = 'awarded_by'
  ) THEN
    ALTER TABLE user_achievements ADD COLUMN awarded_by uuid REFERENCES auth.users(id);
  END IF;
END $$;