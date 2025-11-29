-- Add reply threading and edit tracking to chat_messages
ALTER TABLE chat_messages 
ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES chat_messages(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS is_edited BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

-- Create index for parent_id lookups
CREATE INDEX IF NOT EXISTS idx_chat_messages_parent_id ON chat_messages(parent_id);

-- Update RLS policies to allow users to edit their own messages
CREATE POLICY "Users can update their own messages"
ON chat_messages
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);