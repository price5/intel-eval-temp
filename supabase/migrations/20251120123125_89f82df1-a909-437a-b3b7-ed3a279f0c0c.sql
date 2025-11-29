-- Update RLS policies to respect moderation status

-- Update chat_messages INSERT policy to block suspended and banned users
DROP POLICY IF EXISTS "Authenticated users can send messages" ON public.chat_messages;

CREATE POLICY "Authenticated users can send messages"
ON public.chat_messages
FOR INSERT
WITH CHECK (
  auth.uid() = user_id AND
  EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = auth.uid()
    AND (is_suspended = false OR is_suspended IS NULL)
    AND (is_banned = false OR is_banned IS NULL)
  )
);

-- Update assessment_submissions INSERT policy
DROP POLICY IF EXISTS "Students can manage their own submissions" ON public.assessment_submissions;

CREATE POLICY "Students can view their own submissions"
ON public.assessment_submissions
FOR SELECT
USING (student_id = auth.uid());

CREATE POLICY "Students can insert submissions if not moderated"
ON public.assessment_submissions
FOR INSERT
WITH CHECK (
  student_id = auth.uid() AND
  EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = auth.uid()
    AND (is_suspended = false OR is_suspended IS NULL)
    AND (is_banned = false OR is_banned IS NULL)
  )
);

CREATE POLICY "Students can update their own submissions"
ON public.assessment_submissions
FOR UPDATE
USING (student_id = auth.uid());

-- Update practice_sessions INSERT policy
DROP POLICY IF EXISTS "Students can manage their own practice sessions" ON public.practice_sessions;

CREATE POLICY "Students can view their own practice sessions"
ON public.practice_sessions
FOR SELECT
USING (student_id = auth.uid());

CREATE POLICY "Students can insert practice sessions if not moderated"
ON public.practice_sessions
FOR INSERT
WITH CHECK (
  student_id = auth.uid() AND
  EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = auth.uid()
    AND (is_suspended = false OR is_suspended IS NULL)
    AND (is_banned = false OR is_banned IS NULL)
  )
);

CREATE POLICY "Students can update their own practice sessions"
ON public.practice_sessions
FOR UPDATE
USING (student_id = auth.uid());

-- Update practice_problem_submissions policies
DROP POLICY IF EXISTS "Students can manage their own problem submissions" ON public.practice_problem_submissions;

CREATE POLICY "Students can view their own problem submissions"
ON public.practice_problem_submissions
FOR SELECT
USING (student_id = auth.uid());

CREATE POLICY "Students can insert problem submissions if not moderated"
ON public.practice_problem_submissions
FOR INSERT
WITH CHECK (
  student_id = auth.uid() AND
  EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = auth.uid()
    AND (is_suspended = false OR is_suspended IS NULL)
    AND (is_banned = false OR is_banned IS NULL)
  )
);

CREATE POLICY "Students can update their own problem submissions"
ON public.practice_problem_submissions
FOR UPDATE
USING (student_id = auth.uid());

-- Update direct_messages INSERT policy
DROP POLICY IF EXISTS "Users can send direct messages" ON public.direct_messages;

CREATE POLICY "Users can send direct messages if not moderated"
ON public.direct_messages
FOR INSERT
WITH CHECK (
  auth.uid() = sender_id AND
  EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = auth.uid()
    AND (is_suspended = false OR is_suspended IS NULL)
    AND (is_banned = false OR is_banned IS NULL)
  )
);