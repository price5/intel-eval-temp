-- Update the handle_user_login function to increment days_active
CREATE OR REPLACE FUNCTION public.handle_user_login(user_id_param uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  current_profile profiles%ROWTYPE;
  today_date date;
  yesterday_date date;
BEGIN
  today_date := CURRENT_DATE;
  yesterday_date := today_date - INTERVAL '1 day';
  
  -- Get current profile data
  SELECT * INTO current_profile 
  FROM profiles 
  WHERE user_id = user_id_param;
  
  -- If no profile found, exit
  IF NOT FOUND THEN
    RETURN;
  END IF;
  
  -- Check if this is first login (last_login_date is null) or if user is logging in today
  IF current_profile.last_login_date IS NULL THEN
    -- First time login - set streak to 1 and days_active to 1
    UPDATE profiles 
    SET 
      streak_count = 1,
      days_active = 1,
      last_login_date = today_date,
      updated_at = now()
    WHERE user_id = user_id_param;
  ELSIF current_profile.last_login_date = yesterday_date THEN
    -- User logged in yesterday, continue streak and increment days_active
    UPDATE profiles 
    SET 
      streak_count = current_profile.streak_count + 1,
      days_active = COALESCE(current_profile.days_active, 0) + 1,
      last_login_date = today_date,
      updated_at = now()
    WHERE user_id = user_id_param;
  ELSIF current_profile.last_login_date < yesterday_date THEN
    -- User missed days, reset streak to 1 but increment days_active
    UPDATE profiles 
    SET 
      streak_count = 1,
      days_active = COALESCE(current_profile.days_active, 0) + 1,
      last_login_date = today_date,
      updated_at = now()
    WHERE user_id = user_id_param;
  ELSIF current_profile.last_login_date = today_date THEN
    -- User already logged in today, do nothing
    NULL;
  END IF;
END;
$function$;