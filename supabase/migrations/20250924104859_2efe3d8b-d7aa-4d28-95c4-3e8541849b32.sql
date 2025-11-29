-- Create user role enum
CREATE TYPE public.user_role AS ENUM ('student', 'instructor');

-- Create college enum (expandable)
CREATE TYPE public.college AS ENUM ('New Horizon College of Engineering');

-- Create profiles table
CREATE TABLE public.profiles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  username TEXT NOT NULL UNIQUE,
  college college NOT NULL,
  usn TEXT NOT NULL,
  role user_role NOT NULL,
  bio TEXT,
  avatar_url TEXT,
  last_username_change TIMESTAMP WITH TIME ZONE DEFAULT now(),
  streak_count INTEGER DEFAULT 0,
  last_login_date DATE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Users can view all profiles" 
ON public.profiles 
FOR SELECT 
USING (true);

CREATE POLICY "Users can update their own profile" 
ON public.profiles 
FOR UPDATE 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own profile" 
ON public.profiles 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);

-- Create function to update timestamps
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

-- Create trigger for automatic timestamp updates
CREATE TRIGGER update_profiles_updated_at
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Create function to handle new user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (
    user_id, 
    full_name, 
    username, 
    college, 
    usn, 
    role
  )
  VALUES (
    NEW.id,
    NEW.raw_user_meta_data ->> 'full_name',
    NEW.raw_user_meta_data ->> 'username',
    (NEW.raw_user_meta_data ->> 'college')::college,
    NEW.raw_user_meta_data ->> 'usn',
    (NEW.raw_user_meta_data ->> 'role')::user_role
  );
  RETURN NEW;
END;
$$;

-- Create trigger for new user signup
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Create username validation function
CREATE OR REPLACE FUNCTION public.is_username_available(username_to_check TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN NOT EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE username = username_to_check
  );
END;
$$;

-- Create function to suggest usernames
CREATE OR REPLACE FUNCTION public.suggest_usernames(base_username TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  suggestions TEXT[] := '{}';
  counter INTEGER := 1;
  candidate TEXT;
BEGIN
  -- Generate 3 username suggestions
  WHILE array_length(suggestions, 1) < 3 AND counter <= 100 LOOP
    candidate := base_username || counter::TEXT;
    IF public.is_username_available(candidate) THEN
      suggestions := array_append(suggestions, candidate);
    END IF;
    counter := counter + 1;
  END LOOP;
  
  -- If we still don't have 3, add some with random suffixes
  WHILE array_length(suggestions, 1) < 3 LOOP
    candidate := base_username || '_' || floor(random() * 1000)::TEXT;
    IF public.is_username_available(candidate) AND candidate != ALL(suggestions) THEN
      suggestions := array_append(suggestions, candidate);
    END IF;
  END LOOP;
  
  RETURN suggestions;
END;
$$;