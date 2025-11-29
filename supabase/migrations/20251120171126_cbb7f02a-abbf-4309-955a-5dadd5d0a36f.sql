-- Helper function to create a notification if user has it enabled in preferences
CREATE OR REPLACE FUNCTION create_notification(
  p_user_id UUID,
  p_type notification_type,
  p_title TEXT,
  p_message TEXT,
  p_link TEXT DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  notification_enabled BOOLEAN;
  new_notification_id UUID;
BEGIN
  -- Check if user has this notification type enabled
  EXECUTE format('SELECT COALESCE(%I, true) FROM notification_preferences WHERE user_id = $1', p_type)
  INTO notification_enabled
  USING p_user_id;
  
  -- If preference not found, default to enabled
  IF notification_enabled IS NULL THEN
    notification_enabled := true;
  END IF;
  
  -- Only create notification if enabled
  IF notification_enabled THEN
    INSERT INTO notifications (user_id, type, title, message, link, metadata)
    VALUES (p_user_id, p_type, p_title, p_message, p_link, p_metadata)
    RETURNING id INTO new_notification_id;
    
    RETURN new_notification_id;
  END IF;
  
  RETURN NULL;
END;
$$;

-- Trigger function for assessment graded notifications
CREATE OR REPLACE FUNCTION notify_assessment_graded()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  assessment_title TEXT;
BEGIN
  -- Only notify when status changes to 'completed'
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    -- Get assessment title
    SELECT title INTO assessment_title FROM assessments WHERE id = NEW.assessment_id;
    
    -- Create notification
    PERFORM create_notification(
      NEW.student_id,
      'assessment_graded'::notification_type,
      'Assessment Graded',
      format('Your assessment "%s" has been graded. Score: %s%%', assessment_title, NEW.overall_score),
      '/dashboard?tab=assessment&view=history',
      jsonb_build_object('assessment_id', NEW.assessment_id, 'score', NEW.overall_score)
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Trigger function for achievement unlocked notifications
CREATE OR REPLACE FUNCTION notify_achievement_unlocked()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  achievement_name TEXT;
  achievement_points INTEGER;
BEGIN
  -- Get achievement details
  SELECT name, points INTO achievement_name, achievement_points
  FROM achievements WHERE id = NEW.achievement_id;
  
  -- Create notification
  PERFORM create_notification(
    NEW.user_id,
    'achievement_unlocked'::notification_type,
    'Achievement Unlocked!',
    format('You unlocked "%s" (+%s points)', achievement_name, achievement_points),
    '/settings?section=achievements',
    jsonb_build_object('achievement_id', NEW.achievement_id, 'points', achievement_points)
  );
  
  RETURN NEW;
END;
$$;

-- Trigger function for rank change notifications
CREATE OR REPLACE FUNCTION notify_rank_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rank_improved BOOLEAN := false;
  notification_message TEXT;
BEGIN
  -- Check if any rank improved
  IF NEW.current_rank_overall < COALESCE(OLD.current_rank_overall, 999999) THEN
    rank_improved := true;
    notification_message := format('You moved up to rank #%s in overall rankings!', NEW.current_rank_overall);
  ELSIF NEW.current_rank_code < COALESCE(OLD.current_rank_code, 999999) THEN
    rank_improved := true;
    notification_message := format('You moved up to rank #%s in code rankings!', NEW.current_rank_code);
  ELSIF NEW.current_rank_explanation < COALESCE(OLD.current_rank_explanation, 999999) THEN
    rank_improved := true;
    notification_message := format('You moved up to rank #%s in explanation rankings!', NEW.current_rank_explanation);
  END IF;
  
  -- Only notify if rank improved
  IF rank_improved THEN
    PERFORM create_notification(
      NEW.user_id,
      'rank_change'::notification_type,
      'Rank Improved!',
      notification_message,
      '/dashboard?tab=leaderboard',
      jsonb_build_object('overall_rank', NEW.current_rank_overall, 'code_rank', NEW.current_rank_code, 'explanation_rank', NEW.current_rank_explanation)
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Trigger function for message mentions
CREATE OR REPLACE FUNCTION notify_message_mention()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  mentioned_user_id UUID;
  sender_username TEXT;
  channel_name TEXT;
BEGIN
  -- Get sender username
  SELECT username INTO sender_username FROM profiles WHERE user_id = NEW.user_id;
  
  -- Get channel name
  SELECT name INTO channel_name FROM chat_channels WHERE id = NEW.channel_id;
  
  -- Notify each mentioned user
  IF NEW.mentions IS NOT NULL AND array_length(NEW.mentions, 1) > 0 THEN
    FOREACH mentioned_user_id IN ARRAY NEW.mentions::UUID[]
    LOOP
      -- Don't notify the sender
      IF mentioned_user_id != NEW.user_id THEN
        PERFORM create_notification(
          mentioned_user_id,
          'message_mention'::notification_type,
          'You were mentioned',
          format('%s mentioned you in #%s', sender_username, channel_name),
          '/community',
          jsonb_build_object('message_id', NEW.id, 'channel_id', NEW.channel_id, 'sender_id', NEW.user_id)
        );
      END IF;
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Trigger function for message replies
CREATE OR REPLACE FUNCTION notify_message_reply()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  parent_user_id UUID;
  replier_username TEXT;
  channel_name TEXT;
BEGIN
  -- Only process if this is a reply (has parent_id)
  IF NEW.parent_id IS NOT NULL THEN
    -- Get parent message author
    SELECT user_id INTO parent_user_id FROM chat_messages WHERE id = NEW.parent_id;
    
    -- Don't notify if replying to own message
    IF parent_user_id IS NOT NULL AND parent_user_id != NEW.user_id THEN
      -- Get replier username
      SELECT username INTO replier_username FROM profiles WHERE user_id = NEW.user_id;
      
      -- Get channel name
      SELECT name INTO channel_name FROM chat_channels WHERE id = NEW.channel_id;
      
      -- Create notification
      PERFORM create_notification(
        parent_user_id,
        'message_reply'::notification_type,
        'New Reply',
        format('%s replied to your message in #%s', replier_username, channel_name),
        '/community',
        jsonb_build_object('message_id', NEW.id, 'channel_id', NEW.channel_id, 'parent_id', NEW.parent_id)
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Trigger function for direct messages
CREATE OR REPLACE FUNCTION notify_direct_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sender_username TEXT;
BEGIN
  -- Get sender username
  SELECT username INTO sender_username FROM profiles WHERE user_id = NEW.sender_id;
  
  -- Create notification for recipient
  PERFORM create_notification(
    NEW.recipient_id,
    'direct_message'::notification_type,
    'New Direct Message',
    format('%s sent you a message', sender_username),
    '/community?dm=' || NEW.sender_id::text,
    jsonb_build_object('message_id', NEW.id, 'sender_id', NEW.sender_id)
  );
  
  RETURN NEW;
END;
$$;

-- Trigger function for feedback responses
CREATE OR REPLACE FUNCTION notify_feedback_response()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  feedback_author_id UUID;
  feedback_title TEXT;
BEGIN
  -- Get feedback details
  SELECT user_id, title INTO feedback_author_id, feedback_title
  FROM feedback WHERE id = NEW.feedback_id;
  
  -- Don't notify if commenting on own feedback
  IF feedback_author_id != NEW.user_id THEN
    -- Create notification
    PERFORM create_notification(
      feedback_author_id,
      'feedback_response'::notification_type,
      'New Feedback Comment',
      format('Someone commented on your feedback: "%s"', feedback_title),
      '/settings?section=community-feedback',
      jsonb_build_object('feedback_id', NEW.feedback_id, 'comment_id', NEW.id)
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Create triggers
CREATE TRIGGER assessment_graded_notification
  AFTER INSERT OR UPDATE ON assessment_submissions
  FOR EACH ROW
  EXECUTE FUNCTION notify_assessment_graded();

CREATE TRIGGER achievement_unlocked_notification
  AFTER INSERT ON user_achievements
  FOR EACH ROW
  EXECUTE FUNCTION notify_achievement_unlocked();

CREATE TRIGGER rank_change_notification
  AFTER UPDATE ON user_rankings
  FOR EACH ROW
  EXECUTE FUNCTION notify_rank_change();

CREATE TRIGGER message_mention_notification
  AFTER INSERT ON chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION notify_message_mention();

CREATE TRIGGER message_reply_notification
  AFTER INSERT ON chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION notify_message_reply();

CREATE TRIGGER direct_message_notification
  AFTER INSERT ON direct_messages
  FOR EACH ROW
  EXECUTE FUNCTION notify_direct_message();

CREATE TRIGGER feedback_response_notification
  AFTER INSERT ON feedback_comments
  FOR EACH ROW
  EXECUTE FUNCTION notify_feedback_response();