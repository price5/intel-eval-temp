-- Add code and explanation weight columns to assessments table
ALTER TABLE assessments 
ADD COLUMN code_weight INTEGER DEFAULT 70 CHECK (code_weight >= 0 AND code_weight <= 100),
ADD COLUMN explanation_weight INTEGER DEFAULT 30 CHECK (explanation_weight >= 0 AND explanation_weight <= 100);

-- Add constraint to ensure weights sum to 100
ALTER TABLE assessments 
ADD CONSTRAINT check_weights_sum_100 CHECK (code_weight + explanation_weight = 100);

-- Update existing assessments with default weights
UPDATE assessments 
SET code_weight = 70, explanation_weight = 30
WHERE code_weight IS NULL OR explanation_weight IS NULL;