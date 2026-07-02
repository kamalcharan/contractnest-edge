-- =============================================================================
-- Tenant Isolation — BATCH 1 (UP)
-- =============================================================================
-- Closes the largest "silent exposure": 11 tables hold tenant_id data but have
-- RLS DISABLED, so any authenticated/anon caller could read EVERY tenant's rows
-- (validated live: 146 rows visible across tenants before this migration).
--
-- This migration:
--   1. ENABLEs row level security on each table
--   2. Adds a tenant-membership SELECT policy for the `authenticated` role
--   3. Adds an explicit `service_role` bypass policy (documents intent)
--
-- SAFETY / NON-BREAKING:
--   * The API (Express) and Edge functions connect as service_role, which
--     bypasses RLS — so the running application is unaffected.
--   * None of these 11 tables are accessed by the browser (anon) client.
--   * Effect is strictly TIGHTENING: authenticated callers go from "all tenants"
--     to "own tenant only"; writes by authenticated are denied (service_role only).
--
-- MECHANISM: EXISTS-on-membership against t_user_tenants — matches the existing
-- canonical policies (e.g. t_audit_logs.user_tenant_audit_logs_select) and fits
-- the multi-tenant-per-user model. Mechanism-agnostic: no JWT-vs-GUC decision.
--
-- VALIDATED 2026-06-30 via BEGIN/ROLLBACK on prod with two real cross-tenant
-- users: User A saw 5/146 rows, User B saw 3/146 rows (their own tenants only).
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
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

    EXECUTE format('DROP POLICY IF EXISTS batch1_tenant_member_select ON public.%I', t);
    EXECUTE format($f$CREATE POLICY batch1_tenant_member_select ON public.%I
      FOR SELECT TO authenticated
      USING (EXISTS (
        SELECT 1 FROM public.t_user_tenants ut
        WHERE ut.user_id = auth.uid()
          AND ut.tenant_id = public.%I.tenant_id
          AND ut.status = 'active'))$f$, t, t);

    EXECUTE format('DROP POLICY IF EXISTS batch1_service_role_all ON public.%I', t);
    EXECUTE format($f$CREATE POLICY batch1_service_role_all ON public.%I
      FOR ALL TO service_role USING (true) WITH CHECK (true)$f$, t);
  END LOOP;
END $$;
