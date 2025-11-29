-- Add mentions column to chat_messages for @mention tracking
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS mentions text[] DEFAULT '{}';

-- Update RLS policy to allow admins to delete any message
DROP POLICY IF EXISTS "Users can delete their own messages" ON chat_messages;

CREATE POLICY "Users can delete their own messages or admins can delete any"
ON chat_messages
FOR DELETE
USING (
  auth.uid() = user_id 
  OR 
  has_role(auth.uid(), 'admin'::app_role)
);

-- Update the policy for updating messages to allow admins as well
DROP POLICY IF EXISTS "Users can update their own messages" ON chat_messages;

CREATE POLICY "Users can update their own messages or admins can update any"
ON chat_messages
FOR UPDATE
USING (
  auth.uid() = user_id 
  OR 
  has_role(auth.uid(), 'admin'::app_role)
)
WITH CHECK (
  auth.uid() = user_id 
  OR 
  has_role(auth.uid(), 'admin'::app_role)
);