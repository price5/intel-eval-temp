-- Create app_role enum for system roles
CREATE TYPE public.app_role AS ENUM ('admin', 'moderator', 'user');

-- Create user_roles table for role-based access control
CREATE TABLE public.user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    role app_role NOT NULL,
    assigned_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    assigned_by UUID REFERENCES auth.users(id),
    UNIQUE (user_id, role)
);

-- Enable RLS on user_roles
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Create security definer function to check roles
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = _role
  )
$$;

-- RLS policies for user_roles
CREATE POLICY "Everyone can view roles"
ON public.user_roles
FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Admins can manage roles"
ON public.user_roles
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Update chat_channels RLS to allow admin management
DROP POLICY IF EXISTS "Anyone can view chat channels" ON public.chat_channels;

CREATE POLICY "Everyone can view channels"
ON public.chat_channels
FOR SELECT
USING (true);

CREATE POLICY "Admins can manage channels"
ON public.chat_channels
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Update chat_categories RLS similarly
DROP POLICY IF EXISTS "Anyone can view chat categories" ON public.chat_categories;

CREATE POLICY "Everyone can view categories"
ON public.chat_categories
FOR SELECT
USING (true);

CREATE POLICY "Admins can manage categories"
ON public.chat_categories
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Assign admin role to varundotexe
INSERT INTO public.user_roles (user_id, role)
SELECT p.user_id, 'admin'::app_role
FROM public.profiles p
WHERE p.username = 'varundotexe'
ON CONFLICT (user_id, role) DO NOTHING;