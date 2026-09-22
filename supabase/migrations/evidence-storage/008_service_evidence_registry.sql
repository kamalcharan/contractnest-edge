-- evidence-storage/008_service_evidence_registry.sql
--
-- ⚠️ ALREADY APPLIED LIVE (2026-09-22). Source-of-record copy — DO NOT RE-RUN.
--    (It DROPs the 21-arg create_service_evidence; a second run would fail
--     looking for a function that no longer exists.)
--
-- Service evidence moves onto the broker.
--
-- t_service_evidence stays: it is the SERVICE-domain record (which ticket,
-- which event, which block, what kind of proof) and five live readers return
-- it. What changes is where the FILE lives. Until now the panel uploaded
-- through the legacy per-tenant storage API and stored a durable public URL in
-- file_url. Now the file goes through the evidence broker and the row simply
-- points at the registry; reads mint a short-TTL signed URL.
--
-- Safe as a straight swap because NOTHING HAS EVER USED IT: t_service_evidence
-- held 0 rows and t_contract_attachments held 0 rows when this was written.
-- No data to migrate, no URL to preserve. file_url is kept (nullable) so the
-- readers keep their shape and any future legacy row still renders.

ALTER TABLE t_service_evidence
  ADD COLUMN IF NOT EXISTS evidence_id uuid REFERENCES t_contract_evidence(id) ON DELETE SET NULL;

COMMENT ON COLUMN t_service_evidence.evidence_id IS
  'The file in t_contract_evidence. NULL only for legacy rows that still carry a durable file_url.';

CREATE INDEX IF NOT EXISTS ix_service_evidence_evidence_id
  ON t_service_evidence(evidence_id) WHERE evidence_id IS NOT NULL;

DO $m$
DECLARE
    v_oid oid; v_src text; v_new text; v_args text; v_ident text;
    a_detail text; a_list text; a_report text;
BEGIN
    SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='get_service_ticket_detail';
    a_detail := pg_get_function_identity_arguments(v_oid);
    SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='get_service_evidence_list';
    a_list := pg_get_function_identity_arguments(v_oid);
    SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='get_service_ticket_report';
    a_report := pg_get_function_identity_arguments(v_oid);

    -- create_service_evidence gains p_evidence_id. The 21-arg original is
    -- DROPPED rather than left beside the new one: a stale overload has caught
    -- this codebase three times already (gs_checkin_guest,
    -- check_contact_duplicates, jtd_escalate_payment_call).
    SELECT p.oid, p.prosrc, pg_get_function_arguments(p.oid), pg_get_function_identity_arguments(p.oid)
      INTO v_oid, v_src, v_args, v_ident
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='create_service_evidence';
    IF v_oid IS NULL THEN RAISE EXCEPTION 'create_service_evidence not found'; END IF;

    v_new := replace(v_src,
        E'        status, uploaded_by, uploaded_by_name,\r\n        is_live\r\n    ) VALUES (',
        E'        status, uploaded_by, uploaded_by_name,\r\n        is_live, evidence_id\r\n    ) VALUES (');
    v_new := replace(v_new,
        E'        v_status, p_uploaded_by, p_uploaded_by_name,\r\n        p_is_live\r\n    ) RETURNING id INTO v_evidence_id;',
        E'        v_status, p_uploaded_by, p_uploaded_by_name,\r\n        p_is_live, p_evidence_id\r\n    ) RETURNING id INTO v_evidence_id;');
    IF v_new = v_src THEN RAISE EXCEPTION 'INSERT rewrite did not land'; END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION public.create_service_evidence(%s, p_evidence_id uuid DEFAULT NULL)'
        ' RETURNS %s LANGUAGE plpgsql %s %s AS %L',
        v_args, pg_get_function_result(v_oid),
        (SELECT CASE WHEN pr.prosecdef THEN 'SECURITY DEFINER' ELSE '' END FROM pg_proc pr WHERE pr.oid=v_oid),
        (SELECT COALESCE((SELECT string_agg('SET '||split_part(c,'=',1)||' = '||quote_literal(split_part(c,'=',2)),' ')
                          FROM unnest(pr.proconfig) c), '') FROM pg_proc pr WHERE pr.oid=v_oid),
        v_new);

    EXECUTE format('DROP FUNCTION public.create_service_evidence(%s)', v_ident);

    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname='create_service_evidence') <> 1
    THEN RAISE EXCEPTION 'more than one create_service_evidence remains'; END IF;

    PERFORM sc__rewrite_fn('get_service_ticket_detail', a_detail,
        E'''file_url'', se.file_url,', E'''file_url'', se.file_url,\n            ''evidence_id'', se.evidence_id,');
    PERFORM sc__rewrite_fn('get_service_evidence_list', a_list,
        E'''file_url'', se.file_url,', E'''file_url'', se.file_url,\r\n            ''evidence_id'', se.evidence_id,');
    PERFORM sc__rewrite_fn('get_service_ticket_report', a_report,
        E'''file_url'', ev.file_url,', E'''file_url'', ev.file_url,\n        ''evidence_id'', ev.evidence_id,');
END $m$;
