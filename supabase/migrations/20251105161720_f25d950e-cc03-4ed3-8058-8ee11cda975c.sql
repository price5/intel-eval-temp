-- Add pinning functionality to chat_messages
ALTER TABLE chat_messages 
ADD COLUMN is_pinned boolean DEFAULT false,
ADD COLUMN pinned_at timestamp with time zone,
ADD COLUMN pinned_by uuid REFERENCES auth.users(id);

-- Create index for faster pinned message queries
CREATE INDEX idx_chat_messages_pinned ON chat_messages(channel_id, is_pinned, pinned_at DESC) WHERE is_pinned = true;