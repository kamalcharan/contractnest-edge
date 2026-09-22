-- evidence-storage/006_sweep_wiring.sql
--
-- ⚠️ ALREADY APPLIED LIVE (2026-09-22). Source-of-record copy — DO NOT RE-RUN.
--    (sc__rewrite_fn refuses a second application anyway: it raises
--     'already rewritten' when the new text is already in the body.)
--
-- G2, database half: make the sweep filable, and make clearing test data
-- actually give the bytes back.

-- Generic anchor rewriter. Rebuilds the function from pg_proc rather than
-- retyping a long live body. Refuses on a missing anchor, a non-unique anchor,
-- an already-applied rewrite, and — the failure mode of this technique — a
-- substitution that silently did not land.
--
-- NOTE the post-check asserts the NEW text is PRESENT. Asserting the old
-- anchor is GONE is wrong whenever the replacement deliberately keeps it
-- (change 2 below wraps the anchor rather than replacing it). The first probe
-- of this migration failed on exactly that mistake in the check, not the
-- rewrite.
CREATE OR REPLACE FUNCTION public.sc__rewrite_fn(p_name text, p_args text, p_from text, p_to text)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE v_oid oid; v_src text; v_new text;
BEGIN
    SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname=p_name
       AND pg_get_function_identity_arguments(p.oid)=p_args;
    IF v_oid IS NULL THEN RAISE EXCEPTION 'fn %(%) not found', p_name, p_args; END IF;
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid=v_oid;
    IF position(p_from in v_src) = 0 THEN RAISE EXCEPTION 'anchor absent in %', p_name; END IF;
    IF position(p_from in substring(v_src from position(p_from in v_src)+length(p_from))) <> 0
    THEN RAISE EXCEPTION 'anchor not unique in %', p_name; END IF;
    IF position(p_to in v_src) <> 0 THEN RAISE EXCEPTION 'already rewritten: %', p_name; END IF;
    v_new := replace(v_src, p_from, p_to);
    EXECUTE format('CREATE OR REPLACE FUNCTION public.%I(%s) RETURNS %s LANGUAGE %s %s %s %s AS %L',
        p_name, pg_get_function_arguments(v_oid), pg_get_function_result(v_oid),
        (SELECT lanname FROM pg_language l JOIN pg_proc p ON p.prolang=l.oid WHERE p.oid=v_oid),
        (SELECT CASE provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END FROM pg_proc WHERE oid=v_oid),
        (SELECT CASE WHEN prosecdef THEN 'SECURITY DEFINER' ELSE '' END FROM pg_proc WHERE oid=v_oid),
        (SELECT COALESCE((SELECT string_agg('SET '||split_part(c,'=',1)||' = '||quote_literal(split_part(c,'=',2)),' ')
                          FROM unnest(proconfig) c), '') FROM pg_proc WHERE oid=v_oid),
        v_new);
    IF position(p_to in (SELECT prosrc FROM pg_proc WHERE oid=v_oid)) = 0
    THEN RAISE EXCEPTION 'rewrite did not land in %', p_name; END IF;
END $fn$;

-- 1. claim() must carry is_live. Without it the runner cannot call
--    storage_cleanup_record(tenant, counts, is_live) correctly and would file
--    every test-environment sweep as live.
SELECT sc__rewrite_fn('storage_cleanup_claim','p_limit integer, p_orphan_hours integer',
    '''size_bytes'',e.size_bytes,''reason''',
    '''size_bytes'',e.size_bytes,''is_live'',e.is_live,''reason''');

-- 2. "Space is space" — clearing TEST data has to release the bytes. Until now
--    every reset deleted its rows and orphaned the objects forever.
--    Wrapped so a storage failure can never break a reset, matching the
--    per-step EXCEPTION blocks this function already uses throughout.
SELECT sc__rewrite_fn('admin_reset_test_data','p_tenant_id uuid',
    E'\n  RETURN jsonb_build_object(''success'', true, ''deleted_counts'', v_deleted_counts,',
    E'\n  BEGIN PERFORM storage_cleanup_mark_environment(p_tenant_id, false); EXCEPTION WHEN OTHERS THEN NULL; END;\n'
    || E'\n  RETURN jsonb_build_object(''success'', true, ''deleted_counts'', v_deleted_counts,');

-- 3. Same for the session/forms reset. Its p_is_live defaults to NULL, which
--    in this function's own body means BOTH environments — so both are marked.
SELECT sc__rewrite_fn('reset_tenant_session_and_forms','p_tenant_id uuid, p_is_live boolean',
    E'  EXCEPTION WHEN OTHERS THEN NULL; END;\nEND;',
    E'  EXCEPTION WHEN OTHERS THEN NULL; END;\n'
    || E'  BEGIN\n'
    || E'    IF p_is_live IS NULL THEN\n'
    || E'      PERFORM storage_cleanup_mark_environment(p_tenant_id, true);\n'
    || E'      PERFORM storage_cleanup_mark_environment(p_tenant_id, false);\n'
    || E'    ELSE\n'
    || E'      PERFORM storage_cleanup_mark_environment(p_tenant_id, p_is_live);\n'
    || E'    END IF;\n'
    || E'  EXCEPTION WHEN OTHERS THEN NULL; END;\nEND;');
