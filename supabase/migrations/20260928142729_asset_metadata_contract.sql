-- Sprint 1: typed definitions for registry specifications. Core identity fields
-- remain on t_client_asset_registry; this table describes additional attributes.
CREATE TABLE public.m_asset_attribute_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_type_id varchar(50) NOT NULL CHECK (resource_type_id IN ('equipment','asset')),
  template_id uuid,
  attribute_key text NOT NULL CHECK (attribute_key ~ '^[a-z][a-z0-9_]{1,63}$' AND attribute_key NOT IN ('id','name','code','serial_number','make','model','location','resource_type_id','asset_type_id','template_id','area_sqft','capacity')),
  label text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 160),
  data_type text NOT NULL CHECK (data_type IN ('text','number','boolean','date','select')),
  unit text CHECK (unit IS NULL OR length(btrim(unit)) BETWEEN 1 AND 32),
  options jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(options)='array'),
  required_stage text NOT NULL DEFAULT 'none' CHECK (required_stage IN ('none','service_start','form_submit')),
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT asset_attribute_select_options CHECK ((data_type='select')=(jsonb_array_length(options)>0)),
  CONSTRAINT asset_attribute_unit CHECK (unit IS NULL OR data_type='number')
);
CREATE UNIQUE INDEX asset_attribute_global_key ON public.m_asset_attribute_definitions(resource_type_id,attribute_key) WHERE template_id IS NULL;
CREATE UNIQUE INDEX asset_attribute_template_key ON public.m_asset_attribute_definitions(resource_type_id,template_id,attribute_key) WHERE template_id IS NOT NULL;
CREATE INDEX asset_attribute_lookup ON public.m_asset_attribute_definitions(resource_type_id,template_id,sort_order) WHERE is_active;
ALTER TABLE public.m_asset_attribute_definitions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.m_asset_attribute_definitions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.m_asset_attribute_definitions TO service_role;

-- Snapshots are written at final submission in Sprint 2. Existing records stay
-- unchanged, and a missing snapshot is distinguishable from an empty one.
ALTER TABLE public.m_form_submissions
  ADD COLUMN asset_metadata_snapshot jsonb,
  ADD COLUMN service_context_snapshot jsonb,
  ADD COLUMN form_schema_snapshot jsonb;
COMMENT ON COLUMN public.m_form_submissions.asset_metadata_snapshot IS 'Immutable-at-submission asset identity and applicable specification values; never populated from a draft.';
COMMENT ON COLUMN public.m_form_submissions.service_context_snapshot IS 'Visit and ticket facts as they were when the report was submitted.';
COMMENT ON COLUMN public.m_form_submissions.form_schema_snapshot IS 'Submitted form schema, preserving historical interpretation when a template changes.';
