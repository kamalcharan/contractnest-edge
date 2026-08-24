-- ═══════════════════════════════════════════════════════════════════
-- subscriptions/003_topup_tax_from_settings.sql
-- GST for credit-pack / top-up purchases (completes "platform sales
-- carry tax" — same gap subscriptions/002 fixed for plans, same fix).
--
-- purchase_topup_template is the OTHER payload builder over the shared
-- contract engine, and it still wrote tax_total: 0. Identical splice:
-- read the seller's (platform tenant's) t_tax_settings.display_mode +
-- active t_tax_rates at purchase time —
--   no_tax / no rates → today's zeros
--   including_tax     → sticker keeps: taxable = P/(1+r), tax carved out
--   excluding_tax     → tax on top: grand = P×(1+r); any billing events
--                       gross up by the same factor
-- Contract gains selected_tax_rate_ids + tax_total + tax_breakdown
-- (wizard shape, last component absorbs rounding) → invoice inherits
-- via generate_contract_invoices → tax records page reports it.
-- Packs are one-shot: the checkout charges the response's
-- invoice_amount, which comes from the invoice row — so the collected
-- amount is automatically the tax-correct total in either mode.
--
-- Method: verified-anchor prosrc substitution, marker-guarded
-- (re-running no-ops). APPLIED LIVE 2026-08-24 — source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_def TEXT;
    v_anchor_decl    TEXT := 'v_invoice_currency TEXT;';
    v_anchor_payload TEXT := 'v_payload := jsonb_build_object(';
    v_anchor_grand   TEXT := '''grand_total'',       COALESCE(v_template.total, 0),';
    v_anchor_totalv  TEXT := '''total_value'',       COALESCE(v_template.total, 0),';
    v_anchor_tax     TEXT := '''tax_total'',         0,';
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'purchase_topup_template' AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'purchase_topup_template not found';
    END IF;

    IF position('v_tax_mode' in v_def) > 0 THEN
        RAISE NOTICE 'purchase_topup_template already tax-aware — skipping';
        RETURN;
    END IF;

    IF (length(v_def) - length(replace(v_def, v_anchor_decl, ''))) / length(v_anchor_decl) <> 1 THEN
        RAISE EXCEPTION 'declare anchor not found exactly once — aborting';
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

    v_def := replace(v_def, v_anchor_payload,
        '-- ── Tax from the SELLER''s Tax Settings (subscriptions/003 —' || E'\n' ||
        '    -- same rule as plan subscriptions, see subscriptions/002) ──' || E'\n' ||
        '    v_gross_total   := COALESCE(v_template.total, 0);' || E'\n' ||
        '    v_taxable_total := v_gross_total;' || E'\n' ||
        '    SELECT display_mode INTO v_tax_mode FROM t_tax_settings WHERE tenant_id = v_platform_id;' || E'\n' ||
        '    IF v_gross_total > 0 AND COALESCE(v_tax_mode, ''no_tax'') IN (''including_tax'', ''excluding_tax'') THEN' || E'\n' ||
        '        SELECT COALESCE(SUM(rate), 0), COUNT(*) INTO v_tax_rate_sum, v_tax_rate_count' || E'\n' ||
        '        FROM t_tax_rates WHERE tenant_id = v_platform_id AND is_active = true;' || E'\n' ||
        '        IF v_tax_rate_sum > 0 THEN' || E'\n' ||
        '            IF v_tax_mode = ''including_tax'' THEN' || E'\n' ||
        '                v_taxable_total  := ROUND(v_gross_total / (1 + v_tax_rate_sum / 100), 2);' || E'\n' ||
        '                v_plan_tax_total := ROUND(v_gross_total - v_taxable_total, 2);' || E'\n' ||
        '            ELSE' || E'\n' ||
        '                v_plan_tax_total := ROUND(v_gross_total * v_tax_rate_sum / 100, 2);' || E'\n' ||
        '                v_gross_total    := ROUND(v_taxable_total + v_plan_tax_total, 2);' || E'\n' ||
        '                v_gross_factor   := 1 + v_tax_rate_sum / 100;' || E'\n' ||
        '            END IF;' || E'\n' ||
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
        '                SELECT COALESCE(jsonb_agg(CASE WHEN COALESCE(t.e->>''event_type'', ''billing'') = ''billing''' || E'\n' ||
        '                                      THEN jsonb_set(t.e, ''{amount}'', to_jsonb(ROUND((t.e->>''amount'')::numeric * v_gross_factor, 2)))' || E'\n' ||
        '                                      ELSE t.e END ORDER BY t.ord), ''[]''::jsonb)' || E'\n' ||
        '                INTO v_events' || E'\n' ||
        '                FROM jsonb_array_elements(COALESCE(v_events, ''[]''::jsonb)) WITH ORDINALITY AS t(e, ord);' || E'\n' ||
        '            END IF;' || E'\n' ||
        '        END IF;' || E'\n' ||
        '    END IF;' || E'\n\n' ||
        '    ' || v_anchor_payload);

    v_def := replace(v_def, v_anchor_grand,  '''grand_total'',       v_gross_total,');
    v_def := replace(v_def, v_anchor_totalv, '''total_value'',       v_taxable_total,');
    v_def := replace(v_def, v_anchor_tax,
        '''tax_total'',         v_plan_tax_total,' || E'\n' ||
        '        ''selected_tax_rate_ids'', v_tax_rate_ids,' || E'\n' ||
        '        ''tax_breakdown'',     v_tax_breakdown,');

    EXECUTE v_def;

    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'purchase_topup_template' AND pronamespace = 'public'::regnamespace;
    IF position('v_tax_mode' in v_def) = 0 OR position('v_plan_tax_total' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: tax computation not present after apply';
    END IF;
    RAISE NOTICE 'purchase_topup_template: tax-from-settings installed and verified';
END
$do$;
