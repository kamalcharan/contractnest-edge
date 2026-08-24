-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/003_step3_get_contract_details_v2.sql
-- JTD Nucleus — Step 3 of 6 (owner-approved 2026-08-18)
--
-- ONE aggregate read for the contract view (owner decision: "why so
-- many hits") — contract + blocks + jobs + CNAK + invoices in a
-- single call, replacing 4 round-trips.
--
-- DESIGN:
--   · COMPOSES the existing V1 read RPCs (read-only reuse — golden
--     rule intact, byte-parity guaranteed):
--       contract  ← get_contract_by_id(...)        (includes blocks)
--       invoices  ← get_contract_invoices(...)
--       legacy events fallback ← get_contract_events_list(...)
--   · events section: n_jtd JOB rows when the contract has them
--     (source='jtd'), else the V1 events list (source='legacy') — so
--     ONE endpoint renders both eras correctly during transition.
--   · jobs are mapped to the UI's exact ContractEvent shape
--     (event_type 'service'/'billing', scheduled_date, status, ...)
--     so every existing screen component renders unmodified.
--   · cnak: grant details WITHOUT the secret (presence flag only).
--   · as_of watermark for the UI's "updated Xs ago".
--
-- NEW OBJECT ONLY — no existing function/table/trigger touched.
-- APPLIED LIVE 2026-08-18 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_contract_details_v2(
    p_tenant_id   uuid,
    p_contract_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_contract   jsonb;
    v_is_live    boolean;
    v_jobs       jsonb;
    v_jobs_count integer;
    v_source     text;
    v_legacy     jsonb;
    v_cnak       jsonb;
    v_invoices   jsonb;
BEGIN
    -- ── contract (+blocks): reuse the V1 reader, byte-parity ──
    v_contract := get_contract_by_id(p_contract_id, p_tenant_id, NULL, NULL);
    IF v_contract IS NULL OR COALESCE((v_contract->>'success')::boolean, false) IS DISTINCT FROM true
       OR v_contract->'data' IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
    END IF;

    SELECT c.is_live INTO v_is_live
    FROM t_contracts c
    WHERE c.id = p_contract_id AND c.tenant_id = p_tenant_id;

    -- ── events: JOBS from n_jtd when present (the nucleus), mapped to
    --    the UI's exact ContractEvent shape ──
    SELECT
        jsonb_agg(jsonb_build_object(
            'id', j.id,
            'tenant_id', j.tenant_id,
            'contract_id', j.contract_id,
            'task_id', j.task_id,
            'block_id', j.block_id,
            'block_name', j.block_name,
            'category_id', j.category_id,
            'event_type', CASE j.event_type_code WHEN 'service_visit' THEN 'service' ELSE 'billing' END,
            'billing_sub_type', j.billing_sub_type,
            'billing_cycle_label', j.billing_cycle_label,
            'sequence_number', j.sequence_number,
            'total_occurrences', j.total_occurrences,
            'scheduled_date', j.scheduled_at,
            'original_date', j.original_date,
            'amount', j.amount,
            'amount_settled', j.amount_settled,
            'invoice_id', j.invoice_id,
            'currency', j.currency,
            'status', j.status_code,
            'assigned_to', j.assigned_to,
            'assigned_to_name', j.assigned_to_name,
            'notes', j.notes,
            'version', j.version,
            'is_live', j.is_live,
            'created_at', j.created_at,
            'updated_at', j.updated_at
        ) ORDER BY j.scheduled_at, j.sequence_number, j.id),
        COUNT(*)
    INTO v_jobs, v_jobs_count
    FROM n_jtd j
    WHERE j.contract_id = p_contract_id
      AND j.tenant_id   = p_tenant_id
      AND j.channel_code IS NULL           -- jobs, never messages
      AND COALESCE(j.is_active, true);

    IF COALESCE(v_jobs_count, 0) > 0 THEN
        v_source := 'jtd';
    ELSE
        -- ── legacy fallback: pre-nucleus contracts render from the V1
        --    events list, via the V1 RPC itself (read-only reuse) ──
        v_source := 'legacy';
        v_legacy := get_contract_events_list(
            p_tenant_id, v_is_live, p_contract_id,
            NULL, NULL, NULL, NULL, NULL, NULL,
            1, 100, 'scheduled_date', 'asc');
        v_jobs       := COALESCE(v_legacy->'data', '[]'::jsonb);
        v_jobs_count := COALESCE(jsonb_array_length(v_jobs), 0);
    END IF;

    -- ── CNAK grant (never the secret — presence flag only) ──
    SELECT jsonb_build_object(
        'global_access_id',    a.global_access_id,
        'status',              a.status,
        'accessor_name',       a.accessor_name,
        'accessor_contact_id', a.accessor_contact_id,
        'accessor_tenant_id',  a.accessor_tenant_id,
        'accessor_role',       a.accessor_role,
        'claimed_at',          a.claimed_at,
        'link_clicked_at',     a.link_clicked_at,
        'expires_at',          a.expires_at,
        'is_active',           a.is_active,
        'has_secret',          a.secret_code IS NOT NULL,
        'created_at',          a.created_at
    ) INTO v_cnak
    FROM t_contract_access a
    WHERE a.contract_id = p_contract_id
    ORDER BY a.created_at DESC
    LIMIT 1;

    -- ── invoices: reuse the V1 reader, byte-parity ──
    v_invoices := get_contract_invoices(p_contract_id, p_tenant_id);

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract', v_contract->'data',
            'events', jsonb_build_object(
                'items',       COALESCE(v_jobs, '[]'::jsonb),
                'total_count', COALESCE(v_jobs_count, 0),
                'source',      v_source
            ),
            'cnak',     v_cnak,
            'invoices', v_invoices->'data',
            'as_of',    now()
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to load contract details',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;

COMMENT ON FUNCTION public.get_contract_details_v2 IS
'JTD Nucleus Step 3: single-call contract view aggregate — contract+blocks (via get_contract_by_id), events (n_jtd JOBS when present, V1 events fallback for pre-nucleus contracts), CNAK grant (secret never exposed), invoices (via get_contract_invoices), as_of watermark. Composes V1 readers read-only; no existing object modified.';
