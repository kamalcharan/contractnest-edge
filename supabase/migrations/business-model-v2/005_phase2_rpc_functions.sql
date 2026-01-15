-- ============================================================================
-- Business Model Phase 2 - Additional RPC Functions
-- ============================================================================
-- Purpose: Add RPC functions for Phase 2 billing edge operations
-- Depends on: 003a_rpc_functions.sql (Phase 1)
-- ============================================================================

-- ============================================================================
-- 1. GET INVOICE ESTIMATE
-- ============================================================================
-- Calculates estimated invoice for upcoming billing period
-- Used by: GET /billing/invoice/estimate/:tenantId

CREATE OR REPLACE FUNCTION get_invoice_estimate(
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_subscription RECORD;
    v_product_config RECORD;
    v_usage JSONB;
    v_line_items JSONB := '[]'::JSONB;
    v_base_fee NUMERIC := 0;
    v_usage_charges NUMERIC := 0;
    v_storage_charges NUMERIC := 0;
    v_total NUMERIC := 0;
    v_period_start DATE;
    v_period_end DATE;
    v_billing_config JSONB;
BEGIN
    -- Get active subscription
    SELECT * INTO v_subscription
    FROM t_bm_tenant_subscription
    WHERE tenant_id = p_tenant_id
      AND status IN ('active', 'trial')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_subscription IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No active subscription found',
            'tenant_id', p_tenant_id
        );
    END IF;

    -- Get product config
    SELECT * INTO v_product_config
    FROM t_bm_product_config
    WHERE product_code = v_subscription.product_code
      AND is_active = true;

    IF v_product_config IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Product configuration not found',
            'product_code', v_subscription.product_code
        );
    END IF;

    v_billing_config := v_product_config.billing_config;

    -- Determine billing period
    v_period_start := COALESCE(v_subscription.current_period_start, date_trunc('month', CURRENT_DATE)::DATE);

    -- Calculate period end based on billing cycle
    CASE v_subscription.billing_cycle
        WHEN 'monthly' THEN
            v_period_end := v_period_start + INTERVAL '1 month' - INTERVAL '1 day';
        WHEN 'quarterly' THEN
            v_period_end := v_period_start + INTERVAL '3 months' - INTERVAL '1 day';
        WHEN 'annual' THEN
            v_period_end := v_period_start + INTERVAL '1 year' - INTERVAL '1 day';
        ELSE
            v_period_end := v_period_start + INTERVAL '1 month' - INTERVAL '1 day';
    END CASE;

    -- Aggregate usage for the period
    v_usage := aggregate_usage(p_tenant_id, v_period_start::TIMESTAMPTZ, v_period_end::TIMESTAMPTZ);

    -- Calculate base fee (user tiers)
    IF v_billing_config->'base_fee' IS NOT NULL THEN
        DECLARE
            v_user_count INT := COALESCE((v_usage->>'user')::INT, 1);
            v_tier RECORD;
            v_months INT;
        BEGIN
            -- Calculate months in period
            v_months := CASE v_subscription.billing_cycle
                WHEN 'monthly' THEN 1
                WHEN 'quarterly' THEN 3
                WHEN 'annual' THEN 12
                ELSE 1
            END;

            -- Find applicable tier
            FOR v_tier IN
                SELECT * FROM jsonb_to_recordset(v_billing_config->'base_fee'->'user_tiers')
                AS x(users_from INT, users_to INT, monthly_amount NUMERIC, per_user_amount NUMERIC)
                ORDER BY users_from
            LOOP
                IF v_user_count >= v_tier.users_from AND
                   (v_tier.users_to IS NULL OR v_user_count <= v_tier.users_to) THEN
                    IF v_tier.per_user_amount IS NOT NULL THEN
                        v_base_fee := v_tier.per_user_amount * v_user_count * v_months;
                    ELSE
                        v_base_fee := COALESCE(v_tier.monthly_amount, 0) * v_months;
                    END IF;
                    EXIT;
                END IF;
            END LOOP;

            IF v_base_fee > 0 THEN
                v_line_items := v_line_items || jsonb_build_object(
                    'description', 'Platform Fee (' || v_user_count || ' users)',
                    'quantity', v_months,
                    'unit_price', v_base_fee / v_months,
                    'amount', v_base_fee
                );
            END IF;
        END;
    END IF;

    -- Calculate contract/usage charges
    IF v_billing_config->'unit_charges'->'contract' IS NOT NULL THEN
        DECLARE
            v_contract_count INT := COALESCE((v_usage->>'contract')::INT, 0);
            v_contract_charge NUMERIC := 0;
        BEGIN
            IF v_contract_count > 0 THEN
                -- Use tiered pricing if available
                IF v_billing_config->'unit_charges'->'contract'->'tiers' IS NOT NULL THEN
                    v_contract_charge := calculate_tiered_price(
                        v_billing_config->'unit_charges'->'contract'->'tiers',
                        v_contract_count
                    );
                ELSE
                    v_contract_charge := v_contract_count *
                        COALESCE((v_billing_config->'unit_charges'->'contract'->>'base_price')::NUMERIC, 0);
                END IF;

                v_usage_charges := v_usage_charges + v_contract_charge;

                v_line_items := v_line_items || jsonb_build_object(
                    'description', 'Contract Charges',
                    'quantity', v_contract_count,
                    'unit_price', ROUND(v_contract_charge / NULLIF(v_contract_count, 0), 2),
                    'amount', v_contract_charge
                );
            END IF;
        END;
    END IF;

    -- Calculate storage overage
    IF v_billing_config->'storage' IS NOT NULL THEN
        DECLARE
            v_storage_used INT := COALESCE((v_usage->>'storage_mb')::INT, 0);
            v_included_mb INT := COALESCE((v_billing_config->'storage'->>'included_mb')::INT, 0);
            v_overage_rate NUMERIC := COALESCE((v_billing_config->'storage'->>'overage_per_mb')::NUMERIC, 0);
            v_overage_mb INT;
        BEGIN
            v_overage_mb := GREATEST(0, v_storage_used - v_included_mb);
            IF v_overage_mb > 0 AND v_overage_rate > 0 THEN
                v_storage_charges := v_overage_mb * v_overage_rate;

                v_line_items := v_line_items || jsonb_build_object(
                    'description', 'Storage Overage (' || v_overage_mb || ' MB)',
                    'quantity', v_overage_mb,
                    'unit_price', v_overage_rate,
                    'amount', v_storage_charges
                );
            END IF;
        END;
    END IF;

    -- Calculate total
    v_total := v_base_fee + v_usage_charges + v_storage_charges;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'subscription_id', v_subscription.id,
        'product_code', v_subscription.product_code,
        'billing_cycle', v_subscription.billing_cycle,
        'period', jsonb_build_object(
            'start', v_period_start,
            'end', v_period_end
        ),
        'usage', v_usage,
        'line_items', v_line_items,
        'summary', jsonb_build_object(
            'base_fee', v_base_fee,
            'usage_charges', v_usage_charges,
            'storage_charges', v_storage_charges,
            'subtotal', v_total,
            'tax', 0,
            'total', v_total
        ),
        'currency', COALESCE(v_billing_config->>'currency', 'INR'),
        'next_billing_date', v_subscription.next_billing_date,
        'estimated_at', NOW()
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_invoice_estimate(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_invoice_estimate(UUID) TO service_role;


-- ============================================================================
-- 2. GET USAGE SUMMARY
-- ============================================================================
-- Returns usage summary with limits and percentages
-- Used by: GET /billing/usage/:tenantId

CREATE OR REPLACE FUNCTION get_usage_summary(
    p_tenant_id UUID,
    p_period_start TIMESTAMPTZ DEFAULT NULL,
    p_period_end TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_subscription RECORD;
    v_product_config RECORD;
    v_billing_config JSONB;
    v_usage JSONB;
    v_actual_start TIMESTAMPTZ;
    v_actual_end TIMESTAMPTZ;
    v_metrics JSONB := '{}'::JSONB;
BEGIN
    -- Get active subscription
    SELECT * INTO v_subscription
    FROM t_bm_tenant_subscription
    WHERE tenant_id = p_tenant_id
      AND status IN ('active', 'trial', 'grace_period')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_subscription IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No active subscription found',
            'tenant_id', p_tenant_id
        );
    END IF;

    -- Get product config
    SELECT * INTO v_product_config
    FROM t_bm_product_config
    WHERE product_code = v_subscription.product_code
      AND is_active = true;

    v_billing_config := COALESCE(v_product_config.billing_config, '{}'::JSONB);

    -- Determine period
    v_actual_start := COALESCE(p_period_start, v_subscription.current_period_start, date_trunc('month', CURRENT_DATE));
    v_actual_end := COALESCE(p_period_end,
        CASE v_subscription.billing_cycle
            WHEN 'monthly' THEN v_actual_start + INTERVAL '1 month'
            WHEN 'quarterly' THEN v_actual_start + INTERVAL '3 months'
            WHEN 'annual' THEN v_actual_start + INTERVAL '1 year'
            ELSE v_actual_start + INTERVAL '1 month'
        END
    );

    -- Aggregate usage
    v_usage := aggregate_usage(p_tenant_id, v_actual_start, v_actual_end);

    -- Build metrics with limits
    -- Contracts
    DECLARE
        v_contract_used INT := COALESCE((v_usage->>'contract')::INT, 0);
        v_contract_limit INT := NULL; -- Could be configured per plan
    BEGIN
        v_metrics := v_metrics || jsonb_build_object(
            'contracts', jsonb_build_object(
                'used', v_contract_used,
                'limit', v_contract_limit,
                'percentage', CASE WHEN v_contract_limit IS NOT NULL AND v_contract_limit > 0
                    THEN ROUND((v_contract_used::NUMERIC / v_contract_limit) * 100, 1)
                    ELSE NULL END,
                'unlimited', v_contract_limit IS NULL
            )
        );
    END;

    -- Users
    DECLARE
        v_user_count INT := COALESCE((v_usage->>'user')::INT, 1);
        v_included_users INT := COALESCE((v_billing_config->'base_fee'->>'included_users')::INT, 2);
    BEGIN
        v_metrics := v_metrics || jsonb_build_object(
            'users', jsonb_build_object(
                'used', v_user_count,
                'included', v_included_users,
                'extra', GREATEST(0, v_user_count - v_included_users)
            )
        );
    END;

    -- Storage
    DECLARE
        v_storage_used INT := COALESCE((v_usage->>'storage_mb')::INT, 0);
        v_storage_included INT := COALESCE((v_billing_config->'storage'->>'included_mb')::INT, 40);
    BEGIN
        v_metrics := v_metrics || jsonb_build_object(
            'storage', jsonb_build_object(
                'used_mb', v_storage_used,
                'included_mb', v_storage_included,
                'overage_mb', GREATEST(0, v_storage_used - v_storage_included),
                'percentage', ROUND((v_storage_used::NUMERIC / NULLIF(v_storage_included, 0)) * 100, 1)
            )
        );
    END;

    -- Notifications (from credits)
    DECLARE
        v_notif_balance RECORD;
    BEGIN
        SELECT
            COALESCE(SUM(balance), 0) as total_balance
        INTO v_notif_balance
        FROM t_bm_credit_balance
        WHERE tenant_id = p_tenant_id
          AND credit_type = 'notification'
          AND (expires_at IS NULL OR expires_at > NOW());

        v_metrics := v_metrics || jsonb_build_object(
            'notifications', jsonb_build_object(
                'credits_remaining', v_notif_balance.total_balance,
                'low_threshold', 50,
                'is_low', v_notif_balance.total_balance < 50
            )
        );
    END;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'subscription_id', v_subscription.id,
        'product_code', v_subscription.product_code,
        'status', v_subscription.status,
        'period', jsonb_build_object(
            'start', v_actual_start,
            'end', v_actual_end,
            'days_remaining', GREATEST(0, (v_actual_end::DATE - CURRENT_DATE))
        ),
        'metrics', v_metrics,
        'raw_usage', v_usage,
        'generated_at', NOW()
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_usage_summary(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION get_usage_summary(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO service_role;


-- ============================================================================
-- 3. GET TOPUP PACKS
-- ============================================================================
-- Returns available topup packs for purchase
-- Used by: GET /billing/topup-packs

CREATE OR REPLACE FUNCTION get_topup_packs(
    p_product_code TEXT DEFAULT NULL,
    p_credit_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_packs JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'product_code', product_code,
            'credit_type', credit_type,
            'name', name,
            'quantity', quantity,
            'price', price,
            'currency', currency_code,
            'expiry_days', expiry_days,
            'price_per_unit', ROUND(price / quantity, 2)
        ) ORDER BY product_code, credit_type, sort_order, price
    )
    INTO v_packs
    FROM t_bm_topup_pack
    WHERE is_active = true
      AND (p_product_code IS NULL OR product_code = p_product_code)
      AND (p_credit_type IS NULL OR credit_type = p_credit_type);

    RETURN jsonb_build_object(
        'success', true,
        'packs', COALESCE(v_packs, '[]'::JSONB),
        'count', COALESCE(jsonb_array_length(v_packs), 0)
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_topup_packs(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_topup_packs(TEXT, TEXT) TO service_role;


-- ============================================================================
-- 4. GET SUBSCRIPTION DETAILS
-- ============================================================================
-- Returns detailed subscription information
-- Used by: GET /billing/subscription/:tenantId

CREATE OR REPLACE FUNCTION get_subscription_details(
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_subscription RECORD;
    v_product_config RECORD;
    v_plan RECORD;
    v_credits JSONB;
BEGIN
    -- Get subscription with plan details
    SELECT
        s.*,
        pv.name as plan_name,
        pv.description as plan_description,
        pv.billing_config as plan_billing_config
    INTO v_subscription
    FROM t_bm_tenant_subscription s
    LEFT JOIN t_bm_plan_version pv ON s.plan_version_id = pv.id
    WHERE s.tenant_id = p_tenant_id
      AND s.status IN ('active', 'trial', 'grace_period', 'suspended')
    ORDER BY s.created_at DESC
    LIMIT 1;

    IF v_subscription IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No subscription found',
            'tenant_id', p_tenant_id
        );
    END IF;

    -- Get product config
    SELECT * INTO v_product_config
    FROM t_bm_product_config
    WHERE product_code = v_subscription.product_code
      AND is_active = true;

    -- Get credit balances
    SELECT jsonb_object_agg(
        credit_type || COALESCE('_' || channel, ''),
        jsonb_build_object(
            'balance', balance,
            'expires_at', expires_at
        )
    )
    INTO v_credits
    FROM t_bm_credit_balance
    WHERE tenant_id = p_tenant_id
      AND (expires_at IS NULL OR expires_at > NOW());

    RETURN jsonb_build_object(
        'success', true,
        'subscription', jsonb_build_object(
            'id', v_subscription.id,
            'tenant_id', v_subscription.tenant_id,
            'product_code', v_subscription.product_code,
            'product_name', COALESCE(v_product_config.product_name, v_subscription.product_code),
            'plan_name', v_subscription.plan_name,
            'plan_description', v_subscription.plan_description,
            'status', v_subscription.status,
            'billing_cycle', v_subscription.billing_cycle,
            'current_period_start', v_subscription.current_period_start,
            'current_period_end', v_subscription.current_period_end,
            'next_billing_date', v_subscription.next_billing_date,
            'trial_end_date', v_subscription.trial_end_date,
            'grace_end_date', v_subscription.grace_end_date,
            'created_at', v_subscription.created_at
        ),
        'credits', COALESCE(v_credits, '{}'::JSONB),
        'product_config', jsonb_build_object(
            'billing_model', v_product_config.billing_config->>'billing_model',
            'trial_days', COALESCE((v_product_config.billing_config->'trial'->>'days')::INT, 0),
            'grace_days', COALESCE((v_product_config.billing_config->'grace_period'->>'days')::INT, 0)
        )
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_subscription_details(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_subscription_details(UUID) TO service_role;


-- ============================================================================
-- 5. PURCHASE TOPUP
-- ============================================================================
-- Process a topup pack purchase
-- Used by: POST /billing/credits/topup

CREATE OR REPLACE FUNCTION purchase_topup(
    p_tenant_id UUID,
    p_pack_id UUID,
    p_payment_reference TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_pack RECORD;
    v_expiry TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    -- Get pack details
    SELECT * INTO v_pack
    FROM t_bm_topup_pack
    WHERE id = p_pack_id
      AND is_active = true;

    IF v_pack IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Topup pack not found or inactive',
            'pack_id', p_pack_id
        );
    END IF;

    -- Calculate expiry
    IF v_pack.expiry_days IS NOT NULL THEN
        v_expiry := NOW() + (v_pack.expiry_days || ' days')::INTERVAL;
    END IF;

    -- Add credits using existing function
    v_result := add_credits(
        p_tenant_id,
        v_pack.credit_type,
        v_pack.quantity,
        NULL, -- channel - determined by credit_type
        'topup',
        p_pack_id,
        'Purchased: ' || v_pack.name
    );

    IF NOT (v_result->>'success')::BOOLEAN THEN
        RETURN v_result;
    END IF;

    -- Log billing event
    INSERT INTO t_bm_billing_event (
        tenant_id,
        event_type,
        event_data,
        processed,
        processed_at
    ) VALUES (
        p_tenant_id,
        'credits_purchased',
        jsonb_build_object(
            'pack_id', p_pack_id,
            'pack_name', v_pack.name,
            'credit_type', v_pack.credit_type,
            'quantity', v_pack.quantity,
            'price', v_pack.price,
            'currency', v_pack.currency_code,
            'payment_reference', p_payment_reference
        ),
        true,
        NOW()
    );

    RETURN jsonb_build_object(
        'success', true,
        'pack', jsonb_build_object(
            'id', v_pack.id,
            'name', v_pack.name,
            'credit_type', v_pack.credit_type,
            'quantity', v_pack.quantity,
            'price', v_pack.price,
            'currency', v_pack.currency_code
        ),
        'credits_added', v_pack.quantity,
        'new_balance', v_result->'new_balance',
        'expires_at', v_expiry
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION purchase_topup(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION purchase_topup(UUID, UUID, TEXT) TO service_role;


-- ============================================================================
-- COMMENTS
-- ============================================================================
COMMENT ON FUNCTION get_invoice_estimate(UUID) IS
'Calculates estimated invoice amount for the current billing period based on usage and product config';

COMMENT ON FUNCTION get_usage_summary(UUID, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Returns detailed usage summary with limits, percentages, and credit balances';

COMMENT ON FUNCTION get_topup_packs(TEXT, TEXT) IS
'Returns available topup packs, optionally filtered by product and credit type';

COMMENT ON FUNCTION get_subscription_details(UUID) IS
'Returns comprehensive subscription details including plan, status, and credits';

COMMENT ON FUNCTION purchase_topup(UUID, UUID, TEXT) IS
'Processes a topup pack purchase and adds credits to tenant balance';
