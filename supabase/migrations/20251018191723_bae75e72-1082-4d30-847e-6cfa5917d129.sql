-- Add chat_messages to supabase_realtime publication for real-time updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;