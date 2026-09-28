-- Direct registry assets have asset_type_id but often no onboarding template_id.
-- Scope their definitions to the owning tenant; platform defaults remain global.
ALTER TABLE public.m_asset_attribute_definitions
  ADD COLUMN tenant_id uuid,
  ADD COLUMN asset_type_id uuid,
  ADD CONSTRAINT asset_attribute_one_selector CHECK (template_id IS NULL OR asset_type_id IS NULL),
  ADD CONSTRAINT asset_attribute_type_tenant CHECK (asset_type_id IS NULL OR tenant_id IS NOT NULL);
DROP INDEX public.asset_attribute_global_key;
DROP INDEX public.asset_attribute_template_key;
DROP INDEX public.asset_attribute_lookup;
CREATE UNIQUE INDEX asset_attribute_unique_scope ON public.m_asset_attribute_definitions (
  resource_type_id,
  coalesce(tenant_id,'00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(template_id,'00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(asset_type_id,'00000000-0000-0000-0000-000000000000'::uuid),
  attribute_key
);
CREATE INDEX asset_attribute_lookup ON public.m_asset_attribute_definitions(resource_type_id,tenant_id,template_id,asset_type_id,sort_order) WHERE is_active;
