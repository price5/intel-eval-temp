-- Create chat categories table
CREATE TABLE public.chat_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  display_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create chat channels table
CREATE TABLE public.chat_channels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID REFERENCES public.chat_categories(id) ON DELETE CASCADE NOT NULL,
  name TEXT NOT NULL,
  display_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create chat messages table
CREATE TABLE public.chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID REFERENCES public.chat_channels(id) ON DELETE CASCADE NOT NULL,
  user_id UUID NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.chat_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- RLS Policies for categories (everyone can view)
CREATE POLICY "Anyone can view chat categories"
  ON public.chat_categories
  FOR SELECT
  USING (true);

-- RLS Policies for channels (everyone can view)
CREATE POLICY "Anyone can view chat channels"
  ON public.chat_channels
  FOR SELECT
  USING (true);

-- RLS Policies for messages
CREATE POLICY "Anyone can view messages"
  ON public.chat_messages
  FOR SELECT
  USING (true);

CREATE POLICY "Authenticated users can send messages"
  ON public.chat_messages
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own messages"
  ON public.chat_messages
  FOR DELETE
  USING (auth.uid() = user_id);

-- Create trigger for updated_at
CREATE TRIGGER update_chat_messages_updated_at
  BEFORE UPDATE ON public.chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Insert default category and channel
INSERT INTO public.chat_categories (name, display_order) VALUES ('General', 0);

INSERT INTO public.chat_channels (category_id, name, display_order)
SELECT id, 'General Chat', 0 FROM public.chat_categories WHERE name = 'General';

-- Enable Realtime for messages table
ALTER TABLE public.chat_messages REPLICA IDENTITY FULL;