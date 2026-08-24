-- ═══════════════════════════════════════════════════════════════════
-- subscriptions/002_plan_tax_from_settings_and_tax_summary_v2.sql
-- GST for platform plan sales + split-capable tax summary
-- (owner-approved "build complete things", 2026-08-24)
--
-- OWNER'S FRAMING (correct, and this follows it): there is no
-- subscription infrastructure — subscribe_tenant_to_plan is a payload
-- builder over the SAME contract engine everything uses. If the
-- CONTRACT carries tax, generate_contract_invoices copies it to the
-- invoice verbatim and the tax-records surface lights up. The one gap
-- was the payload builder writing tax_total: 0.
--
-- A ── subscribe_tenant_to_plan: tax from the SELLER's Tax Settings
--   Reads t_tax_settings.display_mode + active t_tax_rates for the
--   platform tenant at subscribe time:
--     no_tax / no active rates → exactly today's behavior (zeros)
--     including_tax → sticker stays (₹23,996): taxable = P/(1+r),
--       tax carved out; billing events (customer instalments) UNCHANGED
--     excluding_tax → tax added on top: grand = P×(1+r); every billing
--       event grossed up by the same factor so instalments still sum to
--       the invoice and due_now still equals the first instalment
--   Contract gains selected_tax_rate_ids + tax_total + tax_breakdown
--   ([{tax_rate_id, name, rate, amount}] — the wizard's exact shape;
--   last component absorbs rounding so components always sum to
--   tax_total). Everything downstream is untouched machinery.
--
-- B ── get_tenant_tax_summary_v2(tenant, is_live, invoice_type default null)
--   NEW sibling (V1 untouched): same month-wise shape, plus an optional
--   invoice_type filter so Money In (receivable/output GST) and To Pay
--   (payable/input GST) can each show their own number. NULL = both,
--   byte-equivalent to V1.
--
-- Method: A is a verified-anchor prosrc substitution (aborts if the
-- live function drifted; marker-guarded so re-running no-ops).
-- APPLIED LIVE 2026-08-24 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

-- ── A: subscribe_tenant_to_plan computes tax from Tax Settings ──────
DO $do$
DECLARE
    v_def TEXT;
    v_anchor_decl    TEXT := 'v_due_now          NUMERIC;';
    v_anchor_payload TEXT := 'v_payload := jsonb_build_object(';
    v_anchor_grand   TEXT := '''grand_total'',       COALESCE(v_template.total, 0),';
    v_anchor_totalv  TEXT := '''total_value'',       COALESCE(v_template.total, 0),';
    v_anchor_tax     TEXT := '''tax_total'',         0,';
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'subscribe_tenant_to_plan' AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'subscribe_tenant_to_plan not found';
    END IF;

    IF position('v_tax_mode' in v_def) > 0 THEN
        RAISE NOTICE 'subscribe_tenant_to_plan already tax-aware — skipping';
        RETURN;
    END IF;

    IF (length(v_def) - length(replace(v_def, v_anchor_decl, ''))) / length(v_anchor_decl) <> 1 THEN
        RAISE EXCEPTION 'declare anchor not found exactly once — run subscriptions/001 first / function drifted';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_payload, ''))) / length(v_anchor_payload) <> 1 THEN
        RAISE EXCEPTION 'payload anchor not found exactly once — aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_grand, ''))) / length(v_anchor_grand) <> 1 THEN
        RAISE EXCEPTION 'grand_total anchor not found exactly once — aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_totalv, ''))) / length(v_anchor_totalv) <> 1 THEN
        RAISE EXCEPTION 'total_value anchor not found exactly once — aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_tax, ''))) / length(v_anchor_tax) <> 1 THEN
        RAISE EXCEPTION 'tax_total anchor not found exactly once — aborting';
    END IF;

    -- new declarations
    v_def := replace(v_def, v_anchor_decl, v_anchor_decl || E'\n' ||
        '    v_tax_mode         TEXT;' || E'\n' ||
        '    v_tax_rate_sum     NUMERIC := 0;' || E'\n' ||
        '    v_tax_rate_ids     JSONB := ''[]''::jsonb;' || E'\n' ||
        '    v_tax_breakdown    JSONB := ''[]''::jsonb;' || E'\n' ||
        '    v_gross_total      NUMERIC;' || E'\n' ||
        '    v_taxable_total    NUMERIC;' || E'\n' ||
        '    v_plan_tax_total   NUMERIC := 0;' || E'\n' ||
        '    v_gross_factor     NUMERIC := 1;' || E'\n' ||
        '    v_tax_rate         RECORD;' || E'\n' ||
        '    v_tax_alloc        NUMERIC := 0;' || E'\n' ||
        '    v_tax_rate_count   INTEGER := 0;' || E'\n' ||
        '    v_tax_rate_seen    INTEGER := 0;');

    -- computation block, immediately before the payload is built
    v_def := replace(v_def, v_anchor_payload,
        '-- ── Tax from the SELLER''s Tax Settings (subscriptions/002) ──' || E'\n' ||
        '    -- The plan payload previously hardcoded tax_total: 0, creating the' || E'\n' ||
        '    -- contract as if the seller never configured tax. Now it honors' || E'\n' ||
        '    -- t_tax_settings.display_mode + active t_tax_rates, and everything' || E'\n' ||
        '    -- downstream (invoice tax fields, tax records) is untouched machinery.' || E'\n' ||
        '    v_gross_total   := COALESCE(v_template.total, 0);' || E'\n' ||
        '    v_taxable_total := v_gross_total;' || E'\n' ||
        '    SELECT display_mode INTO v_tax_mode FROM t_tax_settings WHERE tenant_id = v_platform_id;' || E'\n' ||
        '    IF v_gross_total > 0 AND COALESCE(v_tax_mode, ''no_tax'') IN (''including_tax'', ''excluding_tax'') THEN' || E'\n' ||
        '        SELECT COALESCE(SUM(rate), 0), COUNT(*) INTO v_tax_rate_sum, v_tax_rate_count' || E'\n' ||
        '        FROM t_tax_rates WHERE tenant_id = v_platform_id AND is_active = true;' || E'\n' ||
        '        IF v_tax_rate_sum > 0 THEN' || E'\n' ||
        '            IF v_tax_mode = ''including_tax'' THEN' || E'\n' ||
        '                -- sticker price keeps: carve tax out of it' || E'\n' ||
        '                v_taxable_total  := ROUND(v_gross_total / (1 + v_tax_rate_sum / 100), 2);' || E'\n' ||
        '                v_plan_tax_total := ROUND(v_gross_total - v_taxable_total, 2);' || E'\n' ||
        '            ELSE' || E'\n' ||
        '                -- excluding: tax on top; instalments gross up by the same' || E'\n' ||
        '                -- factor so events still sum to the invoice total and' || E'\n' ||
        '                -- due_now stays "the first instalment the customer pays"' || E'\n' ||
        '                v_plan_tax_total := ROUND(v_gross_total * v_tax_rate_sum / 100, 2);' || E'\n' ||
        '                v_gross_total    := ROUND(v_taxable_total + v_plan_tax_total, 2);' || E'\n' ||
        '                v_gross_factor   := 1 + v_tax_rate_sum / 100;' || E'\n' ||
        '            END IF;' || E'\n' ||
        '            -- components in the wizard''s exact shape; the LAST one absorbs' || E'\n' ||
        '            -- rounding so components always sum to tax_total' || E'\n' ||
        '            FOR v_tax_rate IN' || E'\n' ||
        '                SELECT id, name, rate FROM t_tax_rates' || E'\n' ||
        '                WHERE tenant_id = v_platform_id AND is_active = true' || E'\n' ||
        '                ORDER BY sequence_no, name' || E'\n' ||
        '            LOOP' || E'\n' ||
        '                v_tax_rate_seen := v_tax_rate_seen + 1;' || E'\n' ||
        '                v_tax_rate_ids  := v_tax_rate_ids || to_jsonb(v_tax_rate.id::text);' || E'\n' ||
        '                v_tax_breakdown := v_tax_breakdown || jsonb_build_array(jsonb_build_object(' || E'\n' ||
        '                    ''tax_rate_id'', v_tax_rate.id,' || E'\n' ||
        '                    ''name'',        v_tax_rate.name,' || E'\n' ||
        '                    ''rate'',        v_tax_rate.rate,' || E'\n' ||
        '                    ''amount'',      CASE WHEN v_tax_rate_seen = v_tax_rate_count' || E'\n' ||
        '                                         THEN ROUND(v_plan_tax_total - v_tax_alloc, 2)' || E'\n' ||
        '                                         ELSE ROUND(v_plan_tax_total * v_tax_rate.rate / v_tax_rate_sum, 2) END));' || E'\n' ||
        '                IF v_tax_rate_seen < v_tax_rate_count THEN' || E'\n' ||
        '                    v_tax_alloc := v_tax_alloc + ROUND(v_plan_tax_total * v_tax_rate.rate / v_tax_rate_sum, 2);' || E'\n' ||
        '                END IF;' || E'\n' ||
        '            END LOOP;' || E'\n' ||
        '            IF v_gross_factor <> 1 THEN' || E'\n' ||
        '                SELECT jsonb_agg(CASE WHEN COALESCE(t.e->>''event_type'', ''billing'') = ''billing''' || E'\n' ||
        '                                      THEN jsonb_set(t.e, ''{amount}'', to_jsonb(ROUND((t.e->>''amount'')::numeric * v_gross_factor, 2)))' || E'\n' ||
        '                                      ELSE t.e END ORDER BY t.ord)' || E'\n' ||
        '                INTO v_events' || E'\n' ||
        '                FROM jsonb_array_elements(COALESCE(v_events, ''[]''::jsonb)) WITH ORDINALITY AS t(e, ord);' || E'\n' ||
        '            END IF;' || E'\n' ||
        '        END IF;' || E'\n' ||
        '    END IF;' || E'\n\n' ||
        '    ' || v_anchor_payload);

    -- payload fields: taxable / tax / gross, plus the two tax keys the
    -- wizard sends and create_contract_transaction already understands
    v_def := replace(v_def, v_anchor_grand,  '''grand_total'',       v_gross_total,');
    v_def := replace(v_def, v_anchor_totalv, '''total_value'',       v_taxable_total,');
    v_def := replace(v_def, v_anchor_tax,
        '''tax_total'',         v_plan_tax_total,' || E'\n' ||
        '        ''selected_tax_rate_ids'', v_tax_rate_ids,' || E'\n' ||
        '        ''tax_breakdown'',     v_tax_breakdown,');

    EXECUTE v_def;

    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'subscribe_tenant_to_plan' AND pronamespace = 'public'::regnamespace;
    IF position('v_tax_mode' in v_def) = 0 OR position('v_plan_tax_total' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: tax computation not present after apply';
    END IF;
    RAISE NOTICE 'subscribe_tenant_to_plan: tax-from-settings installed and verified';
END
$do$;

-- ── B: get_tenant_tax_summary_v2 — optional receivable/payable split ─
CREATE OR REPLACE FUNCTION public.get_tenant_tax_summary_v2(
    p_tenant_id    uuid,
    p_is_live      boolean,
    p_invoice_type text DEFAULT NULL   -- 'receivable' | 'payable' | NULL (both = V1 behavior)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_months JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    WITH base AS (
        SELECT
            to_char(i.issued_at, 'YYYY-MM') AS month,
            i.id, i.amount, i.tax_amount, i.total_amount, i.amount_paid, i.tax_breakdown
        FROM t_invoices i
        WHERE i.tenant_id = p_tenant_id
          AND i.is_live = p_is_live
          AND i.is_active = true
          AND i.issued_at IS NOT NULL
          AND (p_invoice_type IS NULL OR i.invoice_type = p_invoice_type)
    ),
    monthly AS (
        SELECT month,
            COUNT(*) AS invoice_count,
            SUM(amount) AS taxable_value,
            SUM(tax_amount) AS tax_invoiced,
            SUM(total_amount) AS total_invoiced,
            SUM(amount_paid) AS collected_value,
            SUM(CASE WHEN COALESCE(total_amount, 0) > 0
                     THEN tax_amount * (amount_paid / total_amount) ELSE 0 END) AS tax_collected_approx
        FROM base GROUP BY month
    ),
    components AS (
        SELECT b.month,
            COALESCE(comp->>'name', 'Tax') AS component_name,
            SUM(COALESCE((comp->>'amount')::numeric, 0)) AS component_amount
        FROM base b
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(b.tax_breakdown, '[]'::jsonb)) AS comp
        GROUP BY b.month, COALESCE(comp->>'name', 'Tax')
    ),
    components_agg AS (
        SELECT month,
            jsonb_agg(jsonb_build_object('name', component_name, 'amount', ROUND(component_amount, 2))
                      ORDER BY component_name) AS components
        FROM components GROUP BY month
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'month', m.month,
            'invoice_count', m.invoice_count,
            'taxable_value', ROUND(m.taxable_value, 2),
            'tax_invoiced', ROUND(m.tax_invoiced, 2),
            'total_invoiced', ROUND(m.total_invoiced, 2),
            'collected_value', ROUND(m.collected_value, 2),
            'tax_collected_approx', ROUND(m.tax_collected_approx, 2),
            'components', COALESCE(ca.components, '[]'::jsonb)
        ) ORDER BY m.month DESC), '[]'::JSONB)
    INTO v_months
    FROM monthly m
    LEFT JOIN components_agg ca ON ca.month = m.month;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'months', v_months,
            'basis', 'invoice_issuance',
            'invoice_type', COALESCE(p_invoice_type, 'all'),
            'note', 'tax_collected_approx is a proportional estimate (tax_amount * amount_paid/total_amount) — no per-payment tax split exists in the schema yet.'
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false, 'error', 'Failed to compute tax summary',
        'details', SQLERRM, 'error_code', SQLSTATE
    );
END;
$function$;

COMMENT ON FUNCTION public.get_tenant_tax_summary_v2 IS
'Month-wise tax records with an optional receivable/payable split (NULL = both, byte-equivalent to get_tenant_tax_summary). Feeds the Money In / To Pay GST cards and the /taxes page. V1 untouched.';
