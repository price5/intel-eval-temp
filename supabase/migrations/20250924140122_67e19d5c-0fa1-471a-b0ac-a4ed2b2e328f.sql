-- Add anti-cheat tracking to assessment_submissions table
ALTER TABLE public.assessment_submissions 
ADD COLUMN tab_switch_count integer DEFAULT 0,
ADD COLUMN suspicious_activity jsonb DEFAULT '[]'::jsonb;