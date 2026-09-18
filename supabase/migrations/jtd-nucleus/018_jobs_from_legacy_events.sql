-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/018_jobs_from_legacy_events.sql  (2026-09-17)
-- Every activation gets its payment/service jobs, whichever writer ran.
--
-- FOUND ON CN-1010 (signia → buyer, accepted through the public review
-- link): the V1 activation trigger materialized 8 legacy t_contract_events
-- rows and ZERO n_jtd jobs. update_contract_status_v2 materializes jobs
-- (004) but the public accept — respond_to_contract — and every other V1
-- writer bypass it, and both cutover mirrors (003) are UPDATE-only: an
-- event born without a twin never gets one. The Ops board's Collections
-- rows come from payment jobs, so the ₹37,000 due was invisible there
-- while Money In showed it. Live count at the time: 68 contracts / 955
-- events without a twin across 9 tenants (~₹1.04 crore open billing).
--
-- WHAT THIS DOES (all additive, id-preserving = the cutover/001 mapping):
--  A) jtd_mirror_jobs_from_events(contract, tenant): inserts a twin job
--     (same id) for every t_contract_events row of the contract that has
--     none. Refuses to touch a contract that already holds jobs WITHOUT
--     event twins (a materialize-created set with its own ids) so a board
--     can never show the same due twice. Legacy status is copied verbatim,
--     never 'created', so trg_jtd_enqueue / the credit gate stay silent.
--  B) trigger_queue_contract_events(): after the V1 event build, mirror.
--     Wrapped so a mirror failure can never block an activation.
--  C) Backfill: mirror every 'contract' record that has events without
--     twins; verify counts and sums per contract like cutover/001; RAISE
--     (rollback) on any mismatch.
-- Applied live 2026-09-17 (batch jtd-jobs-from-legacy-events) — source of
-- record; do not re-run (idempotent anyway: nothing to mirror twice).
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.jtd_mirror_jobs_from_events(p_contract_id uuid, p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_c        RECORD;
    v_orphans  integer;
    v_created  integer := 0;
BEGIN
    SELECT id, tenant_id, contract_number, record_type
    INTO v_c
    FROM t_contracts
    WHERE id = p_contract_id AND tenant_id = p_tenant_id;

    IF v_c.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
    END IF;
    IF v_c.record_type IS DISTINCT FROM 'contract' THEN
        RETURN jsonb_build_object('success', true, 'jobs_created', 0, 'skipped', 'not a contract');
    END IF;

    -- Jobs that are not twins of an event: this contract was materialized
    -- from computed_events with its own ids. Mirroring would double it.
    SELECT count(*) INTO v_orphans
    FROM n_jtd j
    WHERE j.contract_id = p_contract_id AND j.tenant_id = p_tenant_id
      AND j.channel_code IS NULL AND COALESCE(j.is_active, true)
      AND NOT EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = j.id);
    IF v_orphans > 0 THEN
        RETURN jsonb_build_object('success', true, 'jobs_created', 0,
                                  'skipped', 'contract has non-twin jobs', 'orphan_jobs', v_orphans);
    END IF;

    INSERT INTO n_jtd (id, tenant_id, contract_id, block_id, block_name, category_id,
        event_type_code, source_type_code, source_id, source_ref,
        scheduled_at, original_date, sequence_number, total_occurrences,
        billing_sub_type, billing_cycle_label, amount, amount_settled, currency,
        invoice_id, status_code, status_changed_at, completed_at,
        task_id, reminder_jtd_id, reminder_dispatched_at,
        assigned_to, assigned_to_name, notes, version, is_active, is_live, audience,
        performed_by_type, priority, business_context,
        created_at, updated_at, created_by, updated_by)
    SELECT e.id, e.tenant_id, e.contract_id, e.block_id, e.block_name, e.category_id,
        CASE e.event_type WHEN 'service' THEN 'service_visit' ELSE 'payment' END,
        CASE e.event_type WHEN 'service' THEN 'service_scheduled' ELSE 'payment_scheduled' END,
        e.contract_id, v_c.contract_number,
        e.scheduled_date, e.original_date, e.sequence_number, e.total_occurrences,
        e.billing_sub_type, e.billing_cycle_label, e.amount, e.amount_settled, e.currency,
        e.invoice_id, e.status, COALESCE(e.updated_at, e.created_at, now()),
        CASE WHEN e.status IN ('paid','completed') THEN COALESCE(e.updated_at, e.created_at, now()) ELSE NULL END,
        e.task_id, e.reminder_jtd_id, e.reminder_dispatched_at,
        e.assigned_to, e.assigned_to_name, e.notes, e.version, e.is_active, e.is_live, e.audience,
        'system', 5,
        jsonb_build_object('migrated_from', 't_contract_events',
                           'migration', 'jtd-nucleus/018', 'migrated_at', now()),
        COALESCE(e.created_at, now()), COALESCE(e.updated_at, e.created_at, now()), e.created_by, e.updated_by
    FROM t_contract_events e
    WHERE e.contract_id = p_contract_id AND e.tenant_id = p_tenant_id
      AND NOT EXISTS (SELECT 1 FROM n_jtd j2 WHERE j2.id = e.id);
    GET DIAGNOSTICS v_created = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'jobs_created', v_created);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to mirror jobs from events',
                              'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- B) V1 activation: build the legacy events as before, then give them twins.
CREATE OR REPLACE FUNCTION public.trigger_queue_contract_events()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_mirror jsonb;
BEGIN
    IF NEW.status = 'active' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
        IF NEW.computed_events IS NOT NULL AND jsonb_array_length(NEW.computed_events) > 0 THEN
            PERFORM process_contract_events_from_computed(NEW.id, NEW.tenant_id);
        END IF;
        -- jtd-nucleus/018: a V1 activation must leave jobs behind too.
        BEGIN
            v_mirror := jtd_mirror_jobs_from_events(NEW.id, NEW.tenant_id);
            IF COALESCE((v_mirror->>'success')::boolean, false) IS DISTINCT FROM true THEN
                RAISE WARNING 'jtd-nucleus/018: job mirror failed for contract %: %', NEW.id, v_mirror->>'details';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'jtd-nucleus/018: job mirror raised for contract %: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$function$;

-- C) Backfill every contract whose events have no twin, verified per contract.
DO $do$
DECLARE
    r          RECORD;
    v_res      jsonb;
    v_contracts integer := 0;
    v_jobs     integer := 0;
    v_skipped  integer := 0;
    v_bad      integer;
BEGIN
    CREATE TEMP TABLE tmp_018_scope ON COMMIT DROP AS
    SELECT DISTINCT e.contract_id, e.tenant_id
    FROM t_contract_events e
    JOIN t_contracts c ON c.id = e.contract_id AND c.record_type = 'contract'
    WHERE NOT EXISTS (SELECT 1 FROM n_jtd j WHERE j.id = e.id);

    FOR r IN SELECT contract_id, tenant_id FROM tmp_018_scope LOOP
        v_res := jtd_mirror_jobs_from_events(r.contract_id, r.tenant_id);
        IF COALESCE((v_res->>'success')::boolean, false) IS DISTINCT FROM true THEN
            RAISE EXCEPTION '018 backfill failed on contract %: %', r.contract_id, v_res;
        END IF;
        IF v_res ? 'skipped' THEN
            v_skipped := v_skipped + 1;
        ELSE
            v_contracts := v_contracts + 1;
            v_jobs := v_jobs + COALESCE((v_res->>'jobs_created')::integer, 0);
        END IF;
    END LOOP;

    -- Verification (cutover/001 pattern): for every mirrored contract, event
    -- count and rupee sums must equal the twin-job count and sums.
    SELECT count(*) INTO v_bad FROM (
        SELECT s.contract_id,
            (SELECT count(*) FROM t_contract_events e WHERE e.contract_id = s.contract_id) AS ec,
            (SELECT COALESCE(SUM(e.amount),0) FROM t_contract_events e WHERE e.contract_id = s.contract_id) AS ea,
            (SELECT COALESCE(SUM(e.amount_settled),0) FROM t_contract_events e WHERE e.contract_id = s.contract_id) AS es,
            (SELECT count(*) FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL
               AND EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = j.id)) AS jc,
            (SELECT COALESCE(SUM(j.amount),0) FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL
               AND EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = j.id)) AS ja,
            (SELECT COALESCE(SUM(j.amount_settled),0) FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL
               AND EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = j.id)) AS js
        FROM tmp_018_scope s
        WHERE NOT EXISTS (SELECT 1 FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL
                          AND NOT EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = j.id))) t
    WHERE t.ec <> t.jc OR t.ea <> t.ja OR t.es <> t.js;

    IF v_bad > 0 THEN
        RAISE EXCEPTION '018 verification FAILED on % contract(s) — rolled back', v_bad;
    END IF;

    RAISE NOTICE '018 OK: % contracts mirrored, % jobs created id-preserving, % contracts skipped (non-twin jobs)', v_contracts, v_jobs, v_skipped;
END
$do$;
