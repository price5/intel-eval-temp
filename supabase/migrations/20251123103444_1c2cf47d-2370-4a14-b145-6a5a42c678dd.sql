-- Enable realtime for weekly league tables
ALTER TABLE weekly_leagues REPLICA IDENTITY FULL;
ALTER TABLE league_memberships REPLICA IDENTITY FULL;
ALTER TABLE xp_transactions REPLICA IDENTITY FULL;
ALTER TABLE user_xp_boosters REPLICA IDENTITY FULL;

-- Add tables to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE weekly_leagues;
ALTER PUBLICATION supabase_realtime ADD TABLE league_memberships;
ALTER PUBLICATION supabase_realtime ADD TABLE xp_transactions;
ALTER PUBLICATION supabase_realtime ADD TABLE user_xp_boosters;