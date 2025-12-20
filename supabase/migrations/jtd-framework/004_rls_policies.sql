-- ============================================================
-- Migration: 004_rls_policies
-- Description: Row Level Security policies for JTD tables
-- Author: Claude
-- Date: 2025-12-17
-- ============================================================

-- ============================================================
-- OVERVIEW
-- ============================================================
-- RLS Policies ensure:
-- 1. Tenants can only see their own data
-- 2. VaNi (system actor) can access all tenant data for processing
-- 3. Service role bypasses RLS for admin operations
--
-- VaNi UUID: 00000000-0000-0000-0000-000000000001
-- ============================================================

-- ============================================================
-- 1. ENABLE RLS (if not already enabled in 001)
-- ============================================================

ALTER TABLE public.n_jtd ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_tenant_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_tenant_source_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_templates ENABLE ROW LEVEL SECURITY;

-- Master tables - read-only for all authenticated users
ALTER TABLE public.n_system_actors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_event_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_statuses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_status_flows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_source_types ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 2. HELPER FUNCTION: Get Current User's Tenant ID
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_current_tenant_id()
RETURNS UUID AS $$
BEGIN
    -- Get tenant_id from JWT claims
    RETURN NULLIF(current_setting('request.jwt.claims', true)::json->>'tenant_id', '')::UUID;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION public.get_current_tenant_id IS 'Extract tenant_id from JWT claims';

-- ============================================================
-- 3. HELPER FUNCTION: Check if Current User is VaNi
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_vani_user()
RETURNS BOOLEAN AS $$
DECLARE
    v_user_id UUID;
    v_vani_uuid UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
    -- Get user_id from JWT
    v_user_id := NULLIF(current_setting('request.jwt.claims', true)::json->>'sub', '')::UUID;
    
    -- Check if user is VaNi
    RETURN v_user_id = v_vani_uuid;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION public.is_vani_user IS 'Check if current user is VaNi system actor';

-- ============================================================
-- 4. HELPER FUNCTION: Check if Service Role
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_service_role()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN current_setting('request.jwt.claims', true)::json->>'role' = 'service_role';
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION public.is_service_role IS 'Check if current request is using service role';

-- ============================================================
-- 5. RLS POLICIES: MASTER TABLES (Read-only for all)
-- ============================================================

-- n_system_actors
DROP POLICY IF EXISTS "system_actors_read_all" ON public.n_system_actors;
CREATE POLICY "system_actors_read_all" ON public.n_system_actors
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- n_jtd_event_types
DROP POLICY IF EXISTS "event_types_read_all" ON public.n_jtd_event_types;
CREATE POLICY "event_types_read_all" ON public.n_jtd_event_types
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- n_jtd_channels
DROP POLICY IF EXISTS "channels_read_all" ON public.n_jtd_channels;
CREATE POLICY "channels_read_all" ON public.n_jtd_channels
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- n_jtd_statuses
DROP POLICY IF EXISTS "statuses_read_all" ON public.n_jtd_statuses;
CREATE POLICY "statuses_read_all" ON public.n_jtd_statuses
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- n_jtd_status_flows
DROP POLICY IF EXISTS "status_flows_read_all" ON public.n_jtd_status_flows;
CREATE POLICY "status_flows_read_all" ON public.n_jtd_status_flows
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- n_jtd_source_types
DROP POLICY IF EXISTS "source_types_read_all" ON public.n_jtd_source_types;
CREATE POLICY "source_types_read_all" ON public.n_jtd_source_types
    FOR SELECT
    TO authenticated
    USING (is_active = true);

-- ============================================================
-- 6. RLS POLICIES: n_jtd (Main Transaction Table)
-- ============================================================

-- SELECT: Tenant can see their own, VaNi can see all
DROP POLICY IF EXISTS "jtd_select_tenant" ON public.n_jtd;
CREATE POLICY "jtd_select_tenant" ON public.n_jtd
    FOR SELECT
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    );

-- INSERT: Tenant can insert their own, VaNi/Service can insert any
DROP POLICY IF EXISTS "jtd_insert_tenant" ON public.n_jtd;
CREATE POLICY "jtd_insert_tenant" ON public.n_jtd
    FOR INSERT
    TO authenticated
    WITH CHECK (
        tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    );

-- UPDATE: Tenant can update their own, VaNi/Service can update any
DROP POLICY IF EXISTS "jtd_update_tenant" ON public.n_jtd;
CREATE POLICY "jtd_update_tenant" ON public.n_jtd
    FOR UPDATE
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    )
    WITH CHECK (
        tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    );

-- DELETE: Only service role can delete (soft delete preferred)
DROP POLICY IF EXISTS "jtd_delete_service" ON public.n_jtd;
CREATE POLICY "jtd_delete_service" ON public.n_jtd
    FOR DELETE
    TO authenticated
    USING (is_service_role());

-- ============================================================
-- 7. RLS POLICIES: n_jtd_status_history
-- ============================================================

DROP POLICY IF EXISTS "status_history_select" ON public.n_jtd_status_history;
CREATE POLICY "status_history_select" ON public.n_jtd_status_history
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.n_jtd j
            WHERE j.id = n_jtd_status_history.jtd_id
            AND (j.tenant_id = get_current_tenant_id() OR is_vani_user() OR is_service_role())
        )
    );

DROP POLICY IF EXISTS "status_history_insert" ON public.n_jtd_status_history;
CREATE POLICY "status_history_insert" ON public.n_jtd_status_history
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.n_jtd j
            WHERE j.id = n_jtd_status_history.jtd_id
            AND (j.tenant_id = get_current_tenant_id() OR is_vani_user() OR is_service_role())
        )
    );

-- ============================================================
-- 8. RLS POLICIES: n_jtd_history
-- ============================================================

DROP POLICY IF EXISTS "history_select" ON public.n_jtd_history;
CREATE POLICY "history_select" ON public.n_jtd_history
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.n_jtd j
            WHERE j.id = n_jtd_history.jtd_id
            AND (j.tenant_id = get_current_tenant_id() OR is_vani_user() OR is_service_role())
        )
    );

DROP POLICY IF EXISTS "history_insert" ON public.n_jtd_history;
CREATE POLICY "history_insert" ON public.n_jtd_history
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.n_jtd j
            WHERE j.id = n_jtd_history.jtd_id
            AND (j.tenant_id = get_current_tenant_id() OR is_vani_user() OR is_service_role())
        )
    );

-- ============================================================
-- 9. RLS POLICIES: n_jtd_tenant_config
-- ============================================================

DROP POLICY IF EXISTS "tenant_config_select" ON public.n_jtd_tenant_config;
CREATE POLICY "tenant_config_select" ON public.n_jtd_tenant_config
    FOR SELECT
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    );

DROP POLICY IF EXISTS "tenant_config_insert" ON public.n_jtd_tenant_config;
CREATE POLICY "tenant_config_insert" ON public.n_jtd_tenant_config
    FOR INSERT
    TO authenticated
    WITH CHECK (
        tenant_id = get_current_tenant_id()
        OR is_service_role()
    );

DROP POLICY IF EXISTS "tenant_config_update" ON public.n_jtd_tenant_config;
CREATE POLICY "tenant_config_update" ON public.n_jtd_tenant_config
    FOR UPDATE
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_service_role()
    );

-- ============================================================
-- 10. RLS POLICIES: n_jtd_tenant_source_config
-- ============================================================

DROP POLICY IF EXISTS "tenant_source_config_select" ON public.n_jtd_tenant_source_config;
CREATE POLICY "tenant_source_config_select" ON public.n_jtd_tenant_source_config
    FOR SELECT
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    );

DROP POLICY IF EXISTS "tenant_source_config_insert" ON public.n_jtd_tenant_source_config;
CREATE POLICY "tenant_source_config_insert" ON public.n_jtd_tenant_source_config
    FOR INSERT
    TO authenticated
    WITH CHECK (
        tenant_id = get_current_tenant_id()
        OR is_service_role()
    );

DROP POLICY IF EXISTS "tenant_source_config_update" ON public.n_jtd_tenant_source_config;
CREATE POLICY "tenant_source_config_update" ON public.n_jtd_tenant_source_config
    FOR UPDATE
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_service_role()
    );

-- ============================================================
-- 11. RLS POLICIES: n_jtd_templates
-- ============================================================

-- System templates (tenant_id IS NULL) readable by all
-- Tenant templates only by that tenant
DROP POLICY IF EXISTS "templates_select" ON public.n_jtd_templates;
CREATE POLICY "templates_select" ON public.n_jtd_templates
    FOR SELECT
    TO authenticated
    USING (
        tenant_id IS NULL  -- System templates
        OR tenant_id = get_current_tenant_id()
        OR is_vani_user()
        OR is_service_role()
    );

DROP POLICY IF EXISTS "templates_insert" ON public.n_jtd_templates;
CREATE POLICY "templates_insert" ON public.n_jtd_templates
    FOR INSERT
    TO authenticated
    WITH CHECK (
        tenant_id = get_current_tenant_id()
        OR is_service_role()
    );

DROP POLICY IF EXISTS "templates_update" ON public.n_jtd_templates;
CREATE POLICY "templates_update" ON public.n_jtd_templates
    FOR UPDATE
    TO authenticated
    USING (
        tenant_id = get_current_tenant_id()
        OR is_service_role()
    );

-- ============================================================
-- 12. SEED TEST TENANT CONFIGS
-- ============================================================

-- Tenant 1: 70f8eb69-9ccf-4a0c-8177-cb6131934344
INSERT INTO public.n_jtd_tenant_config (
    tenant_id, vani_enabled, vani_auto_execute_types,
    channels_enabled, daily_limit, monthly_limit,
    timezone, is_live, is_active
) VALUES (
    '70f8eb69-9ccf-4a0c-8177-cb6131934344',
    false,
    ARRAY[]::TEXT[],
    '{"email": true, "sms": true, "whatsapp": true, "push": false, "inapp": true}'::JSONB,
    1000,
    30000,
    'Asia/Kolkata',
    false,  -- Test mode
    true
) ON CONFLICT (tenant_id, is_live) DO UPDATE SET
    channels_enabled = EXCLUDED.channels_enabled,
    updated_at = NOW();

-- Tenant 2: a58ca91a-7832-4b4c-b67c-a210032f26b8
INSERT INTO public.n_jtd_tenant_config (
    tenant_id, vani_enabled, vani_auto_execute_types,
    channels_enabled, daily_limit, monthly_limit,
    timezone, is_live, is_active
) VALUES (
    'a58ca91a-7832-4b4c-b67c-a210032f26b8',
    false,
    ARRAY[]::TEXT[],
    '{"email": true, "sms": true, "whatsapp": true, "push": false, "inapp": true}'::JSONB,
    1000,
    30000,
    'Asia/Kolkata',
    false,  -- Test mode
    true
) ON CONFLICT (tenant_id, is_live) DO UPDATE SET
    channels_enabled = EXCLUDED.channels_enabled,
    updated_at = NOW();

-- ============================================================
-- END OF MIGRATION
-- ============================================================
