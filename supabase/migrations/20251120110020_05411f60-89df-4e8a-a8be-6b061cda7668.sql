-- Create feedback_votes table
CREATE TABLE IF NOT EXISTS public.feedback_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feedback_id UUID NOT NULL REFERENCES public.feedback(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(feedback_id, user_id)
);

-- Enable RLS
ALTER TABLE public.feedback_votes ENABLE ROW LEVEL SECURITY;

-- Users can vote on feedback
CREATE POLICY "Users can vote on feedback"
  ON public.feedback_votes
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Users can view all votes
CREATE POLICY "Users can view all votes"
  ON public.feedback_votes
  FOR SELECT
  USING (true);

-- Users can delete their own votes
CREATE POLICY "Users can delete their own votes"
  ON public.feedback_votes
  FOR DELETE
  USING (auth.uid() = user_id);

-- Add vote_count column to feedback table
ALTER TABLE public.feedback
ADD COLUMN IF NOT EXISTS vote_count INTEGER NOT NULL DEFAULT 0;

-- Create function to update vote count
CREATE OR REPLACE FUNCTION public.update_feedback_vote_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE feedback
    SET vote_count = vote_count + 1
    WHERE id = NEW.feedback_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE feedback
    SET vote_count = GREATEST(0, vote_count - 1)
    WHERE id = OLD.feedback_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

-- Create trigger to automatically update vote counts
CREATE TRIGGER update_feedback_vote_count_trigger
AFTER INSERT OR DELETE ON public.feedback_votes
FOR EACH ROW
EXECUTE FUNCTION public.update_feedback_vote_count();