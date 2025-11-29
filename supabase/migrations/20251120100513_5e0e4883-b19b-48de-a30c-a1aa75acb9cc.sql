-- Add reattempt settings to assessments table
ALTER TABLE assessments 
ADD COLUMN allow_reattempts boolean DEFAULT false,
ADD COLUMN reattempt_scoring_method text DEFAULT 'best_score';

-- Add comment for clarity
COMMENT ON COLUMN assessments.reattempt_scoring_method IS 'Options: best_score, latest_score, average_score';