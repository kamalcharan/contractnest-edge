-- ============================================================================
-- Business Model V4 — Plan switching (upgrade/downgrade between Free/
-- Quarterly/Yearly)
--
-- Owner request: "Switch" was disabled on every plan but the one you're
-- currently on — subscribe_tenant_to_plan hard-refused a second
-- subscription (ALREADY_SUBSCRIBED) because superseding an existing plan
-- contract was an unanswered product decision. Now answered, 2026-08-09:
--   - Switch is IMMEDIATE — the old plan contract ends right away, the new
--     one starts right away. No "at next renewal" deferral.
--   - The old plan's unused allowance (limit_contracts/limit_rfqs headroom)
--     and accrued notification credits are FORFEITED, not carried over —
--     a switch resets usage_contracts/usage_rfqs/credits_* to 0 and applies
--     the new plan's limits/grants fresh, same as a first-time subscribe.
--
-- Reuses the existing machinery rather than building a parallel one:
--   - The SAME subscribe_tenant_to_plan RPC handles both first subscribe
--     and switch — no new RPC, no new edge route, no new UI mutation.
--     Requesting the exact plan you're already on is still refused
--     (ALREADY_SUBSCRIBED) — that's a no-op, not a switch.
--   - Ending the old plan contract goes through update_contract_status
--     (the existing generic contract status-transition function — same
--     one every other cancellation in the system uses), so the switch gets
--     a real audit trail (t_contract_history) and JTD event for free,
--     rather than a raw UPDATE that skips both.
--   - The new plan contract is raised exactly like a first-time subscribe
--     (same create_contract_transaction call, same block-building code) —
--     the only difference is the old contract is cancelled first and usage/
--     credits reset instead of left untouched.
--
-- t_contracts has no 'superseded' status — the CHECK constraint only
-- allows draft/pending_review/pending_acceptance/active/completed/
-- cancelled/expired/sent/quotes_received/awarded/converted_to_contract.
-- 'cancelled' is the closest existing semantic fit; the real reason is
-- recorded in the t_contract_history note ("Superseded by switch to
-- plan: X"), not left to be inferred from the bare status alone.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.subscribe_tenant_to_plan(p_template_id uuid, p_subscriber_tenant_id uuid, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    v_once            JSONB := '{}'::JSONB;
    v_gkey            TEXT;
    v_gval            INTEGER;
    v_flags           TEXT[] := ARRAY[]::TEXT[];
    v_duration_value  INTEGER;
    v_duration_unit   TEXT;
    v_events          JSONB := '[]'::JSONB;
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

        -- Switching plans: end the old plan contract through the SAME
        -- status-transition machinery every other contract cancellation
        -- uses (update_contract_status — audit trail via t_contract_
        -- history, JTD event) rather than a raw UPDATE, then fall through
        -- to raise the new plan exactly like a first subscribe. Owner
        -- decision 2026-08-09: immediate switch, old plan's unused
        -- allowance/credits forfeited (reset below), not carried over.
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

    -- A plan is billed once, prepaid, for its whole term. At zero there is
    -- nothing to bill, so no event is raised — which also avoids minting a
    -- zero-value invoice that would sit unpaid forever.
    IF COALESCE(v_template.total, 0) > 0 THEN
        v_events := jsonb_build_array(jsonb_build_object(
            'id', 'billing-1',
            'event_type', 'billing',
            'category_id', '',
            'block_name', COALESCE(v_template.display_name, v_template.name),
            'scheduled_date', now(),
            'amount', v_template.total,
            'status', 'pending'
        ));
    END IF;

    v_payload := jsonb_build_object(
        'tenant_id',         v_platform_id,
        'is_live',           TRUE,
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
        'buyer_id',          v_contact_id,
        'buyer_company',     v_subscriber.name,
        'currency',          COALESCE(v_template.currency, 'INR'),
        'duration_value',    v_duration_value,
        'duration_unit',     v_duration_unit,
        'start_date',        now(),
        'acceptance_method', 'auto',
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

    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_meter := v_block->'config_overrides'->'config'->'metering';
        CONTINUE WHEN v_meter IS NULL;

        IF v_meter->>'mode' = 'limit' AND v_meter->'limits' IS NOT NULL THEN
            v_limits := v_limits || v_meter->'limits';
        ELSIF v_meter->>'mode' = 'per_creation' AND v_meter->'grants' IS NOT NULL THEN
            v_grants := v_grants || v_meter->'grants';
        ELSIF v_meter->>'mode' = 'one_time' AND v_meter->'grants' IS NOT NULL THEN
            v_once := v_once || v_meter->'grants';
        ELSIF v_meter->>'mode' = 'flag' AND v_meter->>'flag' IS NOT NULL THEN
            v_flags := v_flags || (v_meter->>'flag');
        END IF;
    END LOOP;

    INSERT INTO t_tenant_context (product_code, tenant_id, billing_mode)
    VALUES ('contractnest', p_subscriber_tenant_id, 'plan')
    ON CONFLICT (product_code, tenant_id) DO NOTHING;

    UPDATE t_tenant_context
    SET billing_mode      = 'plan',
        limit_contracts   = COALESCE((v_limits->>'contracts')::INT, 0),
        limit_rfqs        = COALESCE((v_limits->>'rfqs')::INT, 0),
        credit_grant_rates = CASE WHEN v_grants = '{}'::JSONB
                                  THEN credit_grant_rates ELSE v_grants END,
        addon_vani_ai     = ('addon_vani_ai' = ANY(v_flags)) OR addon_vani_ai,
        addon_rfp         = ('addon_rfp'     = ANY(v_flags)) OR addon_rfp,
        flag_can_access   = TRUE,
        -- Switching plans forfeits the old plan's unused allowance and
        -- accrued notification credits — owner decision 2026-08-09. A
        -- first-time subscribe leaves these untouched (they were already
        -- 0 on a fresh row; a per_contract/freemium tenant's own accrued
        -- credits are not touched by a first plan subscribe, only a
        -- SWITCH between plans forfeits them).
        usage_contracts   = CASE WHEN v_is_switch THEN 0 ELSE usage_contracts END,
        usage_rfqs        = CASE WHEN v_is_switch THEN 0 ELSE usage_rfqs END,
        credits_whatsapp  = CASE WHEN v_is_switch THEN 0 ELSE credits_whatsapp END,
        credits_sms       = CASE WHEN v_is_switch THEN 0 ELSE credits_sms END,
        credits_email     = CASE WHEN v_is_switch THEN 0 ELSE credits_email END,
        credits_inapp     = CASE WHEN v_is_switch THEN 0 ELSE credits_inapp END,
        updated_at        = now()
    WHERE product_code = 'contractnest'
      AND tenant_id = p_subscriber_tenant_id;

    FOR v_gkey, v_gval IN SELECT key, value::INTEGER FROM jsonb_each_text(v_once)
    LOOP
        CONTINUE WHEN v_gval IS NULL OR v_gval <= 0;
        PERFORM add_credits(
            p_subscriber_tenant_id,
            CASE WHEN v_gkey IN ('whatsapp','sms','email','inapp')
                 THEN 'notification' ELSE v_gkey END,
            v_gval,
            CASE WHEN v_gkey IN ('whatsapp','sms','email','inapp')
                 THEN v_gkey ELSE NULL END,
            'plan_grant',
            (v_result->'data'->>'id'),
            'Included with ' || COALESCE(v_template.display_name, v_template.name),
            'contract'
        );
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
        'previous_contract_id', v_previous_contract_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;
