-- ═══════════════════════════════════════════════════════════════════
-- contracts-v2/006_cadence_backstop_v2.sql
-- JTD Nucleus initiative — owner-approved (2026-08-15)
--
-- WHY: the cadence-fit gate (CN-1002 root-cause fix) lives only in the
-- ContractWizard UI. Template single-assign (VaNi) and bulk-assign never
-- pass through the wizard, so a template whose block cadence cannot fit
-- the contract duration propagates the CN-1002 contradiction (invoice
-- bills full quantity, billing events truncate at end_date, service
-- events overrun) to every assignee. This adds the SAME rule inside
-- create_contract_transaction_v2 so EVERY entry path is refused at the
-- engine, before any side effect (no sequence number burned, nothing
-- inserted, no idempotency stored).
--
-- RULE (SQL port of computeCadenceViolations() in
-- contractnest-ui/src/utils/service-contracts/contractEvents.ts — the
-- branch conditions mirror it 1:1; change together):
--   · contracts only (record_type='contract'); RFQs skipped
--   · per block, skip qty<=1 or unlimited
--   · visit block = category 'service' AND NOT config.billingOnly AND
--     serviceCycleDays > 0 (catalog: config.serviceCycles{enabled,days};
--     FlyBy/RFQ: config.serviceCycleDays)
--   · service leg: (qty−1) × serviceCycleDays must fit the term
--   · billing leg: payment_mode='defined', category IN (service,spare),
--     NOT cadence-priced, NOT a visit block, recurring cycle:
--     (qty−1) × periodDays must fit the term
--     (monthly 30 / fortnightly 14 / quarterly 90 / halfyearly 182 /
--      annual 365 / custom → config days, fallback 30)
--   · where a payload omits its custom cycle days the fallback is
--     PERMISSIVE (30) — the backstop can under-block, never false-refuse
--
-- METHOD: verified-anchor substitution into the live pg_get_functiondef
-- text (never retyped — the migration-048/056-059 technique), with the
-- 059 lesson applied: RAISE if the anchor is not found exactly once,
-- and a post-apply check that the backstop actually landed.
--
-- APPLIED LIVE 2026-08-15 — this file is the source-of-record copy.
-- Idempotent: re-running no-ops if CADENCE_UNFIT is already present.
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_def    TEXT;
    v_anchor TEXT;
    v_insert TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'create_contract_transaction_v2'
      AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'create_contract_transaction_v2 not found — nothing to modify';
    END IF;

    IF position('CADENCE_UNFIT' in v_def) > 0 THEN
        RAISE NOTICE 'cadence backstop already present — skipping';
        RETURN;
    END IF;

    -- Insertion point: immediately before sequence generation, after the
    -- idempotency-cache lookup. The v_seq_result continuation makes this
    -- anchor unique (the later RFQ-vendors branch shares the IF line).
    v_anchor := '    IF v_record_type = ''rfq'' THEN' || E'\n' ||
                '        v_seq_result := get_next_formatted_sequence(''PROJECT''';

    IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
        RAISE EXCEPTION 'anchor not found exactly once — live function has drifted; aborting (nothing changed)';
    END IF;

    v_insert := $ins$    -- ═══ Cadence-fit backstop (2026-08-15, owner-approved) ═══
    -- SQL port of the wizard gate computeCadenceViolations()
    -- (contractnest-ui/src/utils/service-contracts/contractEvents.ts).
    -- Refuses a self-contradictory payload from EVERY entry path before
    -- any side effect. Same rule, same constants; missing custom cycle
    -- days fall back permissively (never a false refusal).
    IF v_record_type = 'contract' THEN
        DECLARE
            cb_total_days  NUMERIC;
            cb_pay_mode    TEXT;
            cb_block       JSONB;
            cb_cfg         JSONB;
            cb_qty         INTEGER;
            cb_svc_days    NUMERIC;
            cb_cycle       TEXT;
            cb_period_days NUMERIC;
            cb_span        NUMERIC;
            cb_visit_block BOOLEAN;
            cb_violations  JSONB := '[]'::JSONB;
        BEGIN
            cb_total_days := CASE COALESCE(p_payload->>'duration_unit', 'months')
                WHEN 'days'   THEN COALESCE((p_payload->>'duration_value')::NUMERIC, 0)
                WHEN 'months' THEN COALESCE((p_payload->>'duration_value')::NUMERIC, 0) * 30
                WHEN 'years'  THEN COALESCE((p_payload->>'duration_value')::NUMERIC, 0) * 365
                ELSE COALESCE((p_payload->>'duration_value')::NUMERIC, 0) * 30
            END;
            cb_pay_mode := p_payload->>'payment_mode';

            IF cb_total_days > 0 THEN
                FOR cb_block IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'blocks', '[]'::JSONB))
                LOOP
                    cb_qty := COALESCE((cb_block->>'quantity')::INTEGER, 1);
                    cb_cfg := COALESCE(cb_block->'custom_fields'->'config', '{}'::JSONB);

                    CONTINUE WHEN cb_qty <= 1
                        OR COALESCE((cb_block->'custom_fields'->>'unlimited')::BOOLEAN, false);

                    cb_svc_days := CASE
                        WHEN COALESCE((cb_cfg->'serviceCycles'->>'enabled')::BOOLEAN, false)
                            THEN (cb_cfg->'serviceCycles'->>'days')::NUMERIC
                        ELSE (cb_cfg->>'serviceCycleDays')::NUMERIC
                    END;

                    cb_visit_block := (cb_block->>'category_id') = 'service'
                        AND NOT COALESCE((cb_cfg->>'billingOnly')::BOOLEAN, false)
                        AND COALESCE(cb_svc_days, 0) > 0;

                    -- Service leg: (qty − 1) × serviceCycleDays must fit the term
                    IF cb_visit_block THEN
                        cb_span := (cb_qty - 1) * cb_svc_days;
                        IF cb_span > cb_total_days THEN
                            cb_violations := cb_violations || jsonb_build_object(
                                'block_name', COALESCE(cb_block->>'block_name', 'Untitled Block'),
                                'event_type', 'service',
                                'count', cb_qty,
                                'cycle_days', cb_svc_days,
                                'span_days', cb_span,
                                'contract_days', cb_total_days,
                                'message', format('"%s": %s service visits every %s days span ~%s days, but the contract runs %s days.',
                                    COALESCE(cb_block->>'block_name', 'Untitled Block'), cb_qty, cb_svc_days, cb_span, cb_total_days)
                            );
                        END IF;
                    END IF;

                    -- Billing leg: per-block ('defined') billing, priced category,
                    -- recurring cycle, not cadence-priced, not a visit block (its
                    -- bill count derives from the term and always fits).
                    IF cb_pay_mode = 'defined'
                       AND NOT cb_visit_block
                       AND (cb_block->>'category_id') IN ('service', 'spare')
                       AND NOT (cb_cfg ? 'cadencePricing' AND cb_cfg->'cadencePricing' <> 'null'::JSONB)
                    THEN
                        cb_cycle := COALESCE(cb_block->>'billing_cycle', 'prepaid');
                        cb_period_days := CASE cb_cycle
                            WHEN 'monthly'     THEN 30
                            WHEN 'fortnightly' THEN 14
                            WHEN 'quarterly'   THEN 90
                            WHEN 'halfyearly'  THEN 182
                            WHEN 'annual'      THEN 365
                            WHEN 'custom'      THEN COALESCE(
                                (cb_cfg->>'customCycleDays')::NUMERIC,
                                CASE WHEN COALESCE((cb_cfg->'serviceCycles'->>'enabled')::BOOLEAN, false)
                                     THEN (cb_cfg->'serviceCycles'->>'days')::NUMERIC END,
                                30)
                            ELSE 0
                        END;
                        IF cb_period_days > 0 THEN
                            cb_span := (cb_qty - 1) * cb_period_days;
                            IF cb_span > cb_total_days THEN
                                cb_violations := cb_violations || jsonb_build_object(
                                    'block_name', COALESCE(cb_block->>'block_name', 'Untitled Block'),
                                    'event_type', 'billing',
                                    'count', cb_qty,
                                    'cycle_days', cb_period_days,
                                    'span_days', cb_span,
                                    'contract_days', cb_total_days,
                                    'message', format('"%s": %s billing cycles of %s days span ~%s days, but the contract runs %s days.',
                                        COALESCE(cb_block->>'block_name', 'Untitled Block'), cb_qty, cb_period_days, cb_span, cb_total_days)
                                );
                            END IF;
                        END IF;
                    END IF;
                END LOOP;
            END IF;

            IF jsonb_array_length(cb_violations) > 0 THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Schedule does not fit the contract duration: '
                        || (cb_violations->0->>'message')
                        || CASE WHEN jsonb_array_length(cb_violations) > 1
                                THEN format(' (+%s more)', jsonb_array_length(cb_violations) - 1)
                                ELSE '' END
                        || ' Reduce the count, shorten the cycle, or extend the contract duration.',
                    'error_code', 'CADENCE_UNFIT',
                    'violations', cb_violations
                );
            END IF;
        END;
    END IF;

$ins$ || E'\n';

    v_def := replace(v_def, v_anchor, v_insert || v_anchor);
    EXECUTE v_def;

    -- Post-apply verification (a silent no-op is this technique's failure mode)
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'create_contract_transaction_v2'
      AND pronamespace = 'public'::regnamespace;

    IF position('CADENCE_UNFIT' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: backstop not present after apply';
    END IF;

    RAISE NOTICE 'cadence backstop installed and verified';
END
$do$;

COMMENT ON FUNCTION public.create_contract_transaction_v2 IS
'V2 contract creation (JTD Nucleus): explicit seller/buyer, unconditional CNAK grant, idempotency, and (2026-08-15) a cadence-fit backstop mirroring the wizard gate computeCadenceViolations — refuses payloads whose block cadence cannot fit the contract duration (error_code CADENCE_UNFIT) before any side effect.';
