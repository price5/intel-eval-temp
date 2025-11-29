-- Add custom status expiration field
ALTER TABLE profiles 
ADD COLUMN custom_status_expires_at timestamp with time zone;

-- Create function to clear expired statuses
CREATE OR REPLACE FUNCTION clear_expired_custom_statuses()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  UPDATE profiles
  SET 
    custom_status_text = NULL,
    custom_status_emoji = NULL,
    custom_status_expires_at = NULL,
    updated_at = now()
  WHERE custom_status_expires_at IS NOT NULL 
    AND custom_status_expires_at <= now();
END;
$$;