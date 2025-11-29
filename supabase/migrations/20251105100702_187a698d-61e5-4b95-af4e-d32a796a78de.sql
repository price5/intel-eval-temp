-- Add inactivity_timeout field to profiles table to store user preference
ALTER TABLE profiles
ADD COLUMN inactivity_timeout INTEGER DEFAULT 5 CHECK (inactivity_timeout IN (5, 10, 15, 30));