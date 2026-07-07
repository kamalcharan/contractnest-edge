-- ============================================================================
-- Migration: Stage 1 Finance AR/AP — 007 Tenant-level finance RPCs
-- ============================================================================
-- Purpose (POA-OPERATIONS-READINESS-2026-07-07 §2, Stage 1):
--   1. get_tenant_receivables  — tenant-level AR aggregation over t_invoices:
--      totals, overdue, upcoming (7/15/30d), ageing buckets (0-7/8-15/16-30/30+),
--      who-owes (by buyer), full invoice worklist (drafts included, flagged).
--   2. get_tenant_payables     — the buyer mirror: (a) my own vendor-contract
--      invoices (invoice_type='payable'), (b) seller invoices on contracts I
--      claimed (buyer_tenant_id = me OR active t_contract_access grant).
--      Buyers NEVER see unapproved drafts.
--   3. approve_draft_invoice   — draft → unpaid + issued_at (manual approval
--      of scanner-created drafts); linked billing event → 'invoice_generated'.
--   4. send_invoice_reminder   — manual "send reminder": enqueues a
--      payment_due JTD on demand (email), updates last_reminder_*.
--   (Cancel reuses the existing cancel_or_writeoff_invoice RPC — no new code.)
--
-- Money convention: all aggregates use BALANCE (total_amount - amount_paid)
-- of is_active invoices; 'draft' status is excluded from every money total
-- and bucket — drafts are proposals, not AR.
--
-- Depends on: operations-loop/001 (columns), contracts/005/006/042/044/045,
--             jtd-framework (n_jtd + payment_due template)
-- Safe to re-run: Yes (CREATE OR REPLACE)
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 1. get_tenant_receivables
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
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
    ),
    open_inv AS (
        SELECT * FROM inv WHERE status IN ('unpaid','partially_paid')
    )
    SELECT jsonb_build_object(
        'total_outstanding',  COALESCE((SELECT SUM(balance) FROM open_inv), 0),
        'outstanding_count',  (SELECT COUNT(*) FROM open_inv),
        'overdue_total',      COALESCE((SELECT SUM(balance) FROM open_inv WHERE days_overdue > 0), 0),
        'overdue_count',      (SELECT COUNT(*) FROM open_inv WHERE days_overdue > 0),
        'upcoming_7_total',   COALESCE((SELECT SUM(balance) FROM open_inv WHERE due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 7), 0),
        'upcoming_7_count',   (SELECT COUNT(*) FROM open_inv WHERE due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 7),
        'upcoming_15_total',  COALESCE((SELECT SUM(balance) FROM open_inv WHERE due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 15), 0),
        'upcoming_15_count',  (SELECT COUNT(*) FROM open_inv WHERE due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 15),
        'upcoming_30_total',  COALESCE((SELECT SUM(balance) FROM open_inv WHERE due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 30), 0),
        'upcoming_30_count',  (SELECT COUNT(*) FROM open_inv WHERE due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 30),
        'draft_total',        COALESCE((SELECT SUM(total_amount) FROM inv WHERE status = 'draft'), 0),
        'draft_count',        (SELECT COUNT(*) FROM inv WHERE status = 'draft'),
        'collected_total',    COALESCE((SELECT SUM(amount_paid) FROM inv), 0),
        'collected_this_month', COALESCE((
            SELECT SUM(r.amount) FROM t_invoice_receipts r
            WHERE r.tenant_id = p_tenant_id
              AND COALESCE(r.is_active, true) = true
              AND r.payment_date >= date_trunc('month', CURRENT_DATE)::date
        ), 0),
        'ageing', jsonb_build_object(
            'b_1_7',   jsonb_build_object(
                'total', COALESCE((SELECT SUM(balance) FROM open_inv WHERE days_overdue BETWEEN 1 AND 7), 0),
                'count', (SELECT COUNT(*) FROM open_inv WHERE days_overdue BETWEEN 1 AND 7)),
            'b_8_15',  jsonb_build_object(
                'total', COALESCE((SELECT SUM(balance) FROM open_inv WHERE days_overdue BETWEEN 8 AND 15), 0),
                'count', (SELECT COUNT(*) FROM open_inv WHERE days_overdue BETWEEN 8 AND 15)),
            'b_16_30', jsonb_build_object(
                'total', COALESCE((SELECT SUM(balance) FROM open_inv WHERE days_overdue BETWEEN 16 AND 30), 0),
                'count', (SELECT COUNT(*) FROM open_inv WHERE days_overdue BETWEEN 16 AND 30)),
            'b_30_plus', jsonb_build_object(
                'total', COALESCE((SELECT SUM(balance) FROM open_inv WHERE days_overdue > 30), 0),
                'count', (SELECT COUNT(*) FROM open_inv WHERE days_overdue > 30))
        )
    )
    INTO v_summary;

    -- Who owes (open invoices grouped by buyer, worst first)
    SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'overdue_total')::NUMERIC DESC, (row_data->>'outstanding')::NUMERIC DESC), '[]'::jsonb)
    INTO v_by_buyer
    FROM (
        SELECT jsonb_build_object(
            'buyer_id',       buyer_id,
            'buyer_name',     COALESCE(MAX(buyer_company), MAX(buyer_name), 'Unknown'),
            'outstanding',    SUM(balance),
            'overdue_total',  SUM(balance) FILTER (WHERE days_overdue > 0),
            'invoice_count',  COUNT(*),
            'oldest_due_date', MIN(due_date),
            'max_days_overdue', MAX(days_overdue)
        ) AS row_data
        FROM (
            SELECT i.balance, i.due_date, c.buyer_id, c.buyer_name, c.buyer_company,
                   CASE WHEN i.due_date IS NOT NULL THEN GREATEST(0, CURRENT_DATE - i.due_date) ELSE 0 END AS days_overdue
            FROM t_invoices i
            JOIN t_contracts c ON c.id = i.contract_id
            WHERE i.tenant_id = p_tenant_id
              AND i.invoice_type = 'receivable'
              AND i.is_active = true
              AND COALESCE(i.is_live, true) = p_is_live
              AND i.status IN ('unpaid','partially_paid')
        ) o
        GROUP BY buyer_id
    ) g;

    -- Invoice worklist: drafts first, then most-overdue, then by due date
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

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 2. get_tenant_payables — the buyer mirror
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION get_tenant_payables(
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
    v_by_vendor JSONB;
    v_invoices JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    -- Payables scope, two legs (drafts always excluded — buyers never see
    -- unapproved proposals):
    --   (a) my own vendor-contract invoices  (i.tenant_id = me, type 'payable')
    --   (b) claimed contracts where I'm the buyer (seller's 'receivable'
    --       invoices; access via buyer_tenant_id or active t_contract_access)
    CREATE TEMP TABLE tmp_payables ON COMMIT DROP AS
        SELECT i.id, i.invoice_number, i.status, i.amount, i.tax_amount, i.total_amount,
               i.amount_paid, i.balance, i.currency, i.due_date, i.issued_at, i.paid_at,
               i.emi_sequence, i.emi_total, i.billing_cycle, i.payment_mode,
               i.contract_event_id, i.created_at,
               c.id AS contract_id, c.contract_number, c.name AS contract_name,
               CASE
                   WHEN i.tenant_id = p_tenant_id THEN COALESCE(c.buyer_company, c.buyer_name, 'Vendor')
                   ELSE seller.name
               END AS counterparty_name,
               CASE WHEN i.tenant_id = p_tenant_id THEN 'own_vendor_contract' ELSE 'claimed_contract' END AS source,
               CASE WHEN i.status IN ('unpaid','partially_paid') AND i.due_date IS NOT NULL
                    THEN GREATEST(0, CURRENT_DATE - i.due_date)
                    ELSE 0 END AS days_overdue
        FROM t_invoices i
        JOIN t_contracts c ON c.id = i.contract_id
        JOIN t_tenants seller ON seller.id = i.tenant_id
        WHERE i.is_active = true
          AND COALESCE(i.is_live, true) = p_is_live
          AND i.status <> 'draft'
          AND (
                (i.tenant_id = p_tenant_id AND i.invoice_type = 'payable')
             OR (i.tenant_id <> p_tenant_id AND i.invoice_type = 'receivable' AND (
                    c.buyer_tenant_id = p_tenant_id
                 OR EXISTS (
                        SELECT 1 FROM t_contract_access a
                        WHERE a.contract_id = c.id
                          AND a.accessor_tenant_id = p_tenant_id
                          AND a.is_active = true
                          AND (a.expires_at IS NULL OR a.expires_at > NOW())
                    )
                ))
          );

    SELECT jsonb_build_object(
        'total_payable',     COALESCE(SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid')), 0),
        'payable_count',     COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid')),
        'overdue_total',     COALESCE(SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid') AND days_overdue > 0), 0),
        'overdue_count',     COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid') AND days_overdue > 0),
        'upcoming_7_total',  COALESCE(SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid') AND due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 7), 0),
        'upcoming_7_count',  COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid') AND due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 7),
        'upcoming_15_total', COALESCE(SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid') AND due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 15), 0),
        'upcoming_15_count', COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid') AND due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 15),
        'upcoming_30_total', COALESCE(SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid') AND due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 30), 0),
        'upcoming_30_count', COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid') AND due_date >= CURRENT_DATE AND due_date <= CURRENT_DATE + 30),
        'paid_total',        COALESCE(SUM(amount_paid), 0)
    )
    INTO v_summary
    FROM tmp_payables;

    SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'overdue_total')::NUMERIC DESC, (row_data->>'outstanding')::NUMERIC DESC), '[]'::jsonb)
    INTO v_by_vendor
    FROM (
        SELECT jsonb_build_object(
            'counterparty_name', counterparty_name,
            'outstanding',       SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid')),
            'overdue_total',     COALESCE(SUM(balance) FILTER (WHERE status IN ('unpaid','partially_paid') AND days_overdue > 0), 0),
            'invoice_count',     COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid')),
            'oldest_due_date',   MIN(due_date) FILTER (WHERE status IN ('unpaid','partially_paid'))
        ) AS row_data
        FROM tmp_payables
        GROUP BY counterparty_name
        HAVING COUNT(*) FILTER (WHERE status IN ('unpaid','partially_paid')) > 0
    ) g;

    SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.days_overdue DESC, t.due_date ASC NULLS LAST, t.created_at DESC), '[]'::jsonb)
    INTO v_invoices
    FROM (SELECT * FROM tmp_payables LIMIT 500) t;

    RETURN jsonb_build_object(
        'success', true,
        'as_of', now(),
        'summary', v_summary,
        'by_vendor', v_by_vendor,
        'invoices', v_invoices
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to load payables',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_tenant_payables(UUID, BOOLEAN) TO service_role;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 3. approve_draft_invoice — draft → unpaid (manual approval)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION approve_draft_invoice(
    p_invoice_id        UUID,
    p_tenant_id         UUID,
    p_performed_by      UUID DEFAULT NULL,
    p_performed_by_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inv RECORD;
BEGIN
    IF p_invoice_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'invoice_id and tenant_id are required');
    END IF;

    SELECT * INTO v_inv
    FROM t_invoices
    WHERE id = p_invoice_id AND tenant_id = p_tenant_id AND is_active = true
    FOR UPDATE;

    IF v_inv IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found', 'error_code', 'NOT_FOUND');
    END IF;

    IF v_inv.status <> 'draft' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Only draft invoices can be approved (current status: %s)', v_inv.status),
            'error_code', 'INVALID_STATUS'
        );
    END IF;

    UPDATE t_invoices
    SET status = 'unpaid',
        issued_at = now(),
        balance = total_amount - amount_paid,
        updated_at = now()
    WHERE id = p_invoice_id;

    -- Linked billing event moves to 'invoice_generated' (billing lifecycle)
    IF v_inv.contract_event_id IS NOT NULL THEN
        UPDATE t_contract_events
        SET status = 'invoice_generated', version = version + 1,
            updated_by = p_performed_by, updated_at = now()
        WHERE id = v_inv.contract_event_id
          AND is_active = true
          AND status IN ('due', 'overdue', 'scheduled');

        IF FOUND THEN
            INSERT INTO t_contract_event_audit
                (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
            VALUES
                (v_inv.contract_event_id, p_tenant_id, 'status', NULL, 'invoice_generated',
                 p_performed_by, COALESCE(p_performed_by_name, 'Finance'), 'Invoice approved: ' || v_inv.invoice_number);
        END IF;
    END IF;

    INSERT INTO t_contract_history
        (contract_id, tenant_id, action, from_status, to_status, changes,
         performed_by_type, performed_by_id, performed_by_name, note)
    VALUES
        (v_inv.contract_id, p_tenant_id, 'invoice_approved', 'draft', 'unpaid',
         jsonb_build_object('invoice_id', v_inv.id, 'invoice_number', v_inv.invoice_number, 'total_amount', v_inv.total_amount),
         CASE WHEN p_performed_by IS NULL THEN 'system' ELSE 'user' END,
         p_performed_by, p_performed_by_name,
         format('Invoice %s approved (draft → unpaid)', v_inv.invoice_number));

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', v_inv.id,
            'invoice_number', v_inv.invoice_number,
            'status', 'unpaid',
            'issued_at', now(),
            'total_amount', v_inv.total_amount,
            'balance', v_inv.total_amount - v_inv.amount_paid
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to approve invoice',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION approve_draft_invoice(UUID, UUID, UUID, TEXT) TO service_role;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 4. send_invoice_reminder — manual payment_due JTD, on demand
--    (unlike the scanner's one-shot, manual sends are always allowed)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION send_invoice_reminder(
    p_invoice_id        UUID,
    p_tenant_id         UUID,
    p_performed_by      UUID DEFAULT NULL,
    p_performed_by_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_row    RECORD;
    v_email  TEXT;
    v_vars   JSONB;
    v_jtd_id UUID;
BEGIN
    IF p_invoice_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'invoice_id and tenant_id are required');
    END IF;

    SELECT i.id, i.invoice_number, i.balance, i.currency, i.due_date, i.is_live, i.status,
           c.id AS contract_id, c.contract_number,
           c.buyer_id, c.buyer_name, c.buyer_email,
           t.name AS tenant_name
    INTO v_row
    FROM t_invoices i
    JOIN t_contracts c ON c.id = i.contract_id
    JOIN t_tenants t ON t.id = i.tenant_id
    WHERE i.id = p_invoice_id AND i.tenant_id = p_tenant_id AND i.is_active = true
    FOR UPDATE OF i;

    IF v_row IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found', 'error_code', 'NOT_FOUND');
    END IF;

    IF v_row.status NOT IN ('unpaid', 'partially_paid') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Reminders can only be sent for open invoices (current status: %s)', v_row.status),
            'error_code', 'INVALID_STATUS'
        );
    END IF;

    v_email := COALESCE(
        NULLIF(TRIM(v_row.buyer_email), ''),
        (SELECT ch.value FROM t_contact_channels ch
         WHERE ch.contact_id = v_row.buyer_id AND ch.channel_type = 'email'
           AND NULLIF(TRIM(ch.value), '') IS NOT NULL
         ORDER BY ch.is_primary DESC NULLS LAST, ch.created_at
         LIMIT 1));

    IF v_email IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'The buyer has no email contact — add an email to the buyer contact to send reminders',
            'error_code', 'NO_EMAIL_CONTACT'
        );
    END IF;

    v_vars := jsonb_build_object(
        'customer_name',  COALESCE(v_row.buyer_name, 'Customer'),
        'invoice_number', v_row.invoice_number,
        'amount',         COALESCE(v_row.currency, 'INR') || ' ' || to_char(v_row.balance, 'FM999,999,999,990.00'),
        'due_date',       COALESCE(to_char(v_row.due_date, 'DD Mon YYYY'), '—'),
        'tenant_name',    v_row.tenant_name
    );

    INSERT INTO n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code,
        source_id, source_ref,
        recipient_type, recipient_id, recipient_name, recipient_contact,
        payload, template_key, template_variables, business_context,
        performed_by_type, performed_by_id, performed_by_name, is_live, created_by
    ) VALUES (
        p_tenant_id, 'reminder', 'email', 'payment_due',
        v_row.id, v_row.invoice_number,
        'contact', v_row.buyer_id, v_row.buyer_name, v_email,
        jsonb_build_object(
            'recipient_data', jsonb_strip_nulls(jsonb_build_object('name', v_row.buyer_name, 'email', v_email)),
            'template_data', v_vars
        ),
        'payment_due_email_v1', v_vars,
        jsonb_build_object(
            'contract_id',     v_row.contract_id,
            'contract_number', v_row.contract_number,
            'invoice_id',      v_row.id,
            'origin',          'manual_send_reminder'
        ),
        CASE WHEN p_performed_by IS NULL THEN 'system' ELSE 'user' END,
        p_performed_by, COALESCE(p_performed_by_name, 'Finance'),
        COALESCE(v_row.is_live, true), p_performed_by
    )
    RETURNING id INTO v_jtd_id;

    UPDATE t_invoices
    SET last_reminder_jtd_id = v_jtd_id, last_reminder_at = now(), updated_at = now()
    WHERE id = v_row.id;

    INSERT INTO t_contract_history
        (contract_id, tenant_id, action, changes,
         performed_by_type, performed_by_id, performed_by_name, note)
    VALUES
        (v_row.contract_id, p_tenant_id, 'invoice_reminder_sent',
         jsonb_build_object('invoice_id', v_row.id, 'invoice_number', v_row.invoice_number, 'jtd_id', v_jtd_id, 'channel', 'email', 'recipient', v_email),
         CASE WHEN p_performed_by IS NULL THEN 'system' ELSE 'user' END,
         p_performed_by, p_performed_by_name,
         format('Payment reminder sent for %s to %s', v_row.invoice_number, v_email));

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'jtd_id', v_jtd_id,
            'channel', 'email',
            'recipient', v_email,
            'invoice_number', v_row.invoice_number,
            'sent_at', now()
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to send reminder',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION send_invoice_reminder(UUID, UUID, UUID, TEXT) TO service_role;
