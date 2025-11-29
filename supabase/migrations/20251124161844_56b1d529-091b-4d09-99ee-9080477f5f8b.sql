-- Create incidents table for status page
CREATE TABLE IF NOT EXISTS public.status_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  status TEXT NOT NULL CHECK (status IN ('investigating', 'identified', 'monitoring', 'resolved')),
  affected_services TEXT[] NOT NULL DEFAULT '{}',
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.status_incidents ENABLE ROW LEVEL SECURITY;

-- Allow everyone to read incidents (public status page)
CREATE POLICY "Anyone can view incidents"
  ON public.status_incidents
  FOR SELECT
  USING (true);

-- Only admins can insert/update incidents
CREATE POLICY "Admins can manage incidents"
  ON public.status_incidents
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM user_roles
      WHERE user_id = auth.uid()
      AND role = 'admin'
    )
  );

-- Create index for faster queries
CREATE INDEX idx_status_incidents_started_at ON public.status_incidents(started_at DESC);

-- Add trigger for updated_at
CREATE TRIGGER update_status_incidents_updated_at
  BEFORE UPDATE ON public.status_incidents
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();