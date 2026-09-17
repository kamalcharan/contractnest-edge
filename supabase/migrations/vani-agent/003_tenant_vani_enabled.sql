-- ============================================================================
-- 003_tenant_vani_enabled.sql — VaNi enablement becomes a tenant-level truth
-- ============================================================================
-- Owner decisions (2026-09-16):
--   · "VaNi enabled or not should be part of the tenant table" and exposed by
--     the tenant-context API. VaNi is part of subscriptions; the flag is what
--     subscriptions (trial / plan add-on / admin) switch on.
--   · The admin tenant (t_tenants.is_admin) is ALWAYS enabled — computed, so
--     it can never lapse.
--   · BBB and signia are enabled now (source 'admin', open-ended).
--
-- What this adds:
--   t_tenants.vani_enabled / vani_enabled_until / vani_enabled_source
--   vani_is_enabled(tenant_id)  — THE truth function. Expiry is evaluated at
--                                 read time, so a lapsed trial switches off
--                                 with no cron.
--   get_tenant_context(...)     — now emits flags.vani_enabled and a `vani`
--                                 object {enabled, until, source}.
--   start_vani_trial(...)       — first writer: a trial sets the flag on until
--                                 trial_ends, never downgrading an open-ended
--                                 enablement.
--
-- What this deliberately does NOT do (stitched on in later steps, per owner):
--   · no engine gating yet (scanner, group-session cron, jtd-worker untouched)
--   · vaniEntitlementService (API) still uses VANI_ENTITLEMENT_MODE
--   · plan-entitlement writers (fn_apply_contract_entitlements,
--     subscribe_tenant_to_plan_v2, fn_apply_topup_grants) do not yet set the
--     column when the addon_vani_ai flag is granted
--
-- Method: get_tenant_context and start_vani_trial are rewritten by anchored
-- substitution on pg_get_functiondef (not retyped). Each anchor must match
-- exactly once or the block RAISEs — a silent no-op is the failure mode of
-- this technique (see CLAUDE.md, migrations 058/059).
--
-- APPLIED LIVE 2026-09-16 after a guarded BEGIN…ROLLBACK verification run.
-- Idempotent: safe to re-run (columns IF NOT EXISTS, rewrites skip when the
-- marker text is already present, the data UPDATE is a no-op second time).
-- ============================================================================

ALTER TABLE public.t_tenants
  ADD COLUMN IF NOT EXISTS vani_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS vani_enabled_until timestamptz NULL,
  ADD COLUMN IF NOT EXISTS vani_enabled_source text NULL;

COMMENT ON COLUMN public.t_tenants.vani_enabled IS
  'Tenant-level VaNi switch (the single truth; see vani_is_enabled()). Admin tenants are always enabled regardless of this column.';
COMMENT ON COLUMN public.t_tenants.vani_enabled_until IS
  'When set, VaNi is enabled only until this instant (trials). NULL = open-ended.';
COMMENT ON COLUMN public.t_tenants.vani_enabled_source IS
  'Who switched it on: trial | plan | admin.';

CREATE OR REPLACE FUNCTION public.vani_is_enabled(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((
    SELECT t.is_admin = true
        OR (t.vani_enabled AND (t.vani_enabled_until IS NULL OR t.vani_enabled_until > now()))
    FROM public.t_tenants t WHERE t.id = p_tenant_id
  ), false);
$$;

COMMENT ON FUNCTION public.vani_is_enabled(uuid) IS
  'THE VaNi enablement truth: admin tenant, or t_tenants.vani_enabled not yet expired. Engines, the tenant-context API and the entitlement service must all read this.';

-- get_tenant_context: add flags.vani_enabled + a `vani` object -------------
DO $do$
DECLARE v_def text; v_new text; v_oid oid; v_n int;
BEGIN
  SELECT p.oid, pg_get_functiondef(p.oid) INTO v_oid, v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_tenant_context';
  IF v_oid IS NULL THEN RAISE EXCEPTION 'get_tenant_context not found'; END IF;
  IF position('vani_is_enabled' IN v_def) > 0 THEN RAISE NOTICE 'get_tenant_context already carries vani flag'; RETURN; END IF;

  SELECT count(*) INTO v_n FROM regexp_matches(v_def, '''over_limit'', v_context\.flag_over_limit\s*\)', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor flags tail found % times', v_n; END IF;
  v_new := regexp_replace(v_def,
    '(''over_limit'', v_context\.flag_over_limit)(\s*\))',
    '\1,' || E'\n            ''vani_enabled'', public.vani_is_enabled(v_context.tenant_id)' || '\2');

  SELECT count(*) INTO v_n FROM regexp_matches(v_new, '''retrieved_at'', NOW\(\)', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor retrieved_at found % times', v_n; END IF;
  v_new := replace(v_new, '''retrieved_at'', NOW()',
    '''vani'', (SELECT jsonb_build_object(' ||
      '''enabled'', public.vani_is_enabled(t.id), ' ||
      '''until'', t.vani_enabled_until, ' ||
      '''source'', CASE WHEN t.is_admin THEN ''admin_tenant'' ELSE t.vani_enabled_source END) ' ||
      'FROM public.t_tenants t WHERE t.id = v_context.tenant_id),' || E'\n        ''retrieved_at'', NOW()');

  IF v_new = v_def THEN RAISE EXCEPTION 'get_tenant_context rewrite produced no change'; END IF;
  EXECUTE v_new;
END $do$;

-- start_vani_trial: first writer of the tenant flag --------------------------
DO $do$
DECLARE v_def text; v_new text; v_oid oid; v_n int;
BEGIN
  SELECT p.oid, pg_get_functiondef(p.oid) INTO v_oid, v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'start_vani_trial';
  IF v_oid IS NULL THEN RAISE EXCEPTION 'start_vani_trial not found'; END IF;
  IF position('vani_enabled_source' IN v_def) > 0 THEN RAISE NOTICE 'start_vani_trial already writes the tenant flag'; RETURN; END IF;

  SELECT count(*) INTO v_n FROM regexp_matches(v_def, 'RETURN jsonb_build_object\(\s*''success'', true,\s*''started_now''', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor started_now RETURN found % times', v_n; END IF;
  v_new := regexp_replace(v_def,
    '(RETURN jsonb_build_object\(\s*''success'', true,\s*''started_now'')',
    E'-- Tenant-level VaNi truth (t_tenants.vani_enabled): a trial switches VaNi on\n' ||
    E'  -- until trial_ends. Never downgrades an open-ended (plan/admin) enablement.\n' ||
    E'  UPDATE public.t_tenants\n' ||
    E'     SET vani_enabled = true,\n' ||
    E'         vani_enabled_until = v_row.trial_ends,\n' ||
    E'         vani_enabled_source = ''trial''\n' ||
    E'   WHERE id = p_tenant_id\n' ||
    E'     AND NOT (vani_enabled AND vani_enabled_until IS NULL);\n\n  \\1');
  IF v_new = v_def THEN RAISE EXCEPTION 'start_vani_trial rewrite produced no change'; END IF;
  EXECUTE v_new;
END $do$;

-- Data: owner instruction 2026-09-16 — BBB (live) and signia on, open-ended.
-- bbb2025 (test tenant) deliberately NOT enabled. vikuna is the admin tenant
-- and is enabled by computation, no row change needed.
UPDATE public.t_tenants
   SET vani_enabled = true, vani_enabled_until = NULL, vani_enabled_source = 'admin'
 WHERE id IN ('dd194710-92b4-4110-80eb-0b492a0d2c1f',   -- BBB
              '80e3b843-525e-4368-b418-b1250d1d1d63');  -- signia

-- Post-checks (RAISE on failure so a partial apply cannot pass silently)
DO $chk$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname='get_tenant_context' AND prosrc LIKE '%vani_is_enabled(v_context.tenant_id)%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'post-check: get_tenant_context does not emit vani_enabled'; END IF;
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname='start_vani_trial' AND prosrc LIKE '%vani_enabled_source = ''trial''%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'post-check: start_vani_trial does not write the tenant flag'; END IF;
  IF NOT public.vani_is_enabled('70f8eb69-9ccf-4a0c-8177-cb6131934344') THEN RAISE EXCEPTION 'post-check: admin tenant must be enabled'; END IF;
  IF NOT public.vani_is_enabled('dd194710-92b4-4110-80eb-0b492a0d2c1f') THEN RAISE EXCEPTION 'post-check: BBB must be enabled'; END IF;
  IF public.vani_is_enabled('ae70b774-f4c7-41ac-83a0-a1ebf352b991') THEN RAISE EXCEPTION 'post-check: bbb2025 must NOT be enabled'; END IF;
END $chk$;
