-- Add batching support to notifications table
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS batch_count integer DEFAULT 1;
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS batch_items jsonb DEFAULT '[]'::jsonb;

-- Update the create_notification function to support batching
CREATE OR REPLACE FUNCTION public.create_notification(
  p_user_id uuid, 
  p_type notification_type, 
  p_title text, 
  p_message text, 
  p_link text DEFAULT NULL::text, 
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  notification_enabled BOOLEAN;
  new_notification_id UUID;
  existing_notification RECORD;
  batching_window INTERVAL := INTERVAL '5 minutes';
  batch_key TEXT;
BEGIN
  -- Check if user has this notification type enabled
  EXECUTE format('SELECT COALESCE(%I, true) FROM notification_preferences WHERE user_id = $1', p_type)
  INTO notification_enabled
  USING p_user_id;
  
  -- If preference not found, default to enabled
  IF notification_enabled IS NULL THEN
    notification_enabled := true;
  END IF;
  
  -- Only create/update notification if enabled
  IF notification_enabled THEN
    -- Create a batch key based on type and source identifier from metadata
    batch_key := p_type::text || '_' || COALESCE(p_metadata->>'source_id', '');
    
    -- Check for existing notification within batching window
    SELECT * INTO existing_notification
    FROM notifications
    WHERE user_id = p_user_id
      AND type = p_type
      AND is_read = false
      AND created_at > (now() - batching_window)
      AND (
        -- Batch messages from the same user
        (p_type IN ('message_mention', 'message_reply', 'direct_message') 
         AND metadata->>'source_id' = p_metadata->>'source_id')
        OR
        -- Batch achievements
        (p_type = 'achievement_unlocked')
        OR
        -- Batch rank changes
        (p_type = 'rank_change')
        OR
        -- Batch assessment deadlines
        (p_type = 'assessment_deadline')
      )
    ORDER BY created_at DESC
    LIMIT 1;
    
    IF existing_notification.id IS NOT NULL THEN
      -- Update existing notification with batched info
      UPDATE notifications
      SET 
        batch_count = batch_count + 1,
        batch_items = batch_items || jsonb_build_object(
          'timestamp', now(),
          'message', p_message,
          'metadata', p_metadata
        ),
        created_at = now(), -- Update timestamp to keep it at top
        metadata = p_metadata -- Update with latest metadata
      WHERE id = existing_notification.id;
      
      -- Update message to reflect batch count
      IF p_type IN ('message_mention', 'message_reply', 'direct_message') THEN
        UPDATE notifications
        SET 
          title = p_title,
          message = format('%s new messages from %s', 
                          batch_count, 
                          p_metadata->>'source_name')
        WHERE id = existing_notification.id;
      ELSIF p_type = 'achievement_unlocked' THEN
        UPDATE notifications
        SET 
          title = 'Achievements Unlocked!',
          message = format('You unlocked %s new achievements', batch_count)
        WHERE id = existing_notification.id;
      ELSIF p_type = 'rank_change' THEN
        UPDATE notifications
        SET 
          title = 'Rank Improved!',
          message = format('Your rank improved %s times', batch_count)
        WHERE id = existing_notification.id;
      END IF;
      
      RETURN existing_notification.id;
    ELSE
      -- Create new notification
      INSERT INTO notifications (
        user_id, 
        type, 
        title, 
        message, 
        link, 
        metadata,
        batch_count,
        batch_items
      )
      VALUES (
        p_user_id, 
        p_type, 
        p_title, 
        p_message, 
        p_link, 
        p_metadata,
        1,
        jsonb_build_array(jsonb_build_object(
          'timestamp', now(),
          'message', p_message,
          'metadata', p_metadata
        ))
      )
      RETURNING id INTO new_notification_id;
      
      RETURN new_notification_id;
    END IF;
  END IF;
  
  RETURN NULL;
END;
$function$;

-- Update trigger functions to include source information in metadata

-- Update message mention trigger
CREATE OR REPLACE FUNCTION public.notify_message_mention()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
          jsonb_build_object(
            'message_id', NEW.id, 
            'channel_id', NEW.channel_id, 
            'sender_id', NEW.user_id,
            'source_id', NEW.user_id,
            'source_name', sender_username
          )
        );
      END IF;
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Update direct message trigger
CREATE OR REPLACE FUNCTION public.notify_direct_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    jsonb_build_object(
      'message_id', NEW.id, 
      'sender_id', NEW.sender_id,
      'source_id', NEW.sender_id,
      'source_name', sender_username
    )
  );
  
  RETURN NEW;
END;
$function$;

-- Update message reply trigger
CREATE OR REPLACE FUNCTION public.notify_message_reply()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
        jsonb_build_object(
          'message_id', NEW.id, 
          'channel_id', NEW.channel_id, 
          'parent_id', NEW.parent_id,
          'source_id', NEW.user_id,
          'source_name', replier_username
        )
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;