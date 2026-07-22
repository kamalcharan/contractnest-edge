-- ============================================================================
-- Migration: operations-loop/021 — Receivables events schedule (additive)
-- ============================================================================
-- Purpose (Finance redesign, owner-approved 2026-07-22):
--   The redesigned /ops/finance page (cash timeline + smart filter + grouped
--   worklist with expandable instalment schedules) needs the per-event detail
--   behind the summary that 020 introduced. This migration adds an `events`
--   array to get_tenant_receivables' response — every billing event (settled
--   AND open) on contracts that have an open invoice, with its FIFO-adjusted
--   open amount, so the client can filter by month/contact/contract and
--   render schedules without extra round-trips.
--
--   ADDITIVE ONLY: summary / by_buyer / invoices are byte-identical to 020.
--   Existing consumers are unaffected. Events are capped at 1000 (ordered by
--   due date); contracts with an open invoice but no billing events get one
--   synthetic invoice-level row so they still appear in the worklist.
--
-- Depends on: operations-loop/020, bbb-foundation/006
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
    v_events   JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    -- ── Summary (identical to 020: event-aware ageing with FIFO fallback) ──
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

    -- ── Who owes (identical to 020) ──
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

    -- ── NEW: full billing-event schedule for open contracts ──
    -- Every non-cancelled billing event on a contract with an open invoice —
    -- settled ones included (open_amount = 0) so the client can render the
    -- complete instalment schedule. Synthetic invoice-level row for contracts
    -- with no billing events. Capped at 1000 by due date.
    WITH inv AS (
        SELECT i.id, i.invoice_number, i.status, i.amount_paid, i.balance,
               i.total_amount, i.due_date, i.created_at,
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
    first_open_inv AS (
        SELECT DISTINCT ON (contract_id) contract_id, id AS invoice_id, invoice_number,
               contract_number, contract_name, buyer_id, buyer_name, buyer_company
        FROM open_inv
        ORDER BY contract_id, created_at ASC
    ),
    ev_all AS (
        SELECT e.id, e.contract_id, e.scheduled_date::date AS due_on,
               e.amount, COALESCE(e.amount_settled, 0) AS amount_settled,
               GREATEST(e.amount - COALESCE(e.amount_settled, 0), 0) AS unsettled,
               e.block_name, e.sequence_number, e.total_occurrences,
               e.billing_cycle_label, e.status
        FROM t_contract_events e
        WHERE e.tenant_id = p_tenant_id
          AND e.event_type = 'billing'
          AND e.is_active = true
          AND COALESCE(e.is_live, true) = p_is_live
          AND COALESCE(e.status, '') NOT IN ('cancelled','skipped','waived')
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
        SELECT ea.*,
               COALESCE(SUM(ea.unsettled) OVER (
                   PARTITION BY ea.contract_id ORDER BY ea.due_on, ea.id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cum_before
        FROM ev_all ea
    ),
    ev_open AS (
        SELECT f.id, f.contract_id, f.due_on, f.amount, f.block_name,
               f.sequence_number, f.total_occurrences, f.billing_cycle_label, f.status,
               GREATEST(0, f.unsettled - GREATEST(0, cu.unallocated - f.cum_before)) AS open_amount
        FROM ev_fifo f
        JOIN contract_unalloc cu ON cu.contract_id = f.contract_id

        UNION ALL

        SELECT NULL::uuid, oi.contract_id, oi.due_date, oi.balance, 'Invoice'::text,
               NULL::int, NULL::int, NULL::text, oi.status,
               oi.balance
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
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',                 x.id,
        'contract_id',        x.contract_id,
        'contract_number',    fo.contract_number,
        'contract_name',      fo.contract_name,
        'buyer_id',           fo.buyer_id,
        'buyer_name',         fo.buyer_name,
        'buyer_company',      fo.buyer_company,
        'invoice_id',         fo.invoice_id,
        'invoice_number',     fo.invoice_number,
        'block_name',         x.block_name,
        'sequence_number',    x.sequence_number,
        'total_occurrences',  x.total_occurrences,
        'billing_cycle_label', x.billing_cycle_label,
        'event_status',       x.status,
        'due_on',             x.due_on,
        'amount',             x.amount,
        'open_amount',        x.open_amount,
        'settled',            (x.open_amount <= 0),
        'days_overdue',       CASE WHEN x.open_amount > 0 AND x.due_on IS NOT NULL AND x.due_on < CURRENT_DATE
                                   THEN CURRENT_DATE - x.due_on ELSE 0 END
    ) ORDER BY x.due_on ASC NULLS LAST, x.id), '[]'::jsonb)
    INTO v_events
    FROM (SELECT * FROM ev_open ORDER BY due_on ASC NULLS LAST LIMIT 1000) x
    JOIN first_open_inv fo ON fo.contract_id = x.contract_id;

    -- ── Invoice worklist (identical to 020) ──
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
        'events', v_events,
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
