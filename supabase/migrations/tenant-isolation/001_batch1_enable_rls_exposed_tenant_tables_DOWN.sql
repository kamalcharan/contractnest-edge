-- =============================================================================
-- Tenant Isolation — BATCH 1 (DOWN / rollback)
-- Reverts 001_batch1_enable_rls_exposed_tenant_tables.sql:
--   drops the two batch1 policies and DISABLEs RLS on each table,
--   returning every table to its pre-migration state.
-- =============================================================================

DO $$
DECLARE t text;
  tabs text[] := ARRAY[
    'm_event_status_config',
    'm_event_status_transitions',
    'n_tenant_preferences',
    't_catalog_categories',
    't_catalog_industries',
    't_category_details',
    't_category_master',
    't_category_resources_master',
    't_group_memberships',
    't_idempotency_keys',
    't_tenant_context'
  ];
BEGIN
  FOREACH t IN ARRAY tabs LOOP
    EXECUTE format('DROP POLICY IF EXISTS batch1_tenant_member_select ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS batch1_service_role_all ON public.%I', t);
    EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;
