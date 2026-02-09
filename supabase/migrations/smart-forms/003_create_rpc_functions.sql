-- ============================================================================
-- SmartForms — RPC Functions
-- ============================================================================
-- Clone and New Version require multi-step DB operations.
-- These RPCs keep all logic in Postgres so Edge stays thin (single call).
-- ============================================================================


-- ============================================================================
-- rpc_m_form_clone_template
-- ============================================================================
-- Clones an existing template into a new draft (any status source is OK).
-- Returns the newly created template row.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_m_form_clone_template(
  p_template_id UUID,
  p_user_id UUID
)
RETURNS SETOF public.m_form_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_source public.m_form_templates%ROWTYPE;
  v_new_id UUID;
BEGIN
  -- 1. Fetch source (single read)
  SELECT * INTO v_source
  FROM public.m_form_templates
  WHERE id = p_template_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template not found: %', p_template_id
      USING ERRCODE = 'P0002'; -- no_data_found
  END IF;

  -- 2. Insert clone as new draft
  INSERT INTO public.m_form_templates (
    name, description, category, form_type, tags, schema,
    version, status, created_by
  ) VALUES (
    v_source.name || ' (Copy)',
    v_source.description,
    v_source.category,
    v_source.form_type,
    v_source.tags,
    v_source.schema,
    1,
    'draft',
    p_user_id
  )
  RETURNING id INTO v_new_id;

  -- 3. Return the new row
  RETURN QUERY
    SELECT * FROM public.m_form_templates WHERE id = v_new_id;
END;
$$;


-- ============================================================================
-- rpc_m_form_new_version
-- ============================================================================
-- Creates a new draft version from an approved template.
-- Archives the source (approved → past) and creates v(N+1) as draft.
-- Links via parent_template_id for lineage.
-- Returns the newly created template row.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_m_form_new_version(
  p_template_id UUID,
  p_user_id UUID
)
RETURNS SETOF public.m_form_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_source public.m_form_templates%ROWTYPE;
  v_new_id UUID;
BEGIN
  -- 1. Fetch source and verify it's approved
  SELECT * INTO v_source
  FROM public.m_form_templates
  WHERE id = p_template_id AND status = 'approved';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template not found or not in approved status: %', p_template_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 2. Archive the current version (approved → past)
  UPDATE public.m_form_templates
  SET status = 'past', updated_at = now()
  WHERE id = p_template_id;

  -- 3. Insert new version as draft
  INSERT INTO public.m_form_templates (
    name, description, category, form_type, tags, schema,
    version, parent_template_id, status, created_by
  ) VALUES (
    v_source.name,
    v_source.description,
    v_source.category,
    v_source.form_type,
    v_source.tags,
    v_source.schema,
    v_source.version + 1,
    p_template_id,
    'draft',
    p_user_id
  )
  RETURNING id INTO v_new_id;

  -- 4. Return the new row
  RETURN QUERY
    SELECT * FROM public.m_form_templates WHERE id = v_new_id;
END;
$$;


-- ============================================================================
-- Done
-- ============================================================================
