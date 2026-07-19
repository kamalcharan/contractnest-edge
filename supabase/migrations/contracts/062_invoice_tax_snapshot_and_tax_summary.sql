-- ═══════════════════════════════════════════════════════════════
-- Migration 062: Invoice tax snapshot + tenant tax summary RPC
-- Sprint 4 (re-scoped) — tax records only (not GST-specific; the same
-- mechanism covers VAT/other regimes once non-IN tenants exist).
-- Discount compliance on
-- t_invoices is a deliberately separate follow-up (see spec hand-off).
-- ═══════════════════════════════════════════════════════════════
--
-- PROBLEM:
--   t_invoices.tax_amount is a single lump number — there is no
--   point-in-time snapshot of the CGST/SGST/IGST component split
--   (t_contracts.tax_breakdown exists and is correct; invoices don't
--   capture it). There is also no month-wise tax reporting anywhere,
--   so a tenant cannot answer "what tax did I invoice/collect in
--   June" for filing.
--
-- SAFETY CHECK PERFORMED BEFORE WRITING THIS (live data, 2026-07-19):
--   - 0 invoices found where tax_amount=0 but the linked contract has
--     tax_total > 0 (i.e. generate_contract_invoices has never
--     mis-copied tax on any live invoice).
--   - 0 invoices found where total_amount != contract.grand_total.
--   - 0 contracts currently carry discount_total > 0 (the discount
--     stitch shipped after these 27 invoices existed) — so backfilling
--     tax_breakdown from the CURRENT contract row is safe; there is no
--     known case of a contract's tax changing after its invoice issued.
--
-- SCOPE (deliberately narrow):
--   1. t_invoices gains a `tax_breakdown` JSONB snapshot column
--      (mirrors the existing t_contracts.tax_breakdown shape —
--      see contracts/008_tax_breakdown_column.sql).
--   2. generate_contract_invoices copies the contract's tax_breakdown
--      onto the invoice at creation time (point-in-time snapshot, so
--      later contract edits cannot silently change a filed period).
--   3. New read-only RPC get_tenant_tax_summary — month-wise (by
--      issued_at, i.e. invoice-issuance/accrual basis) taxable value,
--      tax invoiced, tax collected (approximate), and component
--      split (e.g. CGST/SGST/IGST), for the /ops/finance "Taxes" NAV.
--
-- OUT OF SCOPE (flagged, not touched here):
--   - The VaNi scanner's per-event DRAFT invoice path
--     (operations-loop/013_stage3_scanner_v2.sql, STEP 4) hardcodes
--     tax_amount=0 on scanner-created drafts. Zero draft invoices
--     exist in production today (verified live), so this is a latent
--     defect, not a live undercount — but it WILL undercount tax the
--     first time the scanner mints a draft. That function has been
--     patched across 6 separate migration files; reproducing it here
--     without reading its full, multiply-patched live definition
--     first would be higher-risk than this migration's actual ask.
--     Recommend a dedicated, narrowly-reviewed follow-up once the
--     draft-invoice path is actually in use.
--   - t_invoices discount_total / subtotal (deferred — "next point").
--
-- ROLLBACK: tax_breakdown is nullable with a safe default; dropping
-- the column and reverting generate_contract_invoices to migration
-- 006's body is sufficient to fully undo this file.
-- ═══════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- 1. t_invoices.tax_breakdown — point-in-time tax component snapshot
-- ─────────────────────────────────────────────────────────────
ALTER TABLE t_invoices
    ADD COLUMN IF NOT EXISTS tax_breakdown JSONB DEFAULT '[]'::JSONB;

COMMENT ON COLUMN t_invoices.tax_breakdown IS
    'Point-in-time snapshot of applied tax rates at invoice generation: [{tax_rate_id, name, rate, amount}]. Mirrors t_contracts.tax_breakdown; does not change if the contract is edited later.';


-- ─────────────────────────────────────────────────────────────
-- 2. generate_contract_invoices — reproduced verbatim from
--    contracts/006_invoice_rpc_functions.sql (verified against the
--    live function body before this edit), with tax_breakdown added
--    to the single INSERT. No other behavior changes.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_contract_invoices(
    p_contract_id UUID,
    p_tenant_id UUID,
    p_created_by UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract RECORD;
    v_invoice_type VARCHAR(20);
    v_seq_result JSONB;
    v_invoice_number VARCHAR(30);
    v_invoice_id UUID;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Fetch contract + validate
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    -- Don't generate if not active
    -- Don't generate if not in allowed status
    -- Allow 'active' always, and 'pending_acceptance' for payment-acceptance contracts
    -- (acceptance_method = 'manual' = payment acceptance in DB)
    IF v_contract.status <> 'active' AND NOT (
        v_contract.status = 'pending_acceptance' AND v_contract.acceptance_method = 'manual'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract must be active to generate invoices (payment-acceptance contracts generate at pending_acceptance)',
            'current_status', v_contract.status
        );
    END IF;


    -- Don't generate if invoices already exist
    IF EXISTS (
        SELECT 1 FROM t_invoices
        WHERE contract_id = p_contract_id AND is_active = true
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoices already generated for this contract'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Determine AR/AP from contract_type
    --   client  → client pays tenant  → Receivable (AR)
    --   vendor  → tenant pays vendor  → Payable (AP)
    --   partner → default to AR
    -- ═══════════════════════════════════════════
    v_invoice_type := CASE v_contract.contract_type
        WHEN 'vendor' THEN 'payable'
        ELSE 'receivable'
    END;

    -- ═══════════════════════════════════════════
    -- STEP 2: Generate sequence number
    -- ═══════════════════════════════════════════
    v_seq_result := get_next_formatted_sequence('INVOICE', p_tenant_id, v_contract.is_live);
    v_invoice_number := v_seq_result->>'formatted';

    -- ═══════════════════════════════════════════
    -- STEP 3: Create single invoice for grand_total
    --   Regardless of payment_mode (prepaid/emi/defined),
    --   always 1 invoice. Payments are tracked via receipts.
    --   tax_breakdown is a point-in-time snapshot (new, Sprint 4).
    -- ═══════════════════════════════════════════
    INSERT INTO t_invoices (
        contract_id, tenant_id, invoice_number, invoice_type,
        amount, tax_amount, total_amount, currency,
        balance, status, payment_mode,
        emi_total,
        due_date, issued_at,
        is_live, created_by,
        tax_breakdown
    ) VALUES (
        p_contract_id, p_tenant_id, v_invoice_number, v_invoice_type,
        COALESCE(v_contract.total_value, 0),
        COALESCE(v_contract.tax_total, 0),
        COALESCE(v_contract.grand_total, 0),
        COALESCE(v_contract.currency, 'INR'),
        COALESCE(v_contract.grand_total, 0),  -- balance = total at creation
        'unpaid',
        COALESCE(v_contract.payment_mode, 'prepaid'),
        CASE WHEN v_contract.payment_mode = 'emi'
             THEN v_contract.emi_months
             ELSE NULL
        END,
        CURRENT_DATE, NOW(),
        v_contract.is_live, p_created_by,
        COALESCE(v_contract.tax_breakdown, '[]'::jsonb)
    )
    RETURNING id INTO v_invoice_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Return summary
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract_id', p_contract_id,
            'invoice_id', v_invoice_id,
            'invoice_number', v_invoice_number,
            'invoice_type', v_invoice_type,
            'payment_mode', COALESCE(v_contract.payment_mode, 'prepaid'),
            'emi_months', v_contract.emi_months,
            'total_amount', COALESCE(v_contract.grand_total, 0),
            'currency', COALESCE(v_contract.currency, 'INR')
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to generate invoices',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION generate_contract_invoices(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION generate_contract_invoices(UUID, UUID, UUID) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 3. get_tenant_tax_summary — month-wise tax records (new, read-only)
--    Basis: invoice ISSUANCE (accrual) — issued_at IS NOT NULL, so
--    unissued drafts are excluded (they carry no tax liability yet).
--    tax_collected_approx is a proportional estimate — there is no
--    per-payment tax split in the schema (a receipt against an
--    invoice doesn't record how much of that receipt was "tax");
--    it approximates via tax_amount * (amount_paid / total_amount).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_tenant_tax_summary(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_months JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    WITH base AS (
        SELECT
            to_char(i.issued_at, 'YYYY-MM') AS month,
            i.id,
            i.amount,
            i.tax_amount,
            i.total_amount,
            i.amount_paid,
            i.tax_breakdown
        FROM t_invoices i
        WHERE i.tenant_id = p_tenant_id
          AND i.is_live = p_is_live
          AND i.is_active = true
          AND i.issued_at IS NOT NULL
    ),
    monthly AS (
        SELECT
            month,
            COUNT(*) AS invoice_count,
            SUM(amount) AS taxable_value,
            SUM(tax_amount) AS tax_invoiced,
            SUM(total_amount) AS total_invoiced,
            SUM(amount_paid) AS collected_value,
            SUM(
                CASE WHEN COALESCE(total_amount, 0) > 0
                     THEN tax_amount * (amount_paid / total_amount)
                     ELSE 0
                END
            ) AS tax_collected_approx
        FROM base
        GROUP BY month
    ),
    components AS (
        SELECT
            b.month,
            COALESCE(comp->>'name', 'Tax') AS component_name,
            SUM(COALESCE((comp->>'amount')::numeric, 0)) AS component_amount
        FROM base b
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(b.tax_breakdown, '[]'::jsonb)) AS comp
        GROUP BY b.month, COALESCE(comp->>'name', 'Tax')
    ),
    components_agg AS (
        SELECT
            month,
            jsonb_agg(
                jsonb_build_object('name', component_name, 'amount', ROUND(component_amount, 2))
                ORDER BY component_name
            ) AS components
        FROM components
        GROUP BY month
    )
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'month', m.month,
                'invoice_count', m.invoice_count,
                'taxable_value', ROUND(m.taxable_value, 2),
                'tax_invoiced', ROUND(m.tax_invoiced, 2),
                'total_invoiced', ROUND(m.total_invoiced, 2),
                'collected_value', ROUND(m.collected_value, 2),
                'tax_collected_approx', ROUND(m.tax_collected_approx, 2),
                'components', COALESCE(ca.components, '[]'::jsonb)
            )
            ORDER BY m.month DESC
        ),
        '[]'::JSONB
    )
    INTO v_months
    FROM monthly m
    LEFT JOIN components_agg ca ON ca.month = m.month;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'months', v_months,
            'basis', 'invoice_issuance',
            'note', 'tax_collected_approx is a proportional estimate (tax_amount * amount_paid/total_amount) — no per-payment tax split exists in the schema yet.'
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to compute tax summary',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_tenant_tax_summary(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION get_tenant_tax_summary(UUID, BOOLEAN) TO service_role;
