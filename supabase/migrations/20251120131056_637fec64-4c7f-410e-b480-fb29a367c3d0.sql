-- Allow users to see their own moderation status
-- Update the existing "Users can view all profiles" policy to ensure it includes moderation fields

DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;

CREATE POLICY "Users can view all profiles including moderation status"
ON public.profiles
FOR SELECT
USING (true);

-- Ensure the policy allows reading all columns including moderation fields
COMMENT ON POLICY "Users can view all profiles including moderation status" ON public.profiles 
IS 'Allows all authenticated users to view profile information including moderation status';