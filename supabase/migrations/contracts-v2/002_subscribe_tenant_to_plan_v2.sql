-- ═══════════════════════════════════════════════════════════════════
-- contracts-v2/002_subscribe_tenant_to_plan_v2.sql
-- JTD Nucleus initiative — Milestone 1 Sprint 3
--
-- New, versioned sibling of subscribe_tenant_to_plan (business-model-v2/
-- 017_subscribe_tenant_to_plan.sql). That function is untouched — this
-- is a separate function, nothing currently running calls it.
--
-- Only change: the single create_contract_transaction(...) call is
-- replaced with create_contract_transaction_v2(...), passing tenant/
-- seller/buyer explicitly instead of burying buyer_id in the JSONB
-- payload. Everything else — platform-tenant resolution, self-
-- subscription guard, contact lookup-or-create, metering application —
-- is carried over unchanged.
--
-- Seller/buyer resolution here is Revenue-mode and correct as-is: the
-- PLATFORM tenant is the seller (it's selling the plan), the subscribing
-- tenant's contact is the buyer. No Expense-mode ambiguity — that only
-- applies to counterparty-initiated (vendor-authored) contract creation,
-- which is explicitly out of scope until the RFQ vendor-authored-contract
-- work is picked up.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.subscribe_tenant_to_plan_v2(
    p_template_id           UUID,
    p_subscriber_tenant_id  UUID,
    p_user_id               UUID    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_platform_id     UUID;
    v_template        RECORD;
    v_subscriber      RECORD;
    v_contact_id      UUID;
    v_seq             JSONB;
    v_existing        RECORD;
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

    SELECT c.id, c.contract_number INTO v_existing
    FROM t_contracts c
    JOIN t_contacts ct ON ct.id = c.buyer_id
    WHERE c.tenant_id = v_platform_id
      AND c.is_live = TRUE
      AND c.record_type = 'contract'
      AND c.status IN ('active', 'pending_acceptance')
      AND ct.source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This tenant already has an active plan (' || v_existing.contract_number || ')',
            'error_code', 'ALREADY_SUBSCRIBED',
            'contract_id', v_existing.id
        );
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
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
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
                                'source',              'plan_subscription',
                                'plan_template_id',    v_template.id,
                                'subscriber_tenant_id', p_subscriber_tenant_id
                             )
    );

    -- Platform is seller (it's selling the plan); subscriber's contact is buyer.
    v_result := create_contract_transaction_v2(
        v_platform_id, v_platform_id, v_contact_id,
        v_payload, TRUE, NULL
    );

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
        ELSIF v_meter->>'mode' IN ('per_creation', 'one_time') AND v_meter->'grants' IS NOT NULL THEN
            v_grants := v_grants || v_meter->'grants';
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
        updated_at        = now()
    WHERE product_code = 'contractnest'
      AND tenant_id = p_subscriber_tenant_id;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_result->'data'->>'id',
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'plan_name',       COALESCE(v_template.display_name, v_template.name),
        'limits',          v_limits,
        'grants',          v_grants,
        'flags',           to_jsonb(v_flags)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;

COMMENT ON FUNCTION public.subscribe_tenant_to_plan_v2 IS
'V2 sibling of subscribe_tenant_to_plan — JTD Nucleus initiative, Milestone 1 Sprint 3. Calls create_contract_transaction_v2 with explicit seller/buyer instead of a buried payload key. Not called by any live pathway yet.';
