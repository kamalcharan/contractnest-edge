-- ============================================================================
-- Migration: operations-loop/020 — Event-aware receivables ageing
-- ============================================================================
-- Purpose (owner decision 2026-07-22 — "invoice is 1, receipts are multiple"):
--   The platform's AR model is ONE invoice per contract plus an event-level
--   settlement sub-ledger (bbb-foundation/006: t_contract_events.amount_settled
--   + t_invoice_receipt_allocations). Stage 1's get_tenant_receivables (007)
--   still computed ALL time-based stats from the invoice's single due_date,
--   so a year of instalments went "overdue" the day the invoice was issued
--   (e.g. CN-1020: Rs 18,000 shown overdue when only months 1-4 were late)
--   and scheduled instalments never appeared in "Due in next 30 days".
--
--   This migration re-points the TIME-BASED stats at the billing-event
--   sub-ledger while keeping the invoice as the money source of truth:
--     * total_outstanding / outstanding_count / draft_* / collected_total
--       — unchanged, still invoice balances (source of truth per 006).
--     * overdue_total/count, ageing buckets, upcoming 7/15/30
--       — now from billing events: open amount = amount - amount_settled,
--         aged by each event's own scheduled_date.
--     * FIFO fallback: a payment recorded WITHOUT event allocations is
--       applied display-only to the contract's oldest unsettled events first,
--       so stats stay truthful even for lazy payment entry (no data changed).
--     * Contracts with an open invoice but NO billing events at all keep the
--       old invoice-level semantics (synthetic row from due_date/balance).
--     * by_buyer: outstanding stays invoice balance; overdue_total,
--       oldest_due_date, max_days_overdue now event-based.
--     * collected_this_month: now env-filtered via the receipt's invoice
--       (t_invoice_receipts has no is_live column; 007 mixed test+live).
--   Counts in overdue/ageing/upcoming are DISTINCT contracts (= invoices,
--   one invoice per contract) so "N invoices past due" stays truthful.
--
--   Response shape is IDENTICAL to 007 — no UI/edge changes required.
--   get_tenant_payables is deliberately untouched.
--
-- Depends on: operations-loop/007, bbb-foundation/006
-- Safe to re-run: Yes (CREATE OR REPLACE)
-- Applied live: 2026-07-22 — project uwyqhzotluikawcboldr
-- ============================================================================

CREATE OR REPLACE FUNCTION get_tenant_receivables(
    p_tenant_id UUID,
    p_is_live   BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_summary  JSONB;
    v_by_buyer JSONB;
    v_invoices JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    WITH inv AS (
        SELECT i.id, i.invoice_number, i.status, i.amount, i.tax_amount, i.total_amount,
               i.amount_paid, i.balance, i.currency, i.due_date, i.issued_at, i.paid_at,
               i.emi_sequence, i.emi_total, i.billing_cycle, i.payment_mode,
               i.contract_event_id, i.last_reminder_at, i.created_at,
               c.id AS contract_id, c.contract_number, c.name AS contract_name,
               c.buyer_id, c.buyer_name, c.buyer_company
        FROM t_invoices i
        JOIN t_contracts c ON c.id = i.contract_id
        WHERE i.tenant_id = p_tenant_id
          AND i.invoice_type = 'receivable'
          AND i.is_active = true
          AND COALESCE(i.is_live, true) = p_is_live
    ),
    open_inv AS (
        SELECT * FROM inv WHERE status IN ('unpaid','partially_paid')
    ),
    -- Billing-event sub-ledger, scoped to contracts that have an open invoice
    ev_base AS (
        SELECT e.id, e.contract_id, e.scheduled_date::date AS due_on,
               (e.amount - COALESCE(e.amount_settled, 0)) AS unsettled
        FROM t_contract_events e
        WHERE e.tenant_id = p_tenant_id
          AND e.event_type = 'billing'
          AND e.is_active = true
          AND COALESCE(e.is_live, true) = p_is_live
          AND COALESCE(e.status, '') NOT IN ('cancelled','skipped','waived')
          AND (e.amount - COALESCE(e.amount_settled, 0)) > 0
          AND e.contract_id IN (SELECT contract_id FROM open_inv)
    ),
    -- FIFO fallback pool: payments recorded on the contract's invoices that
    -- were never allocated to specific events (invariant drift is tolerated
    -- via GREATEST(0, ...)). Display-only — no data is changed.
    contract_unalloc AS (
        SELECT oi.contract_id,
               GREATEST(0,
                   SUM(oi.amount_paid)
                   - COALESCE((
                       SELECT SUM(COALESCE(e2.amount_settled, 0))
                       FROM t_contract_events e2
                       WHERE e2.contract_id = oi.contract_id
                         AND e2.event_type = 'billing'
                         AND e2.is_active = true
                         AND COALESCE(e2.is_live, true) = p_is_live
                         AND COALESCE(e2.status, '') NOT IN ('cancelled','skipped','waived')
                   ), 0)
               ) AS unallocated
        FROM (SELECT contract_id, amount_paid FROM inv WHERE status <> 'draft') oi
        GROUP BY oi.contract_id
    ),
    ev_fifo AS (
        SELECT eb.*,
               COALESCE(SUM(eb.unsettled) OVER (
                   PARTITION BY eb.contract_id ORDER BY eb.due_on, eb.id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cum_before
        FROM ev_base eb
    ),
    -- Open (still-owed) amount per event after FIFO-applying unallocated cash,
    -- UNION a synthetic invoice-level row for contracts with no billing events
    -- (keeps 007 semantics for non-event invoices).
    ev AS (
        SELECT f.contract_id, f.due_on,
               GREATEST(0, f.unsettled - GREATEST(0, cu.unallocated - f.cum_before)) AS open_amount,
               CASE WHEN f.due_on < CURRENT_DATE THEN CURRENT_DATE - f.due_on ELSE 0 END AS days_overdue
        FROM ev_fifo f
        JOIN contract_unalloc cu ON cu.contract_id = f.contract_id
        WHERE GREATEST(0, f.unsettled - GREATEST(0, cu.unallocated - f.cum_before)) > 0

        UNION ALL

        SELECT oi.contract_id, oi.due_date AS due_on, oi.balance AS open_amount,
               CASE WHEN oi.due_date IS NOT NULL AND oi.due_date < CURRENT_DATE
                    THEN CURRENT_DATE - oi.due_date ELSE 0 END AS days_overdue
        FROM open_inv oi
        WHERE oi.balance > 0
          AND NOT EXISTS (
              SELECT 1 FROM t_contract_events e3
              WHERE e3.contract_id = oi.contract_id
                AND e3.event_type = 'billing'
                AND e3.is_active = true
                AND COALESCE(e3.is_live, true) = p_is_live
                AND COALESCE(e3.status, '') NOT IN ('cancelled','skipped','waived')
          )
    )
    SELECT jsonb_build_object(
        'total_outstanding',  COALESCE((SELECT SUM(balance) FROM open_inv), 0),
        'outstanding_count',  (SELECT COUNT(*) FROM open_inv),
        'overdue_total',      COALESCE((SELECT SUM(open_amount) FROM ev WHERE days_overdue > 0), 0),
        'overdue_count',      (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE days_overdue > 0),
        'upcoming_7_total',   COALESCE((SELECT SUM(open_amount) FROM ev WHERE due_on >= CURRENT_DATE AND due_on <= CURRENT_DATE + 7), 0),
        'upcoming_7_count',   (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE due_on >= CURRENT_DATE AND due_on <= CURRENT_DATE + 7),
        'upcoming_15_total',  COALESCE((SELECT SUM(open_amount) FROM ev WHERE due_on >= CURRENT_DATE AND due_on <= CURRENT_DATE + 15), 0),
        'upcoming_15_count',  (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE due_on >= CURRENT_DATE AND due_on <= CURRENT_DATE + 15),
        'upcoming_30_total',  COALESCE((SELECT SUM(open_amount) FROM ev WHERE due_on >= CURRENT_DATE AND due_on <= CURRENT_DATE + 30), 0),
        'upcoming_30_count',  (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE due_on >= CURRENT_DATE AND due_on <= CURRENT_DATE + 30),
        'draft_total',        COALESCE((SELECT SUM(total_amount) FROM inv WHERE status = 'draft'), 0),
        'draft_count',        (SELECT COUNT(*) FROM inv WHERE status = 'draft'),
        'collected_total',    COALESCE((SELECT SUM(amount_paid) FROM inv), 0),
        'collected_this_month', COALESCE((
            SELECT SUM(r.amount)
            FROM t_invoice_receipts r
            JOIN t_invoices ri ON ri.id = r.invoice_id
            WHERE r.tenant_id = p_tenant_id
              AND COALESCE(r.is_active, true) = true
              AND COALESCE(ri.is_live, true) = p_is_live
              AND r.payment_date >= date_trunc('month', CURRENT_DATE)::date
        ), 0),
        'ageing', jsonb_build_object(
            'b_1_7',   jsonb_build_object(
                'total', COALESCE((SELECT SUM(open_amount) FROM ev WHERE days_overdue BETWEEN 1 AND 7), 0),
                'count', (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE days_overdue BETWEEN 1 AND 7)),
            'b_8_15',  jsonb_build_object(
                'total', COALESCE((SELECT SUM(open_amount) FROM ev WHERE days_overdue BETWEEN 8 AND 15), 0),
                'count', (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE days_overdue BETWEEN 8 AND 15)),
            'b_16_30', jsonb_build_object(
                'total', COALESCE((SELECT SUM(open_amount) FROM ev WHERE days_overdue BETWEEN 16 AND 30), 0),
                'count', (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE days_overdue BETWEEN 16 AND 30)),
            'b_30_plus', jsonb_build_object(
                'total', COALESCE((SELECT SUM(open_amount) FROM ev WHERE days_overdue > 30), 0),
                'count', (SELECT COUNT(DISTINCT contract_id) FROM ev WHERE days_overdue > 30))
        )
    )
    INTO v_summary;

    -- Who owes: outstanding = invoice balances (source of truth); overdue /
    -- oldest / max-days = event-based, so "oldest Nd overdue" is truthful.
    WITH inv AS (
        SELECT i.id, i.status, i.amount_paid, i.balance, i.due_date,
               c.id AS contract_id, c.buyer_id, c.buyer_name, c.buyer_company
        FROM t_invoices i
        JOIN t_contracts c ON c.id = i.contract_id
        WHERE i.tenant_id = p_tenant_id
          AND i.invoice_type = 'receivable'
          AND i.is_active = true
          AND COALESCE(i.is_live, true) = p_is_live
    ),
    open_inv AS (
        SELECT * FROM inv WHERE status IN ('unpaid','partially_paid')
    ),
    ev_base AS (
        SELECT e.id, e.contract_id, e.scheduled_date::date AS due_on,
               (e.amount - COALESCE(e.amount_settled, 0)) AS unsettled
        FROM t_contract_events e
        WHERE e.tenant_id = p_tenant_id
          AND e.event_type = 'billing'
          AND e.is_active = true
          AND COALESCE(e.is_live, true) = p_is_live
          AND COALESCE(e.status, '') NOT IN ('cancelled','skipped','waived')
          AND (e.amount - COALESCE(e.amount_settled, 0)) > 0
          AND e.contract_id IN (SELECT contract_id FROM open_inv)
    ),
    contract_unalloc AS (
        SELECT oi.contract_id,
               GREATEST(0,
                   SUM(oi.amount_paid)
                   - COALESCE((
                       SELECT SUM(COALESCE(e2.amount_settled, 0))
                       FROM t_contract_events e2
                       WHERE e2.contract_id = oi.contract_id
                         AND e2.event_type = 'billing'
                         AND e2.is_active = true
                         AND COALESCE(e2.is_live, true) = p_is_live
                         AND COALESCE(e2.status, '') NOT IN ('cancelled','skipped','waived')
                   ), 0)
               ) AS unallocated
        FROM (SELECT contract_id, amount_paid FROM inv WHERE status <> 'draft') oi
        GROUP BY oi.contract_id
    ),
    ev_fifo AS (
        SELECT eb.*,
               COALESCE(SUM(eb.unsettled) OVER (
                   PARTITION BY eb.contract_id ORDER BY eb.due_on, eb.id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cum_before
        FROM ev_base eb
    ),
    ev AS (
        SELECT f.contract_id, f.due_on,
               GREATEST(0, f.unsettled - GREATEST(0, cu.unallocated - f.cum_before)) AS open_amount,
               CASE WHEN f.due_on < CURRENT_DATE THEN CURRENT_DATE - f.due_on ELSE 0 END AS days_overdue
        FROM ev_fifo f
        JOIN contract_unalloc cu ON cu.contract_id = f.contract_id
        WHERE GREATEST(0, f.unsettled - GREATEST(0, cu.unallocated - f.cum_before)) > 0

        UNION ALL

        SELECT oi.contract_id, oi.due_date AS due_on, oi.balance AS open_amount,
               CASE WHEN oi.due_date IS NOT NULL AND oi.due_date < CURRENT_DATE
                    THEN CURRENT_DATE - oi.due_date ELSE 0 END AS days_overdue
        FROM open_inv oi
        WHERE oi.balance > 0
          AND NOT EXISTS (
              SELECT 1 FROM t_contract_events e3
              WHERE e3.contract_id = oi.contract_id
                AND e3.event_type = 'billing'
                AND e3.is_active = true
                AND COALESCE(e3.is_live, true) = p_is_live
                AND COALESCE(e3.status, '') NOT IN ('cancelled','skipped','waived')
          )
    ),
    ev_by_contract AS (
        SELECT contract_id,
               SUM(open_amount) FILTER (WHERE days_overdue > 0) AS overdue_total,
               MIN(due_on) AS oldest_due_date,
               MAX(days_overdue) AS max_days_overdue
        FROM ev
        GROUP BY contract_id
    )
    SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'overdue_total')::NUMERIC DESC NULLS LAST, (row_data->>'outstanding')::NUMERIC DESC), '[]'::jsonb)
    INTO v_by_buyer
    FROM (
        SELECT jsonb_build_object(
            'buyer_id',        o.buyer_id,
            'buyer_name',      COALESCE(MAX(o.buyer_company), MAX(o.buyer_name), 'Unknown'),
            'outstanding',     SUM(o.balance),
            'overdue_total',   SUM(COALESCE(ec.overdue_total, 0)),
            'invoice_count',   COUNT(*),
            'oldest_due_date', MIN(ec.oldest_due_date),
            'max_days_overdue', COALESCE(MAX(ec.max_days_overdue), 0)
        ) AS row_data
        FROM open_inv o
        LEFT JOIN ev_by_contract ec ON ec.contract_id = o.contract_id
        GROUP BY o.buyer_id
    ) g;

    -- Invoice worklist: unchanged from 007 (documents stay invoice-level)
    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY
               (x.status = 'draft') DESC, x.days_overdue DESC, x.due_date ASC NULLS LAST, x.created_at DESC), '[]'::jsonb)
    INTO v_invoices
    FROM (
        SELECT i.id, i.invoice_number, i.status, i.amount, i.tax_amount, i.total_amount,
               i.amount_paid, i.balance, i.currency, i.due_date, i.issued_at, i.paid_at,
               i.emi_sequence, i.emi_total, i.billing_cycle, i.payment_mode,
               i.contract_event_id, i.last_reminder_at, i.created_at,
               c.id AS contract_id, c.contract_number, c.name AS contract_name,
               c.buyer_id, c.buyer_name, c.buyer_company,
               CASE WHEN i.status IN ('unpaid','partially_paid') AND i.due_date IS NOT NULL
                    THEN GREATEST(0, CURRENT_DATE - i.due_date)
                    ELSE 0 END AS days_overdue
        FROM t_invoices i
        JOIN t_contracts c ON c.id = i.contract_id
        WHERE i.tenant_id = p_tenant_id
          AND i.invoice_type = 'receivable'
          AND i.is_active = true
          AND COALESCE(i.is_live, true) = p_is_live
        LIMIT 500
    ) x;

    RETURN jsonb_build_object(
        'success', true,
        'as_of', now(),
        'summary', v_summary,
        'by_buyer', v_by_buyer,
        'invoices', v_invoices
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to load receivables',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_tenant_receivables(UUID, BOOLEAN) TO service_role;
