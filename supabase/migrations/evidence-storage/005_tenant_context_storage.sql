-- evidence-storage/005_tenant_context_storage.sql
--
-- ⚠️ ALREADY APPLIED LIVE (2026-09-21). Source-of-record copy — DO NOT RE-RUN.
--
-- Tenant context reports storage from the evidence registry, not the dead
-- t_tenant_context.limit_storage_mb / usage_storage_mb columns, which were
-- never populated by anything — so limits.storage_mb and usage.storage_mb
-- both read as whatever those columns happened to hold (in practice, nothing).
--
-- storage_used_mb() uses exactly the predicate evidence_usage() uses, so the
-- figure on the Workspace Account card can never disagree with the figure the
-- upload broker enforces:
--   scope = 'contract' AND status = 'active' AND owner_tenant_id = tenant
-- Contract evidence only (identity assets are unmetered by owner decision) and
-- both environments together (owner decision: "space is space").

CREATE OR REPLACE FUNCTION public.storage_limit_mb(p_tenant_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
    SELECT GREATEST(1, (COALESCE(storage_quota_bytes, 41943040) / 1048576)::int)
    FROM t_tenants WHERE id = p_tenant_id;
$fn$;

CREATE OR REPLACE FUNCTION public.storage_used_mb(p_tenant_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
    SELECT CEIL(COALESCE(sum(size_bytes), 0)::numeric / 1048576)::int
    FROM t_contract_evidence
    WHERE owner_tenant_id = p_tenant_id AND scope = 'contract' AND status = 'active';
$fn$;

GRANT EXECUTE ON FUNCTION public.storage_limit_mb(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.storage_used_mb(uuid)  TO authenticated, service_role;

-- Anchor rewrite of the live get_tenant_context body (the migration 048/059
-- technique), with a post-check that RAISEs if the substitution did not land.
-- A silent no-op is this technique's failure mode — never skip the check.
--
-- 'storage_mb' is the LAST key of the usage object, so appending 'storage'
-- after it is safe; the rewrite refuses if either anchor is not present exactly
-- once, or if any v_context.*_storage_mb reference survives.
DO $rw$
DECLARE v_src text; v_new text;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'get_tenant_context';
    IF v_src IS NULL THEN RAISE EXCEPTION 'get_tenant_context not found'; END IF;

    IF (SELECT count(*) FROM regexp_matches(v_src, 'v_context\.limit_storage_mb', 'g')) <> 1
    OR (SELECT count(*) FROM regexp_matches(v_src, 'v_context\.usage_storage_mb', 'g')) <> 1
    THEN RAISE EXCEPTION 'expected exactly one of each storage anchor'; END IF;

    v_new := replace(v_src, 'v_context.limit_storage_mb', 'storage_limit_mb(v_context.tenant_id)');
    v_new := replace(v_new, '''storage_mb'', v_context.usage_storage_mb',
                     '''storage_mb'', storage_used_mb(v_context.tenant_id),'
                     || E'\n            ''storage'', evidence_usage(v_context.tenant_id)');

    IF (SELECT count(*) FROM regexp_matches(v_new, 'storage_limit_mb\(v_context\.tenant_id\)', 'g')) <> 1
    OR (SELECT count(*) FROM regexp_matches(v_new, 'storage_used_mb\(v_context\.tenant_id\)', 'g')) <> 1
    OR (SELECT count(*) FROM regexp_matches(v_new, 'evidence_usage\(v_context\.tenant_id\)', 'g')) <> 1
    OR v_new ~ 'v_context\.(limit|usage)_storage_mb'
    THEN RAISE EXCEPTION 'anchor rewrite did not land'; END IF;

    EXECUTE format(
      'CREATE OR REPLACE FUNCTION public.get_tenant_context(p_product_code text, p_tenant_id uuid)'
      ' RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS %L',
      v_new);
END $rw$;
