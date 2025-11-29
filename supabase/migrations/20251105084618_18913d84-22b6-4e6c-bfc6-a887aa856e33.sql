-- Add permissions column to chat_categories
ALTER TABLE chat_categories
ADD COLUMN IF NOT EXISTS permissions JSONB DEFAULT '[]'::jsonb;

-- Add permissions column to chat_channels
ALTER TABLE chat_channels
ADD COLUMN IF NOT EXISTS permissions JSONB DEFAULT '[]'::jsonb;

-- Create function to check channel view permission
CREATE OR REPLACE FUNCTION public.can_view_channel(
  _user_id uuid,
  _channel_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  channel_permissions jsonb;
  category_permissions jsonb;
  _category_id uuid;
  permission_entry jsonb;
  user_roles text[];
BEGIN
  -- Get channel and category
  SELECT category_id, permissions INTO _category_id, channel_permissions
  FROM chat_channels
  WHERE id = _channel_id;
  
  -- Get category permissions
  SELECT permissions INTO category_permissions
  FROM chat_categories
  WHERE id = _category_id;
  
  -- Get user roles
  SELECT ARRAY_AGG(role::text) INTO user_roles
  FROM user_roles
  WHERE user_id = _user_id;
  
  -- If no permissions set, allow everyone
  IF channel_permissions = '[]'::jsonb AND category_permissions = '[]'::jsonb THEN
    RETURN true;
  END IF;
  
  -- Check channel permissions first
  IF channel_permissions != '[]'::jsonb THEN
    FOR permission_entry IN SELECT * FROM jsonb_array_elements(channel_permissions)
    LOOP
      -- Check if this is a view permission
      IF (permission_entry->>'view')::boolean = true THEN
        -- Check user-based permission
        IF permission_entry->>'type' = 'user' AND permission_entry->>'targetId' = _user_id::text THEN
          RETURN true;
        END IF;
        
        -- Check role-based permission
        IF permission_entry->>'type' = 'role' AND user_roles @> ARRAY[permission_entry->>'targetId'] THEN
          RETURN true;
        END IF;
      END IF;
    END LOOP;
    
    -- If channel has permissions but user doesn't match, deny
    RETURN false;
  END IF;
  
  -- Check category permissions (inheritance)
  IF category_permissions != '[]'::jsonb THEN
    FOR permission_entry IN SELECT * FROM jsonb_array_elements(category_permissions)
    LOOP
      IF (permission_entry->>'view')::boolean = true THEN
        IF permission_entry->>'type' = 'user' AND permission_entry->>'targetId' = _user_id::text THEN
          RETURN true;
        END IF;
        
        IF permission_entry->>'type' = 'role' AND user_roles @> ARRAY[permission_entry->>'targetId'] THEN
          RETURN true;
        END IF;
      END IF;
    END LOOP;
    
    RETURN false;
  END IF;
  
  -- Default allow
  RETURN true;
END;
$$;

-- Create function to check channel send permission
CREATE OR REPLACE FUNCTION public.can_send_message(
  _user_id uuid,
  _channel_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  channel_permissions jsonb;
  category_permissions jsonb;
  _category_id uuid;
  permission_entry jsonb;
  user_roles text[];
BEGIN
  -- Get channel and category
  SELECT category_id, permissions INTO _category_id, channel_permissions
  FROM chat_channels
  WHERE id = _channel_id;
  
  -- Get category permissions
  SELECT permissions INTO category_permissions
  FROM chat_categories
  WHERE id = _category_id;
  
  -- Get user roles
  SELECT ARRAY_AGG(role::text) INTO user_roles
  FROM user_roles
  WHERE user_id = _user_id;
  
  -- If no permissions set, allow everyone
  IF channel_permissions = '[]'::jsonb AND category_permissions = '[]'::jsonb THEN
    RETURN true;
  END IF;
  
  -- Check channel permissions first
  IF channel_permissions != '[]'::jsonb THEN
    FOR permission_entry IN SELECT * FROM jsonb_array_elements(channel_permissions)
    LOOP
      IF (permission_entry->>'send')::boolean = true THEN
        IF permission_entry->>'type' = 'user' AND permission_entry->>'targetId' = _user_id::text THEN
          RETURN true;
        END IF;
        
        IF permission_entry->>'type' = 'role' AND user_roles @> ARRAY[permission_entry->>'targetId'] THEN
          RETURN true;
        END IF;
      END IF;
    END LOOP;
    
    RETURN false;
  END IF;
  
  -- Check category permissions
  IF category_permissions != '[]'::jsonb THEN
    FOR permission_entry IN SELECT * FROM jsonb_array_elements(category_permissions)
    LOOP
      IF (permission_entry->>'send')::boolean = true THEN
        IF permission_entry->>'type' = 'user' AND permission_entry->>'targetId' = _user_id::text THEN
          RETURN true;
        END IF;
        
        IF permission_entry->>'type' = 'role' AND user_roles @> ARRAY[permission_entry->>'targetId'] THEN
          RETURN true;
        END IF;
      END IF;
    END LOOP;
    
    RETURN false;
  END IF;
  
  RETURN true;
END;
$$;