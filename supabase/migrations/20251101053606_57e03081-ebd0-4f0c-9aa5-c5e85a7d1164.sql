-- Add code_heatmap and explanation_heatmap columns to assessment_submissions
ALTER TABLE assessment_submissions 
ADD COLUMN IF NOT EXISTS code_heatmap JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS explanation_heatmap JSONB DEFAULT '[]'::jsonb;