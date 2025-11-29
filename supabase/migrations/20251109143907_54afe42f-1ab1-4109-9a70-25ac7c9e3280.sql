-- Add parent_id column to direct_messages for replies
ALTER TABLE direct_messages 
ADD COLUMN parent_id uuid REFERENCES direct_messages(id) ON DELETE SET NULL;

-- Create index for better performance on parent lookups
CREATE INDEX idx_direct_messages_parent_id ON direct_messages(parent_id);

-- Create direct_message_reactions table
CREATE TABLE direct_message_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  direct_message_id uuid NOT NULL REFERENCES direct_messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  emoji text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(direct_message_id, user_id, emoji)
);

-- Create index for better performance
CREATE INDEX idx_dm_reactions_message_id ON direct_message_reactions(direct_message_id);
CREATE INDEX idx_dm_reactions_user_id ON direct_message_reactions(user_id);

-- Enable RLS on direct_message_reactions
ALTER TABLE direct_message_reactions ENABLE ROW LEVEL SECURITY;

-- RLS Policies for direct_message_reactions
CREATE POLICY "Users can view reactions on their DMs"
  ON direct_message_reactions
  FOR SELECT
  USING (
    direct_message_id IN (
      SELECT id FROM direct_messages 
      WHERE sender_id = auth.uid() OR recipient_id = auth.uid()
    )
  );

CREATE POLICY "Users can add reactions to DMs they're part of"
  ON direct_message_reactions
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id AND
    direct_message_id IN (
      SELECT id FROM direct_messages 
      WHERE sender_id = auth.uid() OR recipient_id = auth.uid()
    )
  );

CREATE POLICY "Users can delete their own reactions"
  ON direct_message_reactions
  FOR DELETE
  USING (auth.uid() = user_id);

-- Enable realtime for direct_message_reactions
ALTER TABLE direct_message_reactions REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE direct_message_reactions;