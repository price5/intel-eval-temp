-- Add is_edited and edited_at to direct_messages table
ALTER TABLE direct_messages
ADD COLUMN IF NOT EXISTS is_edited BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP WITH TIME ZONE;

-- Add is_forwarded to chat_messages table
ALTER TABLE chat_messages
ADD COLUMN IF NOT EXISTS is_forwarded BOOLEAN DEFAULT false;

-- Add is_forwarded to direct_messages table
ALTER TABLE direct_messages
ADD COLUMN IF NOT EXISTS is_forwarded BOOLEAN DEFAULT false;