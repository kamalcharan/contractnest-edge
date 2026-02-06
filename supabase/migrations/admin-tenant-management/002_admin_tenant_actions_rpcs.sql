-- ============================================================================
-- Admin Tenant Management - Missing RPCs + Updated Tenant List
-- Migration: admin-tenant-management/002_admin_tenant_actions_rpcs.sql
--
-- Creates 4 missing RPCs that edge functions call but never existed:
--   1. get_tenant_data_summary
--   2. admin_reset_test_data
--   3. admin_reset_all_data
--   4. admin_close_tenant_account
--
-- Updates:
--   5. get_admin_tenant_list - adds owner info, is_test, search by owner email
--
-- Also adds 'closed' to t_tenants status constraint if missing
-- ============================================================================

-- ============================================================================
-- STEP 0: Ensure t_tenants supports 'closed' status
-- ============================================================================
DO $$
BEGIN
  -- Drop old constraint and add new one with 'closed'
  ALTER TABLE t_tenants DROP CONSTRAINT IF EXISTS t_tenants_status_check;
  ALTER TABLE t_tenants ADD CONSTRAINT t_tenants_status_check
    CHECK (status IN ('active', 'inactive', 'suspended', 'trial', 'closed'));
END $$;

-- ============================================================================
-- 1. GET TENANT DATA SUMMARY
-- Returns row counts per table for a specific tenant (for delete preview)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_tenant_data_summary(p_tenant_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant RECORD;
  v_categories jsonb := '[]'::jsonb;
  v_total_records integer := 0;
  v_count integer;
  v_items jsonb;
BEGIN
  -- Get tenant info
  SELECT t.id, t.name, t.workspace_code
  INTO v_tenant
  FROM t_tenants t WHERE t.id = p_tenant_id;

  IF v_tenant.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenant not found');
  END IF;

  -- Category: Contacts & Relationships
  v_items := '[]'::jsonb;

  SELECT COUNT(*) INTO v_count FROM t_contacts WHERE tenant_id = p_tenant_id AND is_live = true;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Contacts (Live)', 'count', v_count, 'table', 't_contacts'));
  v_total_records := v_total_records + v_count;

  SELECT COUNT(*) INTO v_count FROM t_contacts WHERE tenant_id = p_tenant_id AND is_live = false;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Contacts (Test)', 'count', v_count, 'table', 't_contacts'));
  v_total_records := v_total_records + v_count;

  SELECT COUNT(*) INTO v_count FROM t_contact_addresses WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant_id);
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Addresses', 'count', v_count, 'table', 't_contact_addresses'));
  v_total_records := v_total_records + v_count;

  SELECT COUNT(*) INTO v_count FROM t_contact_channels WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant_id);
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Channels', 'count', v_count, 'table', 't_contact_channels'));
  v_total_records := v_total_records + v_count;

  v_categories := v_categories || jsonb_build_array(jsonb_build_object(
    'id', 'contacts', 'label', 'Contacts & Relationships', 'icon', 'Users', 'color', '#3B82F6',
    'description', 'Business contacts, addresses, and communication channels',
    'totalCount', (SELECT SUM((item->>'count')::int) FROM jsonb_array_elements(v_items) item),
    'items', v_items
  ));

  -- Category: Users & Team
  v_items := '[]'::jsonb;

  SELECT COUNT(*) INTO v_count FROM t_user_tenants WHERE tenant_id = p_tenant_id AND status = 'active';
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Team Members', 'count', v_count, 'table', 't_user_tenants'));
  v_total_records := v_total_records + v_count;

  SELECT COUNT(*) INTO v_count FROM t_user_invitations WHERE tenant_id = p_tenant_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Invitations', 'count', v_count, 'table', 't_user_invitations'));
  v_total_records := v_total_records + v_count;

  v_categories := v_categories || jsonb_build_array(jsonb_build_object(
    'id', 'users', 'label', 'Users & Team', 'icon', 'UserPlus', 'color', '#8B5CF6',
    'description', 'Team members, roles, and pending invitations',
    'totalCount', (SELECT SUM((item->>'count')::int) FROM jsonb_array_elements(v_items) item),
    'items', v_items
  ));

  -- Category: Contracts & Documents
  v_items := '[]'::jsonb;

  v_count := 0;
  BEGIN SELECT COUNT(*) INTO v_count FROM t_contracts WHERE tenant_id = p_tenant_id AND is_live = true;
  EXCEPTION WHEN OTHERS THEN v_count := 0; END;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Contracts (Live)', 'count', v_count, 'table', 't_contracts'));
  v_total_records := v_total_records + v_count;

  v_count := 0;
  BEGIN SELECT COUNT(*) INTO v_count FROM t_contracts WHERE tenant_id = p_tenant_id AND is_live = false;
  EXCEPTION WHEN OTHERS THEN v_count := 0; END;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Contracts (Test)', 'count', v_count, 'table', 't_contracts'));
  v_total_records := v_total_records + v_count;

  v_count := 0;
  BEGIN SELECT COUNT(*) INTO v_count FROM t_invoices WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN v_count := 0; END;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Invoices', 'count', v_count, 'table', 't_invoices'));
  v_total_records := v_total_records + v_count;

  v_count := 0;
  BEGIN SELECT COUNT(*) INTO v_count FROM t_tenant_files WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN v_count := 0; END;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Files', 'count', v_count, 'table', 't_tenant_files'));
  v_total_records := v_total_records + v_count;

  v_categories := v_categories || jsonb_build_array(jsonb_build_object(
    'id', 'contracts', 'label', 'Contracts & Documents', 'icon', 'FileText', 'color', '#10B981',
    'description', 'Service contracts, invoices, and uploaded files',
    'totalCount', (SELECT SUM((item->>'count')::int) FROM jsonb_array_elements(v_items) item),
    'items', v_items
  ));

  -- Category: Catalog & Services
  v_items := '[]'::jsonb;

  SELECT COUNT(*) INTO v_count FROM t_catalog_items WHERE tenant_id = p_tenant_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Catalog Items', 'count', v_count, 'table', 't_catalog_items'));
  v_total_records := v_total_records + v_count;

  SELECT COUNT(*) INTO v_count FROM t_catalog_categories WHERE tenant_id = p_tenant_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Categories', 'count', v_count, 'table', 't_catalog_categories'));
  v_total_records := v_total_records + v_count;

  v_categories := v_categories || jsonb_build_array(jsonb_build_object(
    'id', 'catalog', 'label', 'Catalog & Services', 'icon', 'Package', 'color', '#F59E0B',
    'description', 'Products, services, and categories',
    'totalCount', (SELECT SUM((item->>'count')::int) FROM jsonb_array_elements(v_items) item),
    'items', v_items
  ));

  -- Category: Settings & Configuration
  v_items := '[]'::jsonb;

  SELECT COUNT(*) INTO v_count FROM t_tenant_profiles WHERE tenant_id = p_tenant_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Business Profile', 'count', v_count, 'table', 't_tenant_profiles'));
  v_total_records := v_total_records + v_count;

  SELECT COUNT(*) INTO v_count FROM t_tax_rates WHERE tenant_id = p_tenant_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Tax Rates', 'count', v_count, 'table', 't_tax_rates'));
  v_total_records := v_total_records + v_count;

  v_categories := v_categories || jsonb_build_array(jsonb_build_object(
    'id', 'settings', 'label', 'Settings & Configuration', 'icon', 'Settings', 'color', '#6366F1',
    'description', 'Business settings and preferences',
    'totalCount', (SELECT SUM((item->>'count')::int) FROM jsonb_array_elements(v_items) item),
    'items', v_items
  ));

  -- Category: Subscription & Billing
  v_items := '[]'::jsonb;

  SELECT COUNT(*) INTO v_count FROM t_bm_tenant_subscription WHERE tenant_id = p_tenant_id;
  v_items := v_items || jsonb_build_array(jsonb_build_object('label', 'Subscription', 'count', v_count, 'table', 't_bm_tenant_subscription'));
  v_total_records := v_total_records + v_count;

  v_categories := v_categories || jsonb_build_array(jsonb_build_object(
    'id', 'subscription', 'label', 'Subscription & Billing', 'icon', 'CreditCard', 'color', '#EC4899',
    'description', 'Subscription plan and billing records',
    'totalCount', (SELECT SUM((item->>'count')::int) FROM jsonb_array_elements(v_items) item),
    'items', v_items
  ));

  RETURN jsonb_build_object(
    'tenant_id', v_tenant.id,
    'tenant_name', v_tenant.name,
    'workspace_code', v_tenant.workspace_code,
    'categories', v_categories,
    'totalRecords', v_total_records,
    'canDelete', true,
    'blockingReasons', '[]'::jsonb
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_tenant_data_summary(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_tenant_data_summary(UUID) TO service_role;

-- ============================================================================
-- 2. ADMIN RESET TEST DATA
-- Deletes all records where is_live = false for a specific tenant
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_reset_test_data(p_tenant_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_deleted_counts jsonb := '{}'::jsonb;
  v_count integer;
  v_total integer := 0;
  v_contract_ids UUID[];
BEGIN
  -- Get test contract IDs for child table cleanup
  BEGIN
    SELECT ARRAY_AGG(id) INTO v_contract_ids
    FROM t_contracts WHERE tenant_id = p_tenant_id AND is_live = false;
  EXCEPTION WHEN OTHERS THEN v_contract_ids := NULL; END;

  -- Delete contract child records (if any test contracts exist)
  IF v_contract_ids IS NOT NULL AND array_length(v_contract_ids, 1) > 0 THEN
    BEGIN DELETE FROM t_contract_event_audit WHERE tenant_id = p_tenant_id AND event_id IN (SELECT id FROM t_contract_events WHERE contract_id = ANY(v_contract_ids));
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_contract_events WHERE contract_id = ANY(v_contract_ids);
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
      v_deleted_counts := v_deleted_counts || jsonb_build_object('contract_events', v_count);
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_invoice_receipts WHERE tenant_id = p_tenant_id AND invoice_id IN (SELECT id FROM t_invoices WHERE contract_id = ANY(v_contract_ids));
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_invoices WHERE contract_id = ANY(v_contract_ids);
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
      v_deleted_counts := v_deleted_counts || jsonb_build_object('invoices', v_count);
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_contract_access WHERE contract_id = ANY(v_contract_ids);
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_contract_vendors WHERE contract_id = ANY(v_contract_ids);
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_contract_blocks WHERE contract_id = ANY(v_contract_ids);
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN DELETE FROM t_contract_history WHERE contract_id = ANY(v_contract_ids);
      GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  -- Delete test contracts
  BEGIN DELETE FROM t_contracts WHERE tenant_id = p_tenant_id AND is_live = false;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('contracts', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Delete test contacts and their children
  BEGIN DELETE FROM t_contact_channels WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant_id AND is_live = false);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contact_addresses WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant_id AND is_live = false);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contacts WHERE tenant_id = p_tenant_id AND is_live = false;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('contacts', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_counts', v_deleted_counts,
    'total_deleted', v_total,
    'tenant_id', p_tenant_id,
    'scope', 'test_data_only'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'error_code', SQLSTATE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_reset_test_data(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_reset_test_data(UUID) TO service_role;

-- ============================================================================
-- 3. ADMIN RESET ALL DATA
-- Deletes ALL data for a tenant but keeps the account open
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_reset_all_data(p_tenant_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_deleted_counts jsonb := '{}'::jsonb;
  v_count integer;
  v_total integer := 0;
BEGIN
  -- Contract child tables first (FK order)
  -- Each wrapped in sub-block to skip if table doesn't exist
  BEGIN DELETE FROM t_contract_event_audit WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_payment_events WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_payment_requests WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_events WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('contract_events', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_invoice_receipts WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_invoices WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('invoices', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_access WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_vendors WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_blocks WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_history WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contracts WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('contracts', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Contact child tables
  BEGIN DELETE FROM t_contact_channels WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contact_addresses WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contacts WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('contacts', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Catalog
  BEGIN DELETE FROM t_catalog_items WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('catalog_items', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_catalog_categories WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Files
  BEGIN DELETE FROM t_tenant_files WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('files', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Sequences
  BEGIN DELETE FROM t_sequence_counters WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Idempotency keys
  BEGIN DELETE FROM t_idempotency_keys WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- JTD records
  BEGIN DELETE FROM n_jtd_status_history WHERE jtd_id IN (SELECT id FROM n_jtd WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM n_jtd_history WHERE jtd_id IN (SELECT id FROM n_jtd WHERE tenant_id = p_tenant_id);
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM n_jtd WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('jtd_records', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM n_jtd_tenant_source_config WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM n_jtd_tenant_config WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_counts', v_deleted_counts,
    'total_deleted', v_total,
    'tenant_id', p_tenant_id,
    'scope', 'all_data'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'error_code', SQLSTATE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_reset_all_data(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_reset_all_data(UUID) TO service_role;

-- ============================================================================
-- 4. ADMIN CLOSE TENANT ACCOUNT
-- Deletes ALL data + marks tenant as 'closed' + deactivates user relationships
-- Does NOT delete from auth.users (must be done manually from Supabase dashboard)
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_close_tenant_account(p_tenant_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_user_ids UUID[];
  v_orphan_user_ids UUID[];
  v_cleanup_errors text[] := '{}';
  v_err text;
BEGIN
  -- ============================================================
  -- STEP 1 (CRITICAL): Mark tenant as closed FIRST
  -- This ensures the status updates even if cleanup fails
  -- ============================================================
  UPDATE t_tenants
  SET status = 'closed', updated_at = NOW()
  WHERE id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenant not found: ' || p_tenant_id);
  END IF;

  -- ============================================================
  -- STEP 2: Collect user_ids before deleting relationships
  -- ============================================================
  BEGIN
    SELECT ARRAY_AGG(user_id) INTO v_tenant_user_ids
    FROM t_user_tenants WHERE tenant_id = p_tenant_id AND user_id IS NOT NULL;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    v_cleanup_errors := array_append(v_cleanup_errors, 'collect_users: ' || v_err);
  END;

  -- ============================================================
  -- STEP 3: Best-effort data cleanup (each step independent)
  -- ============================================================

  -- Delete contract-related data
  BEGIN PERFORM admin_reset_all_data(p_tenant_id);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    v_cleanup_errors := array_append(v_cleanup_errors, 'reset_all_data: ' || v_err);
  END;

  -- Delete config/settings
  BEGIN DELETE FROM t_tax_rates WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_tax_info WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_tenant_profiles WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_tenant_integrations WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_tenant_onboarding WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_onboarding_step_status WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_bm_tenant_subscription WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_user_invitations WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Delete user-tenant relationships
  BEGIN DELETE FROM t_user_tenants WHERE tenant_id = p_tenant_id;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    v_cleanup_errors := array_append(v_cleanup_errors, 'delete_user_tenants: ' || v_err);
  END;

  -- ============================================================
  -- STEP 4: Find orphan users and clean FK refs
  -- ============================================================
  IF v_tenant_user_ids IS NOT NULL AND array_length(v_tenant_user_ids, 1) > 0 THEN
    BEGIN
      SELECT ARRAY_AGG(uid) INTO v_orphan_user_ids
      FROM (
        SELECT unnest(v_tenant_user_ids) AS uid
        EXCEPT
        SELECT DISTINCT user_id FROM t_user_tenants WHERE user_id = ANY(v_tenant_user_ids)
      ) orphans;
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  IF v_orphan_user_ids IS NOT NULL AND array_length(v_orphan_user_ids, 1) > 0 THEN
    BEGIN UPDATE t_audit_logs SET user_id = NULL WHERE user_id = ANY(v_orphan_user_ids);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN UPDATE t_contacts SET auth_user_id = NULL WHERE auth_user_id = ANY(v_orphan_user_ids);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN DELETE FROM t_user_auth_methods WHERE user_id = ANY(v_orphan_user_ids);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN DELETE FROM t_user_profiles WHERE user_id = ANY(v_orphan_user_ids);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  -- ============================================================
  -- ALWAYS return success (status is already 'closed')
  -- ============================================================
  RETURN jsonb_build_object(
    'success', true,
    'tenant_id', p_tenant_id,
    'tenant_status', 'closed',
    'scope', 'close_account',
    'orphan_user_ids', COALESCE(to_jsonb(v_orphan_user_ids), '[]'::jsonb),
    'cleanup_errors', to_jsonb(v_cleanup_errors),
    'note', 'Auth users NOT auto-deleted. Orphan user_ids returned - delete from Supabase Dashboard > Authentication.'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'error_code', SQLSTATE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_close_tenant_account(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_close_tenant_account(UUID) TO service_role;

-- ============================================================================
-- 5. UPDATED GET_ADMIN_TENANT_LIST
-- Added: owner info (email, name), is_test flag, search by owner email
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_tenant_list(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 20,
  p_status text DEFAULT NULL,
  p_subscription_status text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_sort_by text DEFAULT 'created_at',
  p_sort_direction text DEFAULT 'desc',
  p_is_test text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_offset integer;
  v_total integer;
  v_tenants jsonb;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  -- Count total matching tenants (with owner join for email search)
  SELECT COUNT(*) INTO v_total
  FROM t_tenants t
  LEFT JOIN t_user_profiles up_owner ON up_owner.user_id = t.created_by
  LEFT JOIN LATERAL (
    SELECT * FROM t_bm_tenant_subscription sub
    WHERE sub.tenant_id = t.id
    ORDER BY sub.created_at DESC
    LIMIT 1
  ) ts ON true
  WHERE (p_status IS NULL OR t.status = p_status)
    AND (p_subscription_status IS NULL OR ts.status = p_subscription_status)
    AND (p_is_test IS NULL
      OR (p_is_test = 'true' AND COALESCE(t.is_test, false) = true)
      OR (p_is_test = 'false' AND COALESCE(t.is_test, false) = false)
    )
    AND (p_search IS NULL OR (
      t.name ILIKE '%' || p_search || '%'
      OR t.workspace_code ILIKE '%' || p_search || '%'
      OR up_owner.email ILIKE '%' || p_search || '%'
      OR up_owner.first_name ILIKE '%' || p_search || '%'
      OR up_owner.last_name ILIKE '%' || p_search || '%'
    ));

  -- Get tenant list with owner info
  SELECT COALESCE(jsonb_agg(tenant_row), '[]'::jsonb) INTO v_tenants
  FROM (
    SELECT jsonb_build_object(
      'id', t.id,
      'name', t.name,
      'workspace_code', t.workspace_code,
      'status', t.status,
      'is_admin', COALESCE(t.is_admin, false),
      'is_test', COALESCE(t.is_test, false),
      'created_at', t.created_at,
      'owner', CASE
        WHEN up_owner.id IS NOT NULL THEN jsonb_build_object(
          'user_id', up_owner.user_id,
          'email', up_owner.email,
          'first_name', up_owner.first_name,
          'last_name', up_owner.last_name,
          'name', TRIM(COALESCE(up_owner.first_name, '') || ' ' || COALESCE(up_owner.last_name, ''))
        )
        ELSE NULL
      END,
      'profile', CASE
        WHEN tp.id IS NOT NULL THEN jsonb_build_object(
          'business_name', tp.business_name,
          'business_email', tp.business_email,
          'logo_url', tp.logo_url,
          'industry_id', tp.industry_id,
          'industry_name', tp.industry_id,
          'city', tp.city
        )
        ELSE NULL
      END,
      'subscription', CASE
        WHEN ts.subscription_id IS NOT NULL THEN jsonb_build_object(
          'status', ts.status,
          'product_code', ts.product_code,
          'billing_cycle', ts.billing_cycle,
          'trial_end_date', ts.trial_ends,
          'next_billing_date', ts.next_billing_date,
          'days_until_expiry', CASE
            WHEN ts.trial_ends IS NOT NULL AND ts.trial_ends > NOW()
            THEN EXTRACT(DAY FROM ts.trial_ends - NOW())::integer
            ELSE NULL
          END
        )
        ELSE NULL
      END,
      'stats', jsonb_build_object(
        'total_users', COALESCE((
          SELECT COUNT(*) FROM t_user_tenants ut
          WHERE ut.tenant_id = t.id AND ut.status = 'active'
        ), 0),
        'total_contacts', COALESCE((
          SELECT COUNT(*) FROM t_contacts c
          WHERE c.tenant_id = t.id AND c.is_live = true
        ), 0),
        'total_contracts', COALESCE((
          SELECT COUNT(*) FROM t_contracts ct
          WHERE ct.tenant_id = t.id AND ct.is_live = true AND ct.is_active = true
        ), 0),
        'storage_used_mb', COALESCE(t.storage_consumed, 0),
        'storage_limit_mb', COALESCE(t.storage_quota, 40),
        'tenant_type', 'mixed'
      )
    ) as tenant_row
    FROM t_tenants t
    LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id
    LEFT JOIN t_user_profiles up_owner ON up_owner.user_id = t.created_by
    LEFT JOIN LATERAL (
      SELECT * FROM t_bm_tenant_subscription sub
      WHERE sub.tenant_id = t.id
      ORDER BY sub.created_at DESC
      LIMIT 1
    ) ts ON true
    WHERE (p_status IS NULL OR t.status = p_status)
      AND (p_subscription_status IS NULL OR ts.status = p_subscription_status)
      AND (p_is_test IS NULL
        OR (p_is_test = 'true' AND COALESCE(t.is_test, false) = true)
        OR (p_is_test = 'false' AND COALESCE(t.is_test, false) = false)
      )
      AND (p_search IS NULL OR (
        t.name ILIKE '%' || p_search || '%'
        OR t.workspace_code ILIKE '%' || p_search || '%'
        OR up_owner.email ILIKE '%' || p_search || '%'
        OR up_owner.first_name ILIKE '%' || p_search || '%'
        OR up_owner.last_name ILIKE '%' || p_search || '%'
      ))
    ORDER BY
      CASE WHEN p_sort_by = 'name' AND p_sort_direction = 'asc' THEN t.name END ASC,
      CASE WHEN p_sort_by = 'name' AND p_sort_direction = 'desc' THEN t.name END DESC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_direction = 'asc' THEN t.created_at END ASC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_direction = 'desc' THEN t.created_at END DESC,
      CASE WHEN p_sort_by = 'status' AND p_sort_direction = 'asc' THEN t.status END ASC,
      CASE WHEN p_sort_by = 'status' AND p_sort_direction = 'desc' THEN t.status END DESC,
      t.created_at DESC
    LIMIT p_limit
    OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'tenants', v_tenants,
    'pagination', jsonb_build_object(
      'current_page', p_page,
      'total_pages', CEIL(v_total::float / p_limit)::integer,
      'total_records', v_total,
      'limit', p_limit,
      'has_next', (v_offset + p_limit) < v_total,
      'has_prev', p_page > 1
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_admin_tenant_list(integer, integer, text, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION get_admin_tenant_list(integer, integer, text, text, text, text, text, text) TO service_role;
