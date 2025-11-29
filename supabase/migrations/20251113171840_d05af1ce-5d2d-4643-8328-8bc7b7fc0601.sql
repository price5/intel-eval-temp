-- Create table for bookmarked messages
CREATE TABLE IF NOT EXISTS public.bookmarked_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  message_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  notes TEXT,
  CONSTRAINT bookmarked_messages_user_message_unique UNIQUE (user_id, message_id)
);

-- Enable RLS
ALTER TABLE public.bookmarked_messages ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Users can view their own bookmarks"
  ON public.bookmarked_messages
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own bookmarks"
  ON public.bookmarked_messages
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own bookmarks"
  ON public.bookmarked_messages
  FOR DELETE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own bookmarks"
  ON public.bookmarked_messages
  FOR UPDATE
  USING (auth.uid() = user_id);

-- Create index for faster lookups
CREATE INDEX idx_bookmarked_messages_user_id ON public.bookmarked_messages(user_id);
CREATE INDEX idx_bookmarked_messages_message_id ON public.bookmarked_messages(message_id);

-- Add comment
COMMENT ON TABLE public.bookmarked_messages IS 'Stores user bookmarks for chat messages';

-- Create table for bookmarked direct messages
CREATE TABLE IF NOT EXISTS public.bookmarked_direct_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  message_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  notes TEXT,
  CONSTRAINT bookmarked_direct_messages_user_message_unique UNIQUE (user_id, message_id)
);

-- Enable RLS
ALTER TABLE public.bookmarked_direct_messages ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Users can view their own DM bookmarks"
  ON public.bookmarked_direct_messages
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own DM bookmarks"
  ON public.bookmarked_direct_messages
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own DM bookmarks"
  ON public.bookmarked_direct_messages
  FOR DELETE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own DM bookmarks"
  ON public.bookmarked_direct_messages
  FOR UPDATE
  USING (auth.uid() = user_id);

-- Create index for faster lookups
CREATE INDEX idx_bookmarked_direct_messages_user_id ON public.bookmarked_direct_messages(user_id);
CREATE INDEX idx_bookmarked_direct_messages_message_id ON public.bookmarked_direct_messages(message_id);