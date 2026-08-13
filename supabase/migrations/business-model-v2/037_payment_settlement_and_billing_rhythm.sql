-- =============================================================================
-- 037_payment_settlement_and_billing_rhythm.sql
--
-- Fixes B5, B6, B7 (server side) and B8's data source, plus the
-- "₹23,996 asked in a single go" schedule defect.
--
-- FOUR INDEPENDENT DEFECTS, ONE MIGRATION — they share a root cause worth
-- stating once: the payment path has been reading the WRONG TENANT and the
-- WRONG DATE, because both were taken from whatever the caller happened to
-- send rather than from the record that actually owns the fact.
--
--   B5  The gateway was resolved from the x-tenant-id header — the PAYER.
--       An invoice is settled by its OWNER (the seller). Trinity paying
--       vikuna looked up Trinity's gateway, found none, and returned a bare
--       400 ("Could not start payment"). Verified live: INV-10042 ₹23,996
--       belongs to vikuna (razorpay configured), buyer Trinity (no gateway
--       at all). This is NOT subscription-specific — a BBB partner paying
--       BBB hits exactly the same wall.
--
--   B6  Nothing could ask "can this seller take money at all?" before
--       committing the buyer to a purchase, so the only way to discover an
--       unconfigured seller was to fail at the checkout step.
--
--   B7  A wallet top-up below ₹1,000 was not prevented anywhere.
--
--   B8  The subscription countdown read the CONTRACT END DATE, so a
--       quarterly plan on a 12-month term reported "365 days left".
--       Verified live on CN-1043: start 13 Aug 2026, end 13 Aug 2027.
--       The number a subscriber needs is days to the NEXT INSTALMENT.
--
--   Schedule  subscribe_tenant_to_plan fell back to ONE upfront event for
--       the whole template total whenever the caller did not pass
--       p_computed_events (which no caller does). The Quarterly template
--       already says quantity 4 × unit_price 5,999 @ billing_cycle
--       'quarterly' — the rhythm was authored all along and thrown away.
--
-- B8 and the schedule defect are the same fix: once the instalments exist,
-- the countdown has something true to count to.
--
-- IDEMPOTENT. Safe to re-run.
-- =============================================================================


-- =============================================================================
-- 1. can_collect_payment  — the single authority on "can this tenant be paid"
--
-- Every surface that is about to ask someone for money must be able to check
-- this FIRST, so the buyer is told "X has been notified and will be in touch"
-- instead of being walked into a dead checkout.
--
-- p_tenant_id is TEXT to match t_tenant_integrations.tenant_id, which is TEXT
-- (not UUID) — the same reason get_tenant_gateway_credentials takes TEXT.
-- Passing a UUID works via the implicit cast at the call site.
--
-- 'payment_gateway' is an integration TYPE that holds BOTH razorpay and
-- offline_upi, so the two are reported separately: offline UPI can collect
-- money but cannot run a checkout, and conflating them is what would make a
-- BBB-style tenant look card-enabled when it is not.
-- =============================================================================

CREATE OR REPLACE FUNCTION can_collect_payment(p_tenant_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_online      BOOLEAN := FALSE;
    v_offline     BOOLEAN := FALSE;
    v_name        TEXT;
    v_methods     TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required',
            'can_collect', false, 'online', false, 'offline_upi', false
        );
    END IF;

    SELECT COALESCE(tp.business_name, t.name)
      INTO v_name
    FROM t_tenants t
    LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id
    WHERE t.id::TEXT = p_tenant_id;

    SELECT
        BOOL_OR(ip.name = 'razorpay'),
        BOOL_OR(ip.name = 'offline_upi')
      INTO v_online, v_offline
    FROM t_tenant_integrations ti
    JOIN t_integration_providers ip ON ip.id = ti.master_integration_id
    JOIN t_integration_types it     ON it.id = ip.type_id
    WHERE ti.tenant_id::TEXT = p_tenant_id
      AND it.name = 'payment_gateway'
      AND ti.is_active = TRUE;

    v_online  := COALESCE(v_online, FALSE);
    v_offline := COALESCE(v_offline, FALSE);

    -- ::TEXT is required, not decorative: for `text[] || <literal>` Postgres
    -- resolves the untyped literal as an ARRAY literal and fails with
    -- "malformed array literal".
    IF v_online  THEN v_methods := v_methods || 'razorpay'::TEXT;    END IF;
    IF v_offline THEN v_methods := v_methods || 'offline_upi'::TEXT; END IF;

    RETURN jsonb_build_object(
        'success',      true,
        'tenant_id',    p_tenant_id,
        'tenant_name',  v_name,
        'can_collect',  (v_online OR v_offline),
        'online',       v_online,
        'offline_upi',  v_offline,
        'methods',      to_jsonb(v_methods)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION can_collect_payment(TEXT) TO authenticated, service_role, anon;


-- =============================================================================
-- 2. resolve_invoice_settlement  — B5
--
-- Answers, from the invoice itself: who is owed this money, may the caller
-- act on it, and can the payee actually be paid.
--
-- The edge function must call this INSTEAD OF trusting x-tenant-id. The
-- header still decides WHO IS ASKING (authorisation); it no longer decides
-- whose gateway gets used (settlement). Those were conflated, and that is
-- the whole of B5.
--
-- p_caller_tenant_id NULL = internal/service call, authorised by definition
-- (the CNAK public path has already proven the caller against
-- t_contract_access before it gets here).
-- =============================================================================

CREATE OR REPLACE FUNCTION resolve_invoice_settlement(
    p_invoice_id       UUID,
    p_caller_tenant_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inv       RECORD;
    v_role      TEXT;
    v_collect   JSONB;
BEGIN
    IF p_invoice_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'invoice_id is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    SELECT i.id,
           i.tenant_id                              AS settlement_tenant_id,
           i.contract_id,
           i.total_amount,
           -- t_invoices carries `balance` (and `amount_paid`); there is no
           -- balance_amount column. A NULL balance on an untouched invoice
           -- means the whole total is still owed.
           COALESCE(i.balance, i.total_amount - COALESCE(i.amount_paid, 0)) AS balance_amount,
           i.currency,
           i.status,
           c.buyer_tenant_id,
           c.contract_number,
           c.is_live
      INTO v_inv
    FROM t_invoices i
    LEFT JOIN t_contracts c ON c.id = i.contract_id
    WHERE i.id = p_invoice_id;

    IF v_inv.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found',
                                  'error_code', 'NOT_FOUND');
    END IF;

    -- Authorisation. Only the two parties to the money may act on it: the
    -- tenant owed it, and the tenant that owes it.
    IF p_caller_tenant_id IS NULL THEN
        v_role := 'service';
    ELSIF p_caller_tenant_id = v_inv.settlement_tenant_id THEN
        v_role := 'seller';
    ELSIF p_caller_tenant_id = v_inv.buyer_tenant_id THEN
        v_role := 'buyer';
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This tenant is not a party to that invoice',
            'error_code', 'NOT_A_PARTY'
        );
    END IF;

    v_collect := can_collect_payment(v_inv.settlement_tenant_id::TEXT);

    RETURN jsonb_build_object(
        'success',                true,
        'invoice_id',             v_inv.id,
        'contract_id',            v_inv.contract_id,
        'contract_number',        v_inv.contract_number,
        'is_live',                v_inv.is_live,
        -- THE fix: whose gateway, whose books, whose receipt.
        'settlement_tenant_id',   v_inv.settlement_tenant_id,
        'settlement_tenant_name', v_collect->>'tenant_name',
        'buyer_tenant_id',        v_inv.buyer_tenant_id,
        'caller_role',            v_role,
        'amount_total',           v_inv.total_amount,
        'amount_due',             v_inv.balance_amount,
        'currency',               COALESCE(v_inv.currency, 'INR'),
        'invoice_status',         v_inv.status,
        'can_collect',            (v_collect->>'can_collect')::BOOLEAN,
        'online',                 (v_collect->>'online')::BOOLEAN,
        'offline_upi',            (v_collect->>'offline_upi')::BOOLEAN
    );
END;
$$;

GRANT EXECUTE ON FUNCTION resolve_invoice_settlement(UUID, UUID) TO authenticated, service_role;


-- =============================================================================
-- 3. plan_billing_schedule  — the schedule the template already described
--
-- Builds the instalment schedule from the plan template's own priced block,
-- reading the SAME three fields cat-templates reads to render the card
-- (unit_price, quantity, billing_cycle). Card and schedule therefore cannot
-- disagree: ₹5,999/quarter × 4 on the card is ₹5,999 × 4 in the ledger.
--
-- CALENDAR arithmetic, deliberately. The shared derivation engine
-- (contractEventsDerivationService.ts and its two mirrors) uses fixed day
-- counts — quarterly = 90 days — which drifts: 13 Aug → 11 Nov → 9 Feb →
-- 10 May. That drift is a known open defect in CLAUDE.md, too wide to fix
-- here because BBB's live contracts run through those same three copies.
-- This is a NEW code path used only by plan subscriptions, so it is not
-- obliged to reproduce the bug: 13 Aug → 13 Nov → 13 Feb → 13 May.
--
-- Rounding: instalments are the authored unit_price; any gap against the
-- template total lands on the LAST instalment, so the schedule always sums
-- to exactly what the contract says.
-- =============================================================================

CREATE OR REPLACE FUNCTION plan_billing_schedule(
    p_template_id UUID,
    p_start       TIMESTAMPTZ DEFAULT NOW()
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_t            RECORD;
    v_block        JSONB;
    v_co           JSONB;
    v_price        NUMERIC;
    v_cycle        TEXT;
    v_qty          INT;
    v_label        TEXT;
    v_found        BOOLEAN := FALSE;
    v_months       INT;
    v_days         INT;
    v_events       JSONB := '[]'::JSONB;
    v_i            INT;
    v_when         TIMESTAMPTZ;
    v_amount       NUMERIC;
    v_running      NUMERIC := 0;
BEGIN
    SELECT id, name, display_name, total, currency, blocks
      INTO v_t
    FROM t_cat_templates
    WHERE id = p_template_id;

    IF v_t.id IS NULL OR COALESCE(v_t.total, 0) <= 0 THEN
        RETURN '[]'::JSONB;
    END IF;

    -- Pick the priced block that carries a real cadence. A cadenced block
    -- wins over a prepaid one; a plan priced only prepaid is one payment.
    -- Same precedence as cat-templates' `billing` derivation.
    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_t.blocks, '[]'::JSONB))
    LOOP
        v_co := v_block->'config_overrides';
        IF COALESCE((v_co->>'unit_price')::NUMERIC, 0) <= 0 THEN
            CONTINUE;
        END IF;

        IF COALESCE(v_co->>'billing_cycle', 'prepaid') <> 'prepaid' THEN
            v_price := (v_co->>'unit_price')::NUMERIC;
            v_cycle := v_co->>'billing_cycle';
            v_qty   := GREATEST(COALESCE((v_co->>'quantity')::INT, 1), 1);
            v_label := COALESCE(v_co->>'name', v_t.display_name, v_t.name);
            v_found := TRUE;
            EXIT;
        ELSIF NOT v_found THEN
            v_price := v_t.total;
            v_cycle := 'prepaid';
            v_qty   := 1;
            v_label := COALESCE(v_co->>'name', v_t.display_name, v_t.name);
            v_found := TRUE;
        END IF;
    END LOOP;

    -- No priced block at all, but the template has a total — one upfront
    -- payment. Same as the old fallback, now only for the case that
    -- genuinely is a single payment.
    IF NOT v_found THEN
        v_price := v_t.total;
        v_cycle := 'prepaid';
        v_qty   := 1;
        v_label := COALESCE(v_t.display_name, v_t.name);
    END IF;

    v_months := CASE v_cycle
                    WHEN 'monthly'    THEN 1
                    WHEN 'quarterly'  THEN 3
                    WHEN 'halfyearly' THEN 6
                    WHEN 'annual'     THEN 12
                    WHEN 'yearly'     THEN 12
                    ELSE 0
                END;
    v_days   := CASE v_cycle
                    WHEN 'weekly'      THEN 7
                    WHEN 'fortnightly' THEN 14
                    ELSE 0
                END;

    -- An unrecognised cadence must not silently become "everything on day
    -- one" — that is precisely the failure being fixed. Treat it as a single
    -- payment of the template total and say so in the label.
    IF v_months = 0 AND v_days = 0 THEN
        v_qty := 1;
        v_price := v_t.total;
    END IF;

    FOR v_i IN 1..v_qty LOOP
        v_when := CASE
                    WHEN v_months > 0 THEN p_start + ((v_i - 1) * v_months || ' months')::INTERVAL
                    WHEN v_days   > 0 THEN p_start + ((v_i - 1) * v_days   || ' days')::INTERVAL
                    ELSE p_start
                  END;

        -- Last instalment absorbs any rounding gap so the schedule sums to
        -- the contract total exactly.
        IF v_i = v_qty THEN
            v_amount := ROUND(COALESCE(v_t.total, 0) - v_running, 2);
        ELSE
            v_amount := ROUND(v_price, 2);
            v_running := v_running + v_amount;
        END IF;

        v_events := v_events || jsonb_build_array(jsonb_build_object(
            'id',                  'billing-' || v_i,
            'event_type',          'billing',
            'category_id',         '',
            'block_name',          v_label,
            'scheduled_date',      v_when,
            'amount',              v_amount,
            'status',              'pending',
            'sequence_number',     v_i,
            'total_occurrences',   v_qty,
            'billing_cycle_label', v_cycle
        ));
    END LOOP;

    RETURN v_events;
END;
$$;

GRANT EXECUTE ON FUNCTION plan_billing_schedule(UUID, TIMESTAMPTZ) TO authenticated, service_role;


-- =============================================================================
-- 4. subscribe_tenant_to_plan — use the derived schedule as the fallback
--
-- Only the fallback branch changes. A caller that DOES supply
-- p_computed_events (the UI's derivation engine) still wins, so nothing that
-- works today changes behaviour; the branch that produced one lump sum now
-- produces the authored instalments instead.
--
-- Rewritten in full rather than by prosrc substitution. CLAUDE.md records
-- that substitution silently no-ops when whitespace differs (migration 058
-- missed two of four functions that way), and a silent no-op here would
-- leave the ₹23,996 bug in place while the migration reported success.
-- =============================================================================

CREATE OR REPLACE FUNCTION subscribe_tenant_to_plan(
    p_template_id          UUID,
    p_subscriber_tenant_id UUID,
    p_user_id              UUID,
    p_computed_events      JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_platform_id     UUID;
    v_template        RECORD;
    v_subscriber      RECORD;
    v_contact_id      UUID;
    v_seq             JSONB;
    v_existing        RECORD;
    v_is_switch       BOOLEAN := FALSE;
    v_previous_contract_id UUID;
    v_cancel_result   JSONB;
    v_blocks          JSONB := '[]'::JSONB;
    v_block           JSONB;
    v_payload         JSONB;
    v_result          JSONB;
    v_meter           JSONB;
    v_limits          JSONB := '{}'::JSONB;
    v_grants          JSONB := '{}'::JSONB;
    v_flags           TEXT[] := ARRAY[]::TEXT[];
    v_duration_value  INTEGER;
    v_duration_unit   TEXT;
    v_events          JSONB;
    v_start           TIMESTAMPTZ := NOW();
    v_invoice_id       UUID;
    v_invoice_amount   NUMERIC;
    v_invoice_currency TEXT;
BEGIN
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No platform tenant configured',
                                  'error_code', 'NO_PLATFORM_TENANT');
    END IF;

    IF p_subscriber_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'subscriber tenant is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    IF p_subscriber_tenant_id = v_platform_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'The platform tenant cannot subscribe to its own plan',
                                  'error_code', 'SELF_SUBSCRIPTION');
    END IF;

    SELECT * INTO v_template
    FROM t_cat_templates
    WHERE id = p_template_id
      AND tenant_id = v_platform_id
      AND is_active = TRUE
      AND is_live = TRUE
      AND is_public = TRUE
      AND settings->>'lifecycle' = 'signed_off';

    IF v_template.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Plan not found, not published, or not listed for sale',
                                  'error_code', 'PLAN_NOT_AVAILABLE');
    END IF;

    SELECT id, name INTO v_subscriber FROM t_tenants WHERE id = p_subscriber_tenant_id;
    IF v_subscriber.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Subscriber tenant not found',
                                  'error_code', 'TENANT_NOT_FOUND');
    END IF;

    -- ── B6 (server side) ────────────────────────────────────────────────
    -- Refuse to raise a priced contract the platform cannot collect on. The
    -- UI checks this first and offers the "you have been notified" path
    -- instead; this is the backstop for anything that bypasses the UI, so a
    -- buyer can never end up holding an invoice nobody can take money for.
    IF COALESCE(v_template.total, 0) > 0
       AND NOT COALESCE((can_collect_payment(v_platform_id::TEXT)->>'can_collect')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This plan cannot be purchased online right now. The seller has been notified and will be in touch to complete it.',
            'error_code', 'SELLER_CANNOT_COLLECT'
        );
    END IF;

    SELECT c.id, c.contract_number, c.metadata->>'plan_template_id' AS plan_template_id INTO v_existing
    FROM t_contracts c
    JOIN t_contacts ct ON ct.id = c.buyer_id
    WHERE c.tenant_id = v_platform_id
      AND c.is_live = TRUE
      AND c.record_type = 'contract'
      AND c.status IN ('active', 'pending_acceptance')
      AND COALESCE(c.metadata->>'source', '') <> 'topup_purchase'
      AND ct.source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        IF v_existing.plan_template_id = p_template_id::TEXT THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'This tenant already has an active plan (' || v_existing.contract_number || ')',
                'error_code', 'ALREADY_SUBSCRIBED',
                'contract_id', v_existing.id
            );
        END IF;

        v_is_switch := TRUE;
        v_previous_contract_id := v_existing.id;

        v_cancel_result := update_contract_status(
            v_existing.id, v_platform_id, 'cancelled',
            p_user_id, NULL, 'system',
            'Superseded by switch to plan: ' || COALESCE(v_template.display_name, v_template.name)
        );

        IF NOT COALESCE((v_cancel_result->>'success')::BOOLEAN, FALSE) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', COALESCE(v_cancel_result->>'error', 'Could not end current plan'),
                'error_code', 'SWITCH_CANCEL_FAILED',
                'detail', v_cancel_result
            );
        END IF;
    END IF;

    SELECT id INTO v_contact_id
    FROM t_contacts
    WHERE tenant_id = v_platform_id
      AND is_live = TRUE
      AND source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        v_seq := get_next_formatted_sequence('CONTACT', v_platform_id, TRUE);

        INSERT INTO t_contacts (
            tenant_id, is_live, type, name, company_name, contact_number,
            classifications, status, is_active, is_seed,
            source, source_tenant_id, created_by
        ) VALUES (
            v_platform_id, TRUE, 'corporate',
            NULL, v_subscriber.name, v_seq->>'formatted',
            '["client"]'::JSONB, 'active', TRUE, FALSE,
            'plan_subscription', p_subscriber_tenant_id, p_user_id
        )
        RETURNING id INTO v_contact_id;
    END IF;

    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
            'position',        COALESCE((v_block->>'order')::INT, 0),
            'source_type',     'catalog',
            'source_block_id', v_block->>'block_id',
            'block_name',      v_block->'config_overrides'->>'name',
            'category_id',     v_block->'config_overrides'->>'category_id',
            'category_name',   v_block->'config_overrides'->>'category_name',
            'unit_price',      COALESCE((v_block->'config_overrides'->>'unit_price')::NUMERIC, 0),
            'quantity',        COALESCE((v_block->'config_overrides'->>'quantity')::INT, 1),
            'billing_cycle',   COALESCE(v_block->'config_overrides'->>'billing_cycle', 'prepaid'),
            'total_price',     COALESCE((v_block->'config_overrides'->>'total_price')::NUMERIC, 0),
            'custom_fields',   jsonb_build_object(
                                  'config',   COALESCE(v_block->'config_overrides'->'config', '{}'::JSONB),
                                  'currency', COALESCE(v_template.currency, 'INR'),
                                  'notes',    'Plan: ' || COALESCE(v_template.display_name, v_template.name)
                               )
        ));
    END LOOP;

    v_duration_value := COALESCE((v_template.settings->'defaults'->>'duration_value')::INT, 1);
    v_duration_unit  := COALESCE(v_template.settings->'defaults'->>'duration_unit', 'months');

    -- ── The schedule ────────────────────────────────────────────────────
    -- A caller that derived a real schedule (the UI engine) still wins.
    -- Otherwise the schedule is derived from the template's own priced
    -- block — NOT collapsed into one upfront payment, which is what charged
    -- ₹23,996 in a single go for a plan whose card said ₹5,999/quarter.
    IF p_computed_events IS NOT NULL AND jsonb_typeof(p_computed_events) = 'array'
       AND jsonb_array_length(p_computed_events) > 0 THEN
        v_events := p_computed_events;
    ELSE
        v_events := plan_billing_schedule(v_template.id, v_start);
    END IF;

    v_payload := jsonb_build_object(
        'tenant_id',         v_platform_id,
        'is_live',           TRUE,
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
        'buyer_id',          v_contact_id,
        'buyer_tenant_id',   p_subscriber_tenant_id,
        'buyer_company',     v_subscriber.name,
        'currency',          COALESCE(v_template.currency, 'INR'),
        'duration_value',    v_duration_value,
        'duration_unit',     v_duration_unit,
        'start_date',        v_start,
        'acceptance_method', CASE WHEN COALESCE(v_template.total, 0) > 0 THEN 'payment' ELSE 'auto' END,
        'nomenclature_id',   v_template.settings->'defaults'->>'nomenclature_id',
        'billing_cycle_type',COALESCE(v_template.settings->'defaults'->>'billing_cycle_type', 'unified'),
        'grand_total',       COALESCE(v_template.total, 0),
        'total_value',       COALESCE(v_template.total, 0),
        'tax_total',         0,
        'discount_total',    0,
        'blocks',            v_blocks,
        'computed_events',   v_events,
        'created_by',        p_user_id,
        'performed_by_type', 'user',
        'metadata',          jsonb_build_object(
                                'source',                 'plan_subscription',
                                'plan_template_id',       v_template.id,
                                'subscriber_tenant_id',   p_subscriber_tenant_id,
                                'switched_from_contract_id', v_previous_contract_id
                             )
    );

    v_result := create_contract_transaction(v_payload, NULL);

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED',
            'detail', v_result
        );
    END IF;

    -- Priced plans are payment-gated. create_contract_transaction only
    -- auto-activates acceptance_method='auto', so a priced plan stops at
    -- 'draft' with no invoice. Move it to pending_acceptance and raise the
    -- invoice the subscriber pays; activation then happens in
    -- record_invoice_payment once that invoice clears (migration 036).
    IF COALESCE(v_template.total, 0) > 0 THEN
        PERFORM update_contract_status(
            p_contract_id       := (v_result->'data'->>'id')::UUID,
            p_tenant_id         := v_platform_id,
            p_new_status        := 'pending_acceptance',
            p_performed_by_id   := p_user_id,
            p_performed_by_name := NULL,
            p_performed_by_type := 'system',
            p_note              := 'Plan subscription raised - awaiting payment'
        );
        PERFORM generate_contract_invoices(
            (v_result->'data'->>'id')::UUID, v_platform_id, p_user_id
        );
    END IF;

    SELECT id, total_amount, currency INTO v_invoice_id, v_invoice_amount, v_invoice_currency
    FROM t_invoices
    WHERE contract_id = (v_result->'data'->>'id')::UUID
    ORDER BY created_at ASC
    LIMIT 1;

    -- Response display only — actual application happens in
    -- fn_apply_contract_entitlements, gated on payment for priced plans.
    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_meter := v_block->'config_overrides'->'config'->'metering';
        CONTINUE WHEN v_meter IS NULL;
        IF v_meter->>'mode' = 'limit' AND v_meter->'limits' IS NOT NULL THEN
            v_limits := v_limits || v_meter->'limits';
        ELSIF v_meter->>'mode' = 'per_creation' AND v_meter->'grants' IS NOT NULL THEN
            v_grants := v_grants || v_meter->'grants';
        ELSIF v_meter->>'mode' = 'flag' AND v_meter->>'flag' IS NOT NULL THEN
            v_flags := v_flags || (v_meter->>'flag');
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_result->'data'->>'id',
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'plan_name',       COALESCE(v_template.display_name, v_template.name),
        'limits',          v_limits,
        'grants',          v_grants,
        'flags',           to_jsonb(v_flags),
        'was_switch',       v_is_switch,
        'previous_contract_id', v_previous_contract_id,
        'invoice_id',       v_invoice_id,
        'invoice_amount',   v_invoice_amount,
        'invoice_currency', COALESCE(v_invoice_currency, v_template.currency, 'INR'),
        'requires_payment', COALESCE(v_template.total, 0) > 0
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Subscription failed: ' || SQLERRM,
        'error_code', 'INTERNAL_ERROR'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION subscribe_tenant_to_plan(UUID, UUID, UUID, JSONB) TO authenticated, service_role;


-- =============================================================================
-- 5. get_subscription_billing_rhythm  — B8's data source
--
-- The billing events ARE the rhythm; nothing here re-derives a cadence.
--
-- Reads whichever copy of the schedule is authoritative right now:
--   'events'   t_contract_events — materialised on ACTIVATION
--   'computed' t_contracts.computed_events — the pending contract's schedule,
--              which is all that exists before the first payment clears.
-- That second branch is the point. B8's screenshot was a contract in exactly
-- that state, and any rhythm that only read t_contract_events would have had
-- nothing to show and fallen back to the contract term all over again.
--
-- "Today" is IST, per migration 048 — a UTC CURRENT_DATE reports yesterday
-- for the first 5½ hours of every Indian day, which on a countdown is an
-- off-by-one the user sees.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_subscription_billing_rhythm(p_contract_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_today       DATE := (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE;
    v_source      TEXT := 'none';
    v_sched       JSONB := '[]'::JSONB;
    v_total       INT := 0;
    v_paid        INT := 0;
    v_next_date   DATE;
    v_next_amount NUMERIC;
    v_last_paid   DATE;
    v_cycle       TEXT;
    v_contract    RECORD;
BEGIN
    IF p_contract_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'source', 'none');
    END IF;

    SELECT id, status, start_date, end_date, currency, computed_events
      INTO v_contract
    FROM t_contracts WHERE id = p_contract_id;

    IF v_contract.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'source', 'none');
    END IF;

    -- Materialised events win when they exist.
    SELECT COUNT(*) INTO v_total
    FROM t_contract_events
    WHERE contract_id = p_contract_id AND event_type = 'billing' AND is_active = TRUE;

    IF v_total > 0 THEN
        v_source := 'events';

        SELECT COUNT(*) FILTER (WHERE status = 'paid'),
               MAX(scheduled_date::DATE) FILTER (WHERE status = 'paid'),
               MAX(billing_cycle_label)
          INTO v_paid, v_last_paid, v_cycle
        FROM t_contract_events
        WHERE contract_id = p_contract_id AND event_type = 'billing' AND is_active = TRUE;

        SELECT scheduled_date::DATE, amount
          INTO v_next_date, v_next_amount
        FROM t_contract_events
        WHERE contract_id = p_contract_id AND event_type = 'billing'
          AND is_active = TRUE AND status <> 'paid'
        ORDER BY scheduled_date ASC
        LIMIT 1;

        -- sequence_number is nullable on older rows, so it is backfilled by
        -- position. The row_number() lives in a subquery: Postgres forbids a
        -- window function inside an aggregate call.
        SELECT jsonb_agg(jsonb_build_object(
                   'sequence', s.seq,
                   'date',     s.scheduled_date::DATE,
                   'amount',   s.amount,
                   'status',   s.status
               ) ORDER BY s.scheduled_date)
          INTO v_sched
        FROM (
            SELECT scheduled_date, amount, status,
                   COALESCE(sequence_number,
                            (row_number() OVER (ORDER BY scheduled_date))::INT) AS seq
            FROM t_contract_events
            WHERE contract_id = p_contract_id AND event_type = 'billing' AND is_active = TRUE
        ) s;

    ELSIF jsonb_typeof(COALESCE(v_contract.computed_events, 'null'::JSONB)) = 'array'
          AND jsonb_array_length(v_contract.computed_events) > 0 THEN
        -- Not yet activated: the schedule exists only as computed_events.
        v_source := 'computed';

        SELECT COUNT(*),
               MAX(e->>'billing_cycle_label')
          INTO v_total, v_cycle
        FROM jsonb_array_elements(v_contract.computed_events) e
        WHERE COALESCE(e->>'event_type', '') = 'billing';

        v_paid := 0;

        SELECT (e->>'scheduled_date')::DATE, (e->>'amount')::NUMERIC
          INTO v_next_date, v_next_amount
        FROM jsonb_array_elements(v_contract.computed_events) e
        WHERE COALESCE(e->>'event_type', '') = 'billing'
        ORDER BY (e->>'scheduled_date')::TIMESTAMPTZ ASC
        LIMIT 1;

        SELECT jsonb_agg(jsonb_build_object(
                   'sequence', COALESCE((e->>'sequence_number')::INT, 0),
                   'date',     (e->>'scheduled_date')::DATE,
                   'amount',   (e->>'amount')::NUMERIC,
                   'status',   COALESCE(e->>'status', 'pending')
               ) ORDER BY (e->>'scheduled_date')::TIMESTAMPTZ)
          INTO v_sched
        FROM jsonb_array_elements(v_contract.computed_events) e
        WHERE COALESCE(e->>'event_type', '') = 'billing';
    END IF;

    IF v_total = 0 THEN
        RETURN jsonb_build_object(
            'success', true, 'source', 'none',
            'total_installments', 0, 'paid_installments', 0,
            'awaiting_first_payment', v_contract.status = 'pending_acceptance'
        );
    END IF;

    RETURN jsonb_build_object(
        'success',                true,
        'source',                 v_source,
        'cycle',                  v_cycle,
        'currency',               COALESCE(v_contract.currency, 'INR'),
        'total_installments',     v_total,
        'paid_installments',      v_paid,
        'next_due_date',          v_next_date,
        'next_due_amount',        v_next_amount,
        -- THE number the page shows. Days to the next INSTALMENT, not to the
        -- end of the contract term.
        'days_to_next',           CASE WHEN v_next_date IS NULL THEN NULL
                                       ELSE (v_next_date - v_today) END,
        'is_overdue',             (v_next_date IS NOT NULL AND v_next_date < v_today),
        'last_paid_date',         v_last_paid,
        -- Nothing has been paid yet and the contract is still gated: the plan
        -- is NOT live, whatever the term dates say.
        'awaiting_first_payment', (v_paid = 0 AND v_contract.status = 'pending_acceptance'),
        'schedule',               COALESCE(v_sched, '[]'::JSONB)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_subscription_billing_rhythm(UUID) TO authenticated, service_role;


-- =============================================================================
-- 6. get_tenant_context — hand the rhythm to the Subscription page
--
-- ONE targeted substitution into a 5.6k function rather than retyping it.
-- CLAUDE.md's migration 058/059 lesson applies: a substitution that does not
-- match SILENTLY NO-OPS and the migration still reports success. So the hit
-- is asserted before the function is replaced, and verified after.
-- =============================================================================

DO $do$
DECLARE
    v_src     TEXT;
    v_new     TEXT;
    v_anchor  TEXT := '''next_billing_date'', COALESCE(v_plan.end_date, v_context.next_billing_date)';
    v_replace TEXT := '''next_billing_date'', COALESCE(v_plan.end_date, v_context.next_billing_date),' || E'\n' ||
                      '            ''rhythm'', get_subscription_billing_rhythm(v_plan.id)';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_tenant_context';

    IF v_src IS NULL THEN
        RAISE EXCEPTION '037: get_tenant_context not found';
    END IF;

    -- Already applied — nothing to do (idempotency).
    IF position('get_subscription_billing_rhythm' IN v_src) > 0 THEN
        RAISE NOTICE '037: get_tenant_context already carries rhythm — skipped';
        RETURN;
    END IF;

    IF position(v_anchor IN v_src) = 0 THEN
        RAISE EXCEPTION '037: anchor not found in get_tenant_context — REFUSING to no-op silently. Re-read the live source and update the anchor.';
    END IF;

    v_new := replace(v_src, v_anchor, v_replace);

    IF v_new = v_src THEN
        RAISE EXCEPTION '037: substitution produced no change';
    END IF;

    EXECUTE v_new;

    -- Post-check: prove the rewrite actually landed.
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_tenant_context';

    IF position('get_subscription_billing_rhythm' IN v_src) = 0 THEN
        RAISE EXCEPTION '037: post-check failed — rhythm not present after replace';
    END IF;

    RAISE NOTICE '037: get_tenant_context now returns subscription.rhythm';
END
$do$;


-- =============================================================================
-- 7. B7 — the ₹1,000 wallet minimum, enforced where it cannot be bypassed
--
-- purchase_topup_template(template_id, tenant, user) takes NO amount: a
-- top-up can only ever be a listed template. So the authoring boundary is
-- the complete choke point — guard it there once, rather than repeating an
-- amount check at every purchase site (and missing one).
--
-- Today exactly one wallet_topup template exists, at ₹1,000, so this
-- changes nothing live; it stops a sub-minimum one from being published.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_enforce_wallet_topup_minimum()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_min NUMERIC := 1000;
BEGIN
    IF NEW.category = 'wallet_topup'
       AND COALESCE(NEW.is_public, FALSE)
       AND COALESCE(NEW.is_active, FALSE)
       AND COALESCE(NEW.total, 0) < v_min THEN
        RAISE EXCEPTION 'A wallet top-up must be at least %. "%" is set to %.',
            v_min, COALESCE(NEW.display_name, NEW.name), COALESCE(NEW.total, 0)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wallet_topup_minimum ON t_cat_templates;
CREATE TRIGGER trg_wallet_topup_minimum
    BEFORE INSERT OR UPDATE ON t_cat_templates
    FOR EACH ROW EXECUTE FUNCTION fn_enforce_wallet_topup_minimum();


-- =============================================================================
-- VERIFICATION — run after applying. Every line should read as described.
-- =============================================================================
-- -- B5: the seller settles, not the payer.
-- SELECT resolve_invoice_settlement(
--   (SELECT id FROM t_invoices WHERE invoice_number = 'INV-10042'),
--   (SELECT id FROM t_tenants WHERE name = 'Trinity Tecnitions'));
--   --> caller_role 'buyer', settlement_tenant_name 'vikuna…', can_collect true, online true
--
-- -- B6: capability, per tenant.
-- SELECT can_collect_payment((SELECT id::TEXT FROM t_tenants WHERE name='BBB'));
--   --> can_collect true, online false, offline_upi true
-- SELECT can_collect_payment((SELECT id::TEXT FROM t_tenants WHERE name='Trinity Tecnitions'));
--   --> can_collect false
--
-- -- Schedule: 4 × ₹5,999 on calendar quarters, summing to ₹23,996.
-- SELECT jsonb_pretty(plan_billing_schedule(
--   (SELECT id FROM t_cat_templates WHERE name='Quarterly' AND is_latest LIMIT 1),
--   '2026-08-13'::TIMESTAMPTZ));
--
-- -- B8: rhythm off the pending contract's computed_events.
-- SELECT jsonb_pretty(get_subscription_billing_rhythm(
--   (SELECT id FROM t_contracts WHERE contract_number='CN-1043'
--      AND tenant_id=(SELECT id FROM t_tenants WHERE name='vikuna') AND is_live)));
--
-- -- B7: must RAISE.
-- -- UPDATE t_cat_templates SET total = 500 WHERE category='wallet_topup' AND is_public;
-- =============================================================================
