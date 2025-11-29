-- Add custom status fields to profiles table
ALTER TABLE profiles 
ADD COLUMN IF NOT EXISTS custom_status_text text,
ADD COLUMN IF NOT EXISTS custom_status_emoji text;

-- Create index for better performance when querying custom statuses
CREATE INDEX IF NOT EXISTS idx_profiles_custom_status ON profiles(custom_status_text) WHERE custom_status_text IS NOT NULL;