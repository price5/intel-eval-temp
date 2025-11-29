-- Fix security warning: Add search_path to helper function
DROP FUNCTION IF EXISTS get_current_league_week_boundaries();

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
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;