-- Create message_reactions table
CREATE TABLE public.message_reactions (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  emoji text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT unique_user_message_emoji UNIQUE (message_id, user_id, emoji)
);

-- Enable RLS
ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Anyone can view reactions"
  ON public.message_reactions
  FOR SELECT
  USING (true);

CREATE POLICY "Authenticated users can add reactions"
  ON public.message_reactions
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own reactions"
  ON public.message_reactions
  FOR DELETE
  USING (auth.uid() = user_id);

-- Index for performance
CREATE INDEX idx_message_reactions_message_id ON public.message_reactions(message_id);
CREATE INDEX idx_message_reactions_user_id ON public.message_reactions(user_id);

-- Function to get user's most used emojis
CREATE OR REPLACE FUNCTION public.get_user_top_emojis(user_id_param uuid, limit_count integer DEFAULT 3)
RETURNS TABLE(emoji text, count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT emoji, COUNT(*) as count
  FROM public.message_reactions
  WHERE user_id = user_id_param
  GROUP BY emoji
  ORDER BY count DESC, emoji ASC
  LIMIT limit_count;
$$;