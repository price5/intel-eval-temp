-- Create feedback_comments table
CREATE TABLE IF NOT EXISTS public.feedback_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feedback_id UUID NOT NULL REFERENCES public.feedback(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  comment TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.feedback_comments ENABLE ROW LEVEL SECURITY;

-- Users can create comments
CREATE POLICY "Users can create comments"
  ON public.feedback_comments
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Everyone can view comments
CREATE POLICY "Everyone can view comments"
  ON public.feedback_comments
  FOR SELECT
  USING (true);

-- Users can update their own comments
CREATE POLICY "Users can update their own comments"
  ON public.feedback_comments
  FOR UPDATE
  USING (auth.uid() = user_id);

-- Users can delete their own comments
CREATE POLICY "Users can delete their own comments"
  ON public.feedback_comments
  FOR DELETE
  USING (auth.uid() = user_id);

-- Add updated_at trigger
CREATE TRIGGER update_feedback_comments_updated_at
  BEFORE UPDATE ON public.feedback_comments
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Add comment_count to feedback table
ALTER TABLE public.feedback
ADD COLUMN IF NOT EXISTS comment_count INTEGER NOT NULL DEFAULT 0;

-- Create function to update comment count
CREATE OR REPLACE FUNCTION public.update_feedback_comment_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE feedback
    SET comment_count = comment_count + 1
    WHERE id = NEW.feedback_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE feedback
    SET comment_count = GREATEST(0, comment_count - 1)
    WHERE id = OLD.feedback_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

-- Create trigger to automatically update comment counts
CREATE TRIGGER update_feedback_comment_count_trigger
AFTER INSERT OR DELETE ON public.feedback_comments
FOR EACH ROW
EXECUTE FUNCTION public.update_feedback_comment_count();

-- Enable realtime for comments
ALTER TABLE public.feedback_comments REPLICA IDENTITY FULL;