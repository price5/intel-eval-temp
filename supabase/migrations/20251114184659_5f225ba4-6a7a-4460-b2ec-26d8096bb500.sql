-- Add foreign key constraints for bookmarked_messages
ALTER TABLE public.bookmarked_messages
ADD CONSTRAINT bookmarked_messages_message_id_fkey
FOREIGN KEY (message_id)
REFERENCES public.chat_messages(id)
ON DELETE CASCADE;

-- Add foreign key constraints for bookmarked_direct_messages
ALTER TABLE public.bookmarked_direct_messages
ADD CONSTRAINT bookmarked_direct_messages_message_id_fkey
FOREIGN KEY (message_id)
REFERENCES public.direct_messages(id)
ON DELETE CASCADE;