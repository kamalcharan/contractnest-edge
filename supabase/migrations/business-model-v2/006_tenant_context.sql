-- ============================================================================
-- Migration: 006_tenant_context.sql
-- Purpose: Create t_tenant_context table and triggers for Phase 3
-- Created: January 2025
-- ============================================================================

-- ============================================================================
-- 1. CREATE t_tenant_context TABLE
-- ============================================================================
-- This is a materialized/denormalized table for fast lookups
-- Updated automatically by triggers on source tables

CREATE TABLE IF NOT EXISTS t_tenant_context (
    -- ===== PRIMARY KEY =====
    product_code TEXT NOT NULL,
    tenant_id UUID NOT NULL,

    -- ===== PROFILE (denormalized from t_tenant_profile) =====
    business_name TEXT,
    logo_url TEXT,
    primary_color TEXT,
    secondary_color TEXT,

    -- ===== SUBSCRIPTION (denormalized from t_bm_tenant_subscription) =====
    subscription_id UUID,
    subscription_status TEXT,  -- 'active', 'trial', 'grace_period', 'suspended', NULL
    plan_name TEXT,
    billing_cycle TEXT,        -- 'monthly', 'quarterly', 'annual'
    period_start DATE,
    period_end DATE,
    trial_end_date DATE,
    grace_end_date DATE,
    next_billing_date DATE,

    -- ===== CREDITS (aggregated from t_bm_credit_balance) =====
    -- These are AVAILABLE credits (balance - reserved)
    credits_whatsapp INTEGER NOT NULL DEFAULT 0,
    credits_sms INTEGER NOT NULL DEFAULT 0,
    credits_email INTEGER NOT NULL DEFAULT 0,
    credits_pooled INTEGER NOT NULL DEFAULT 0,  -- channel IS NULL

    -- ===== LIMITS (from plan/product config) =====
    limit_users INTEGER,           -- NULL = unlimited
    limit_contracts INTEGER,       -- NULL = unlimited
    limit_storage_mb INTEGER DEFAULT 40,

    -- ===== USAGE (aggregated from t_bm_subscription_usage, current period) =====
    usage_users INTEGER NOT NULL DEFAULT 0,
    usage_contracts INTEGER NOT NULL DEFAULT 0,
    usage_storage_mb INTEGER NOT NULL DEFAULT 0,

    -- ===== ADD-ONS (from subscription) =====
    addon_vani_ai BOOLEAN NOT NULL DEFAULT FALSE,
    addon_rfp BOOLEAN NOT NULL DEFAULT FALSE,

    -- ===== COMPUTED FLAGS (for fast decision making) =====
    flag_can_access BOOLEAN NOT NULL DEFAULT FALSE,
    flag_can_send_whatsapp BOOLEAN NOT NULL DEFAULT FALSE,
    flag_can_send_sms BOOLEAN NOT NULL DEFAULT FALSE,
    flag_can_send_email BOOLEAN NOT NULL DEFAULT FALSE,
    flag_credits_low BOOLEAN NOT NULL DEFAULT FALSE,
    flag_near_limit BOOLEAN NOT NULL DEFAULT FALSE,

    -- ===== METADATA =====
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- ===== CONSTRAINTS =====
    PRIMARY KEY (product_code, tenant_id)
);

-- ============================================================================
-- 2. CREATE INDEXES
-- ============================================================================

-- Index for queries by tenant_id only (common pattern)
CREATE INDEX IF NOT EXISTS idx_tenant_context_tenant
ON t_tenant_context (tenant_id);

-- Index for finding tenants by subscription status
CREATE INDEX IF NOT EXISTS idx_tenant_context_status
ON t_tenant_context (product_code, subscription_status);

-- Index for finding recently updated contexts
CREATE INDEX IF NOT EXISTS idx_tenant_context_updated
ON t_tenant_context (updated_at DESC);

-- Index for finding tenants with low credits
CREATE INDEX IF NOT EXISTS idx_tenant_context_credits_low
ON t_tenant_context (product_code)
WHERE flag_credits_low = TRUE;

-- ============================================================================
-- 3. HELPER FUNCTION: Recalculate credit flags
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_recalc_credit_flags(
    p_credits_whatsapp INTEGER,
    p_credits_sms INTEGER,
    p_credits_email INTEGER,
    p_credits_pooled INTEGER,
    p_subscription_status TEXT
)
RETURNS TABLE (
    can_send_whatsapp BOOLEAN,
    can_send_sms BOOLEAN,
    can_send_email BOOLEAN,
    credits_low BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_active BOOLEAN;
    v_low_threshold INTEGER := 10;  -- Credits below this = low
BEGIN
    -- Check if subscription allows sending
    v_is_active := p_subscription_status IN ('active', 'trial', 'grace_period');

    RETURN QUERY SELECT
        v_is_active AND (p_credits_whatsapp + p_credits_pooled) > 0,
        v_is_active AND (p_credits_sms + p_credits_pooled) > 0,
        v_is_active AND (p_credits_email + p_credits_pooled) > 0,
        (p_credits_whatsapp + p_credits_sms + p_credits_email + p_credits_pooled) < v_low_threshold;
END;
$$;

-- ============================================================================
-- 4. TRIGGER FUNCTION: Update context on subscription change
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_update_context_on_subscription()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_product_code TEXT;
    v_plan_name TEXT;
    v_flags RECORD;
BEGIN
    -- Get product_code from the subscription
    v_product_code := COALESCE(NEW.product_code, OLD.product_code);

    -- Get plan name if plan_version_id exists
    IF NEW.plan_version_id IS NOT NULL THEN
        SELECT name INTO v_plan_name
        FROM t_bm_plan_version
        WHERE id = NEW.plan_version_id;
    END IF;

    -- Upsert tenant context
    INSERT INTO t_tenant_context (
        product_code,
        tenant_id,
        subscription_id,
        subscription_status,
        plan_name,
        billing_cycle,
        period_start,
        period_end,
        trial_end_date,
        grace_end_date,
        next_billing_date,
        flag_can_access,
        updated_at
    )
    VALUES (
        v_product_code,
        NEW.tenant_id,
        NEW.id,
        NEW.status,
        v_plan_name,
        NEW.billing_cycle,
        NEW.current_period_start,
        NEW.current_period_end,
        NEW.trial_end_date,
        NEW.grace_end_date,
        NEW.next_billing_date,
        NEW.status IN ('active', 'trial', 'grace_period'),
        NOW()
    )
    ON CONFLICT (product_code, tenant_id)
    DO UPDATE SET
        subscription_id = EXCLUDED.subscription_id,
        subscription_status = EXCLUDED.subscription_status,
        plan_name = EXCLUDED.plan_name,
        billing_cycle = EXCLUDED.billing_cycle,
        period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end,
        trial_end_date = EXCLUDED.trial_end_date,
        grace_end_date = EXCLUDED.grace_end_date,
        next_billing_date = EXCLUDED.next_billing_date,
        flag_can_access = EXCLUDED.flag_can_access,
        updated_at = NOW();

    -- Recalculate credit flags (subscription status affects can_send flags)
    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(
        (SELECT credits_whatsapp FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id),
        (SELECT credits_sms FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id),
        (SELECT credits_email FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id),
        (SELECT credits_pooled FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id),
        NEW.status
    );

    UPDATE t_tenant_context SET
        flag_can_send_whatsapp = v_flags.can_send_whatsapp,
        flag_can_send_sms = v_flags.can_send_sms,
        flag_can_send_email = v_flags.can_send_email,
        flag_credits_low = v_flags.credits_low
    WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id;

    RETURN NEW;
END;
$$;

-- Create trigger on subscription table
DROP TRIGGER IF EXISTS trg_subscription_update_context ON t_bm_tenant_subscription;
CREATE TRIGGER trg_subscription_update_context
AFTER INSERT OR UPDATE ON t_bm_tenant_subscription
FOR EACH ROW
EXECUTE FUNCTION trg_fn_update_context_on_subscription();

-- ============================================================================
-- 5. TRIGGER FUNCTION: Update context on credit balance change
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_update_context_on_credit_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id UUID;
    v_product_code TEXT;
    v_whatsapp INTEGER;
    v_sms INTEGER;
    v_email INTEGER;
    v_pooled INTEGER;
    v_sub_status TEXT;
    v_flags RECORD;
BEGIN
    -- Get tenant_id from new or old record
    v_tenant_id := COALESCE(NEW.tenant_id, OLD.tenant_id);

    -- Get product_code from active subscription
    SELECT product_code, status INTO v_product_code, v_sub_status
    FROM t_bm_tenant_subscription
    WHERE tenant_id = v_tenant_id
      AND status IN ('active', 'trial', 'grace_period')
    ORDER BY created_at DESC
    LIMIT 1;

    -- If no active subscription, skip
    IF v_product_code IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- Aggregate current credits by channel
    SELECT
        COALESCE(SUM(CASE WHEN channel = 'whatsapp' THEN balance - COALESCE(reserved, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel = 'sms' THEN balance - COALESCE(reserved, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel = 'email' THEN balance - COALESCE(reserved, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel IS NULL THEN balance - COALESCE(reserved, 0) END), 0)
    INTO v_whatsapp, v_sms, v_email, v_pooled
    FROM t_bm_credit_balance
    WHERE tenant_id = v_tenant_id
      AND credit_type = 'notification'
      AND (expires_at IS NULL OR expires_at > NOW());

    -- Calculate flags
    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(v_whatsapp, v_sms, v_email, v_pooled, v_sub_status);

    -- Update context
    UPDATE t_tenant_context SET
        credits_whatsapp = v_whatsapp,
        credits_sms = v_sms,
        credits_email = v_email,
        credits_pooled = v_pooled,
        flag_can_send_whatsapp = v_flags.can_send_whatsapp,
        flag_can_send_sms = v_flags.can_send_sms,
        flag_can_send_email = v_flags.can_send_email,
        flag_credits_low = v_flags.credits_low,
        updated_at = NOW()
    WHERE product_code = v_product_code
      AND tenant_id = v_tenant_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Create trigger on credit balance table
DROP TRIGGER IF EXISTS trg_credit_balance_update_context ON t_bm_credit_balance;
CREATE TRIGGER trg_credit_balance_update_context
AFTER INSERT OR UPDATE OR DELETE ON t_bm_credit_balance
FOR EACH ROW
EXECUTE FUNCTION trg_fn_update_context_on_credit_change();

-- ============================================================================
-- 6. TRIGGER FUNCTION: Update context on usage record
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_update_context_on_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_product_code TEXT;
    v_period_start DATE;
    v_period_end DATE;
    v_usage_contracts INTEGER;
    v_usage_storage INTEGER;
    v_usage_users INTEGER;
    v_limit_contracts INTEGER;
    v_limit_storage INTEGER;
BEGIN
    -- Get product_code and period from subscription
    SELECT product_code, current_period_start, current_period_end
    INTO v_product_code, v_period_start, v_period_end
    FROM t_bm_tenant_subscription
    WHERE id = NEW.subscription_id;

    IF v_product_code IS NULL THEN
        RETURN NEW;
    END IF;

    -- Aggregate usage for current period
    SELECT
        COALESCE(SUM(CASE WHEN metric_type = 'contract' THEN quantity END), 0),
        COALESCE(SUM(CASE WHEN metric_type = 'storage_mb' THEN quantity END), 0),
        COALESCE(SUM(CASE WHEN metric_type = 'user' THEN quantity END), 0)
    INTO v_usage_contracts, v_usage_storage, v_usage_users
    FROM t_bm_subscription_usage
    WHERE tenant_id = NEW.tenant_id
      AND recorded_at >= COALESCE(v_period_start, date_trunc('month', NOW()))
      AND recorded_at < COALESCE(v_period_end, date_trunc('month', NOW()) + interval '1 month');

    -- Get limits from context
    SELECT limit_contracts, limit_storage_mb
    INTO v_limit_contracts, v_limit_storage
    FROM t_tenant_context
    WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id;

    -- Update context
    UPDATE t_tenant_context SET
        usage_contracts = v_usage_contracts,
        usage_storage_mb = v_usage_storage,
        usage_users = v_usage_users,
        flag_near_limit = (
            (v_limit_contracts IS NOT NULL AND v_usage_contracts >= v_limit_contracts * 0.9) OR
            (v_limit_storage IS NOT NULL AND v_usage_storage >= v_limit_storage * 0.9)
        ),
        updated_at = NOW()
    WHERE product_code = v_product_code
      AND tenant_id = NEW.tenant_id;

    RETURN NEW;
END;
$$;

-- Create trigger on usage table
DROP TRIGGER IF EXISTS trg_usage_update_context ON t_bm_subscription_usage;
CREATE TRIGGER trg_usage_update_context
AFTER INSERT ON t_bm_subscription_usage
FOR EACH ROW
EXECUTE FUNCTION trg_fn_update_context_on_usage();

-- ============================================================================
-- 7. TRIGGER FUNCTION: Update context on profile change
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_update_context_on_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_product_code TEXT;
BEGIN
    -- Get product_code from active subscription
    SELECT product_code INTO v_product_code
    FROM t_bm_tenant_subscription
    WHERE tenant_id = NEW.tenant_id
      AND status IN ('active', 'trial', 'grace_period')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_product_code IS NULL THEN
        RETURN NEW;
    END IF;

    -- Update context with profile fields
    UPDATE t_tenant_context SET
        business_name = NEW.business_name,
        logo_url = NEW.logo_url,
        primary_color = NEW.primary_color,
        secondary_color = NEW.secondary_color,
        updated_at = NOW()
    WHERE product_code = v_product_code
      AND tenant_id = NEW.tenant_id;

    RETURN NEW;
END;
$$;

-- Create trigger on profile table (if exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_tenant_profile') THEN
        DROP TRIGGER IF EXISTS trg_profile_update_context ON t_tenant_profile;
        CREATE TRIGGER trg_profile_update_context
        AFTER INSERT OR UPDATE ON t_tenant_profile
        FOR EACH ROW
        EXECUTE FUNCTION trg_fn_update_context_on_profile();
    END IF;
END;
$$;

-- ============================================================================
-- 8. RPC FUNCTION: get_tenant_context
-- ============================================================================

CREATE OR REPLACE FUNCTION get_tenant_context(
    p_product_code TEXT,
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_context RECORD;
BEGIN
    -- Validate inputs
    IF p_product_code IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'product_code and tenant_id are required'
        );
    END IF;

    -- Get tenant context
    SELECT * INTO v_context
    FROM t_tenant_context
    WHERE product_code = p_product_code
      AND tenant_id = p_tenant_id;

    -- Not found
    IF v_context IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Tenant context not found',
            'product_code', p_product_code,
            'tenant_id', p_tenant_id
        );
    END IF;

    -- Return structured response
    RETURN jsonb_build_object(
        'success', true,
        'product_code', v_context.product_code,
        'tenant_id', v_context.tenant_id,

        'profile', jsonb_build_object(
            'business_name', v_context.business_name,
            'logo_url', v_context.logo_url,
            'primary_color', v_context.primary_color,
            'secondary_color', v_context.secondary_color
        ),

        'subscription', jsonb_build_object(
            'id', v_context.subscription_id,
            'status', v_context.subscription_status,
            'plan_name', v_context.plan_name,
            'billing_cycle', v_context.billing_cycle,
            'period_start', v_context.period_start,
            'period_end', v_context.period_end,
            'trial_end', v_context.trial_end_date,
            'grace_end', v_context.grace_end_date,
            'next_billing_date', v_context.next_billing_date
        ),

        'credits', jsonb_build_object(
            'whatsapp', v_context.credits_whatsapp,
            'sms', v_context.credits_sms,
            'email', v_context.credits_email,
            'pooled', v_context.credits_pooled
        ),

        'limits', jsonb_build_object(
            'users', v_context.limit_users,
            'contracts', v_context.limit_contracts,
            'storage_mb', v_context.limit_storage_mb
        ),

        'usage', jsonb_build_object(
            'users', v_context.usage_users,
            'contracts', v_context.usage_contracts,
            'storage_mb', v_context.usage_storage_mb
        ),

        'addons', jsonb_build_object(
            'vani_ai', v_context.addon_vani_ai,
            'rfp', v_context.addon_rfp
        ),

        'flags', jsonb_build_object(
            'can_access', v_context.flag_can_access,
            'can_send_whatsapp', v_context.flag_can_send_whatsapp,
            'can_send_sms', v_context.flag_can_send_sms,
            'can_send_email', v_context.flag_can_send_email,
            'credits_low', v_context.flag_credits_low,
            'near_limit', v_context.flag_near_limit
        ),

        'retrieved_at', NOW()
    );
END;
$$;

-- ============================================================================
-- 9. RPC FUNCTION: Initialize tenant context (called on signup)
-- ============================================================================

CREATE OR REPLACE FUNCTION init_tenant_context(
    p_product_code TEXT,
    p_tenant_id UUID,
    p_business_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_context_id UUID;
BEGIN
    -- Insert new tenant context with defaults
    INSERT INTO t_tenant_context (
        product_code,
        tenant_id,
        business_name,
        flag_can_access,  -- False until subscription is assigned
        created_at,
        updated_at
    )
    VALUES (
        p_product_code,
        p_tenant_id,
        p_business_name,
        FALSE,
        NOW(),
        NOW()
    )
    ON CONFLICT (product_code, tenant_id) DO NOTHING;

    RETURN jsonb_build_object(
        'success', true,
        'product_code', p_product_code,
        'tenant_id', p_tenant_id,
        'message', 'Tenant context initialized'
    );
END;
$$;

-- ============================================================================
-- 10. COMMENTS
-- ============================================================================

COMMENT ON TABLE t_tenant_context IS 'Materialized tenant context for fast lookups. Updated by triggers.';
COMMENT ON COLUMN t_tenant_context.credits_whatsapp IS 'Available WhatsApp credits (balance - reserved)';
COMMENT ON COLUMN t_tenant_context.flag_can_send_whatsapp IS 'TRUE if tenant can send WhatsApp (active sub + credits > 0)';
COMMENT ON FUNCTION get_tenant_context IS 'Get complete tenant context as JSON. Primary key: (product_code, tenant_id)';
COMMENT ON FUNCTION init_tenant_context IS 'Initialize tenant context on signup. Called before subscription assignment.';
