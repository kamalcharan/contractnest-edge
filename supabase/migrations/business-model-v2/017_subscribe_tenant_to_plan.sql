-- =====================================================================
-- 017_subscribe_tenant_to_plan.sql
--
-- Sprint 1 step 7 — tenant self-service subscription.
--
-- A tenant opens /businessmodel/tenants/pricing-plans, clicks a plan, and
-- ONE transaction does all of this:
--
--   1. creates a contact for that tenant in the PLATFORM tenant's book,
--      stamped with source_tenant_id so the contact is permanently tied
--      back to the tenant account it represents
--   2. raises a contract under the PLATFORM tenant from the plan template
--   3. applies the plan's metering blocks to the SUBSCRIBER's
--      t_tenant_context — limits, credit grant rates, add-on flags
--
-- Why the contact is created here rather than by hand: source_tenant_id is
-- the only link between "a contact on a contract" and "a tenant account".
-- Nothing in the product writes it today (17 of 361 rows have it, all
-- seed data), so a hand-made contact leaves the subscription unattributable.
-- Creating it FROM the subscribing tenant's own record sets it by
-- construction, which is the whole reason this flow is buyer-initiated.
--
-- ALWAYS LIVE. There is no p_is_live parameter and no environment scoping
-- anywhere in here. ContractNest's own commercial model exists once: a tenant
-- switching to its test environment is still on the same real plan, billed for
-- real. Scoping by environment gave every tenant a phantom second plan in test.
--
-- Cross-tenant by design: the caller is the subscriber, but the contact and
-- contract are written under the platform tenant. That is why this is a
-- SECURITY DEFINER function with its own guards rather than something the
-- normal contracts endpoint could do — that endpoint forces tenant_id from
-- the request header, and correctly so.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.subscribe_tenant_to_plan(
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
    -- ── platform tenant, by FLAG never by hardcoded id ────────────────
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No platform tenant configured',
                                  'error_code', 'NO_PLATFORM_TENANT');
    END IF;

    IF p_subscriber_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'subscriber tenant is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    -- The platform tenant is billing-exempt; letting it subscribe to itself
    -- would create a contract where buyer and seller are the same tenant.
    IF p_subscriber_tenant_id = v_platform_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'The platform tenant cannot subscribe to its own plan',
                                  'error_code', 'SELF_SUBSCRIPTION');
    END IF;

    -- ── the plan must be published AND listed ─────────────────────────
    -- lifecycle=signed_off means "published, usable to create contracts".
    -- is_public means "offered for sale". Both are required: a plan can be
    -- published for internal use while not yet on the price list.
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

    -- ── already on a plan? ────────────────────────────────────────────
    -- Identified through the contact's source_tenant_id rather than a
    -- column on t_contracts: the contact IS the link to the tenant account.
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

    -- ── 1. contact in the PLATFORM tenant's book ──────────────────────
    SELECT id INTO v_contact_id
    FROM t_contacts
    WHERE tenant_id = v_platform_id
      AND is_live = TRUE
      AND source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        v_seq := get_next_formatted_sequence('CONTACT', v_platform_id, TRUE);

        -- t_contacts_type_name_check: a 'corporate' contact must carry
        -- company_name and leave name NULL (only 'individual' uses name).
        -- A subscribing tenant is an organisation, so corporate is correct.
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

    -- ── 2. contract from the plan template ────────────────────────────
    -- Blocks are rebuilt from the template's own snapshot into the shape
    -- create_contract_transaction expects. custom_fields carries config
    -- through verbatim, which is how config.metering and billingOnly reach
    -- t_contract_blocks and therefore the event-derivation engine.
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
    --
    -- create_contract_transaction does NOT derive events; it stores whatever
    -- computed_events it is handed (the wizard computes them client-side).
    -- Passing none is why the first cut of this function produced a contract
    -- with no billing event at all.
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
        -- Auto-acceptance: the tenant subscribed by clicking. There is no
        -- counterparty to chase, so the contract goes straight to active.
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

    v_result := create_contract_transaction(v_payload, NULL);

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        -- Bubble the real reason up rather than a generic failure: the most
        -- common cause is a missing sequence for the platform tenant, which
        -- otherwise surfaces to the browser as an opaque 502.
        RETURN jsonb_build_object(
            'success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED',
            'detail', v_result
        );
    END IF;

    -- ── 3. apply the plan's metering to the SUBSCRIBER's context ──────
    -- Merged across every metering block on the template, so a plan may
    -- carry several (a limit block plus a flag block, say).
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
        -- Blank/absent in the plan means 0, never unlimited. NULL on these
        -- columns is reserved for the exempt platform tenant.
        limit_contracts   = COALESCE((v_limits->>'contracts')::INT, 0),
        limit_rfqs        = COALESCE((v_limits->>'rfqs')::INT, 0),
        -- Grant rates are configuration read at creation time, not a balance.
        -- Empty here means the platform-wide rate applies.
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

COMMENT ON FUNCTION public.subscribe_tenant_to_plan IS
'Tenant self-service plan subscription. Creates the tenant''s contact in the platform tenant''s book (stamping source_tenant_id), raises the plan contract under the platform tenant, and applies the plan''s metering blocks to the subscriber''s t_tenant_context.';

-- Verify:
--   select subscribe_tenant_to_plan(
--     '<template_id>'::uuid, '<subscriber_tenant_id>'::uuid, null);
