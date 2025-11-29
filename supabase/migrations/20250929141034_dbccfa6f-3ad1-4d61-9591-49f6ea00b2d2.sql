-- Create assessment_sessions table for session management and device locking
CREATE TABLE IF NOT EXISTS public.assessment_sessions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  assessment_id UUID NOT NULL,
  device_info TEXT NOT NULL,
  ip_address TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  ended_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create assessment_security_events table for tracking security violations
CREATE TABLE IF NOT EXISTS public.assessment_security_events (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES public.assessment_sessions(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  event_data JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE public.assessment_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_security_events ENABLE ROW LEVEL SECURITY;

-- Create policies for assessment_sessions
CREATE POLICY "Users can view their own assessment sessions" 
ON public.assessment_sessions 
FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own assessment sessions" 
ON public.assessment_sessions 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own assessment sessions" 
ON public.assessment_sessions 
FOR UPDATE 
USING (auth.uid() = user_id);

-- Create policies for assessment_security_events  
CREATE POLICY "Users can view security events for their sessions" 
ON public.assessment_security_events 
FOR SELECT 
USING (
  session_id IN (
    SELECT id FROM public.assessment_sessions 
    WHERE user_id = auth.uid()
  )
);

CREATE POLICY "Users can create security events for their sessions" 
ON public.assessment_security_events 
FOR INSERT 
WITH CHECK (
  session_id IN (
    SELECT id FROM public.assessment_sessions 
    WHERE user_id = auth.uid()
  )
);

-- Create indexes for better performance
CREATE INDEX idx_assessment_sessions_user_id ON public.assessment_sessions(user_id);
CREATE INDEX idx_assessment_sessions_assessment_id ON public.assessment_sessions(assessment_id);
CREATE INDEX idx_assessment_sessions_active ON public.assessment_sessions(is_active) WHERE is_active = true;
CREATE INDEX idx_assessment_security_events_session_id ON public.assessment_security_events(session_id);

-- Add trigger for automatic timestamp updates on assessment_sessions
CREATE TRIGGER update_assessment_sessions_updated_at
BEFORE UPDATE ON public.assessment_sessions
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();