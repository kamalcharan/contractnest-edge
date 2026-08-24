-- ═══════════════════════════════════════════════════════════════════
-- contracts-v2/003_purchase_topup_template_v2.sql
-- JTD Nucleus initiative — Milestone 1 Sprint 3
--
-- New, versioned sibling of purchase_topup_template (business-model-v2/
-- 023_topup_is_a_contract.sql). That function is untouched — this is a
-- separate function, nothing currently running calls it.
--
-- Only change: the single create_contract_transaction(...) call is
-- replaced with create_contract_transaction_v2(...), passing tenant/
-- seller/buyer explicitly. Everything else — pack-vs-plan gating,
-- contact lookup-or-create, grant snapshotting — carried over unchanged.
--
-- Same Revenue-mode reasoning as subscribe_tenant_to_plan_v2: platform
-- is seller, buying tenant's contact is buyer. No Expense-mode ambiguity.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.purchase_topup_template_v2(
    p_template_id UUID, p_buyer_tenant_id UUID, p_user_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_platform_id UUID;
    v_template    RECORD;
    v_buyer       RECORD;
    v_contact_id  UUID;
    v_seq         JSONB;
    v_blocks      JSONB := '[]'::JSONB;
    v_block       JSONB;
    v_meter       JSONB;
    v_grants      JSONB := '{}'::JSONB;
    v_events      JSONB := '[]'::JSONB;
    v_payload     JSONB;
    v_result      JSONB;
    v_contract_id UUID;
    v_dur_value   INTEGER;
    v_dur_unit    TEXT;
BEGIN
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No platform tenant configured',
                                  'error_code', 'NO_PLATFORM_TENANT');
    END IF;

    IF p_buyer_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'buyer tenant is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    IF p_buyer_tenant_id = v_platform_id THEN
        RETURN jsonb_build_object('success', false,
            'error', 'The platform tenant cannot buy its own credit pack',
            'error_code', 'SELF_PURCHASE');
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
        RETURN jsonb_build_object('success', false,
            'error', 'Pack not found, not published, or not listed for sale',
            'error_code', 'PACK_NOT_AVAILABLE');
    END IF;

    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_meter := v_block->'config_overrides'->'config'->'metering';
        CONTINUE WHEN v_meter IS NULL;
        IF v_meter->>'mode' = 'one_time' AND v_meter->'grants' IS NOT NULL THEN
            v_grants := v_grants || v_meter->'grants';
        END IF;
    END LOOP;

    IF v_grants = '{}'::JSONB THEN
        RETURN jsonb_build_object('success', false,
            'error', 'This template grants nothing once — it is a plan, not a credit pack',
            'error_code', 'NOT_A_TOPUP_PACK');
    END IF;

    SELECT id, name INTO v_buyer FROM t_tenants WHERE id = p_buyer_tenant_id;
    IF v_buyer.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Buyer tenant not found',
                                  'error_code', 'TENANT_NOT_FOUND');
    END IF;

    SELECT id INTO v_contact_id
    FROM t_contacts
    WHERE tenant_id = v_platform_id AND is_live = TRUE
      AND source_tenant_id = p_buyer_tenant_id
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        v_seq := get_next_formatted_sequence('CONTACT', v_platform_id, TRUE);
        INSERT INTO t_contacts (
            tenant_id, is_live, type, name, company_name, contact_number,
            classifications, status, is_active, is_seed,
            source, source_tenant_id, created_by
        ) VALUES (
            v_platform_id, TRUE, 'corporate',
            NULL, v_buyer.name, v_seq->>'formatted',
            '["client"]'::JSONB, 'active', TRUE, FALSE,
            'topup_purchase', p_buyer_tenant_id, p_user_id
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
            'billing_cycle',   'prepaid',
            'total_price',     COALESCE((v_block->'config_overrides'->>'total_price')::NUMERIC, 0),
            'custom_fields',   jsonb_build_object(
                                  'config',   COALESCE(v_block->'config_overrides'->'config', '{}'::JSONB),
                                  'currency', COALESCE(v_template.currency, 'INR'),
                                  'notes',    'Credit pack: ' || COALESCE(v_template.display_name, v_template.name)
                               )
        ));
    END LOOP;

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

    v_dur_value := COALESCE((v_template.settings->'defaults'->>'duration_value')::INT, 1);
    v_dur_unit  := COALESCE(v_template.settings->'defaults'->>'duration_unit', 'months');

    v_payload := jsonb_build_object(
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
        'buyer_company',     v_buyer.name,
        'currency',          COALESCE(v_template.currency, 'INR'),
        'duration_value',    v_dur_value,
        'duration_unit',     v_dur_unit,
        'start_date',        now(),
        'acceptance_method', 'auto',
        'nomenclature_id',   v_template.settings->'defaults'->>'nomenclature_id',
        'billing_cycle_type','unified',
        'grand_total',       COALESCE(v_template.total, 0),
        'total_value',       COALESCE(v_template.total, 0),
        'tax_total',         0,
        'discount_total',    0,
        'blocks',            v_blocks,
        'computed_events',   v_events,
        'created_by',        p_user_id,
        'performed_by_type', 'user',
        'metadata',          jsonb_build_object(
                                'source',           'topup_purchase',
                                'pack_template_id', v_template.id,
                                'buyer_tenant_id',  p_buyer_tenant_id,
                                'topup_grants',     v_grants
                             )
    );

    v_result := create_contract_transaction_v2(
        v_platform_id, v_platform_id, v_contact_id,
        v_payload, TRUE, NULL
    );

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object('success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED', 'detail', v_result);
    END IF;

    v_contract_id := (v_result->'data'->>'id')::UUID;

    IF COALESCE(v_template.total, 0) <= 0 THEN
        PERFORM fn_apply_topup_grants(v_contract_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_contract_id,
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'pack_name',       COALESCE(v_template.display_name, v_template.name),
        'amount',          COALESCE(v_template.total, 0),
        'currency',        COALESCE(v_template.currency, 'INR'),
        'grants',          v_grants,
        'credits_pending', COALESCE(v_template.total, 0) > 0
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION public.purchase_topup_template_v2 IS
'V2 sibling of purchase_topup_template — JTD Nucleus initiative, Milestone 1 Sprint 3. Calls create_contract_transaction_v2 with explicit seller/buyer instead of a buried payload key. Not called by any live pathway yet.';
