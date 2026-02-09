-- ============================================================================
-- SmartForms — Rename Tables with m_form_ prefix
-- ============================================================================
-- Renames all SmartForms tables to follow the m_form_ naming convention.
-- Also renames indexes, constraints, and RLS policies to match.
-- Run AFTER 001_create_smart_forms_tables.sql
-- ============================================================================

-- ============================================================================
-- Step 1: Drop existing RLS policies (must drop before rename)
-- ============================================================================

DROP POLICY IF EXISTS "tenant_form_selections_tenant_isolation" ON public.tenant_form_selections;
DROP POLICY IF EXISTS "form_template_mappings_tenant_isolation" ON public.form_template_mappings;
DROP POLICY IF EXISTS "form_submissions_tenant_isolation" ON public.form_submissions;
DROP POLICY IF EXISTS "form_attachments_tenant_isolation" ON public.form_attachments;

-- ============================================================================
-- Step 2: Rename tables
-- ============================================================================

ALTER TABLE IF EXISTS public.form_templates RENAME TO m_form_templates;
ALTER TABLE IF EXISTS public.tenant_form_selections RENAME TO m_form_tenant_selections;
ALTER TABLE IF EXISTS public.form_template_mappings RENAME TO m_form_template_mappings;
ALTER TABLE IF EXISTS public.form_submissions RENAME TO m_form_submissions;
ALTER TABLE IF EXISTS public.form_attachments RENAME TO m_form_attachments;

-- ============================================================================
-- Step 3: Rename indexes
-- ============================================================================

-- m_form_templates indexes
ALTER INDEX IF EXISTS idx_form_templates_status RENAME TO idx_m_form_templates_status;
ALTER INDEX IF EXISTS idx_form_templates_category RENAME TO idx_m_form_templates_category;
ALTER INDEX IF EXISTS idx_form_templates_parent RENAME TO idx_m_form_templates_parent;
ALTER INDEX IF EXISTS idx_form_templates_tags RENAME TO idx_m_form_templates_tags;
ALTER INDEX IF EXISTS idx_form_templates_schema RENAME TO idx_m_form_templates_schema;

-- m_form_tenant_selections indexes
ALTER INDEX IF EXISTS idx_tenant_form_selections_tenant RENAME TO idx_m_form_tenant_selections_tenant;
ALTER INDEX IF EXISTS idx_tenant_form_selections_template RENAME TO idx_m_form_tenant_selections_template;
ALTER INDEX IF EXISTS idx_tenant_form_selections_active RENAME TO idx_m_form_tenant_selections_active;

-- m_form_template_mappings indexes
ALTER INDEX IF EXISTS idx_form_template_mappings_tenant RENAME TO idx_m_form_template_mappings_tenant;
ALTER INDEX IF EXISTS idx_form_template_mappings_contract RENAME TO idx_m_form_template_mappings_contract;
ALTER INDEX IF EXISTS idx_form_template_mappings_template RENAME TO idx_m_form_template_mappings_template;

-- m_form_submissions indexes
ALTER INDEX IF EXISTS idx_form_submissions_tenant RENAME TO idx_m_form_submissions_tenant;
ALTER INDEX IF EXISTS idx_form_submissions_event RENAME TO idx_m_form_submissions_event;
ALTER INDEX IF EXISTS idx_form_submissions_template RENAME TO idx_m_form_submissions_template;
ALTER INDEX IF EXISTS idx_form_submissions_status RENAME TO idx_m_form_submissions_status;
ALTER INDEX IF EXISTS idx_form_submissions_responses RENAME TO idx_m_form_submissions_responses;

-- m_form_attachments indexes
ALTER INDEX IF EXISTS idx_form_attachments_submission RENAME TO idx_m_form_attachments_submission;
ALTER INDEX IF EXISTS idx_form_attachments_field RENAME TO idx_m_form_attachments_field;
ALTER INDEX IF EXISTS idx_form_attachments_tenant RENAME TO idx_m_form_attachments_tenant;

-- ============================================================================
-- Step 4: Recreate RLS policies with new table names
-- ============================================================================

CREATE POLICY "m_form_tenant_selections_tenant_isolation"
  ON public.m_form_tenant_selections
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

CREATE POLICY "m_form_template_mappings_tenant_isolation"
  ON public.m_form_template_mappings
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

CREATE POLICY "m_form_submissions_tenant_isolation"
  ON public.m_form_submissions
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

CREATE POLICY "m_form_attachments_tenant_isolation"
  ON public.m_form_attachments
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

-- ============================================================================
-- Done — All tables now use m_form_ prefix
-- ============================================================================
-- Final table names:
--   m_form_templates
--   m_form_tenant_selections
--   m_form_template_mappings
--   m_form_submissions
--   m_form_attachments
-- ============================================================================
