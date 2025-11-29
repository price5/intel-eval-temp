-- Create user_moderation_logs table for tracking bans and suspensions
CREATE TABLE IF NOT EXISTS public.user_moderation_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('suspend', 'ban', 'unsuspend', 'unban')),
  reason TEXT NOT NULL,
  moderator_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  expires_at TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN DEFAULT true
);

-- Enable RLS
ALTER TABLE public.user_moderation_logs ENABLE ROW LEVEL SECURITY;

-- Admins can view all moderation logs
CREATE POLICY "Admins can view all moderation logs"
ON public.user_moderation_logs
FOR SELECT
USING (has_role(auth.uid(), 'admin'::app_role));

-- Admins can insert moderation logs
CREATE POLICY "Admins can insert moderation logs"
ON public.user_moderation_logs
FOR INSERT
WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_user_moderation_logs_user_id ON public.user_moderation_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_user_moderation_logs_active ON public.user_moderation_logs(user_id, is_active);

-- Add is_suspended and is_banned columns to profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS is_suspended BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS is_banned BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS moderation_reason TEXT,
ADD COLUMN IF NOT EXISTS moderation_expires_at TIMESTAMP WITH TIME ZONE;

-- Create function to check if user is currently moderated
CREATE OR REPLACE FUNCTION public.is_user_moderated(user_id_param UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = user_id_param
    AND (is_suspended = true OR is_banned = true)
    AND (moderation_expires_at IS NULL OR moderation_expires_at > now())
  );
END;
$$;