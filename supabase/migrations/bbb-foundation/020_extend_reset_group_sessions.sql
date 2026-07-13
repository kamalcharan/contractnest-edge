-- ============================================================================
-- 020_extend_reset_group_sessions.sql
-- ============================================================================
-- The existing admin_reset_test_data / admin_reset_all_data miss several
-- transactional tables — including everything from the Group Session work
-- (check-in) and forms. This adds a helper that cleans those, and calls it
-- from the top of both functions (before contracts are deleted, so its
-- contract-scoped subqueries still resolve). p_is_live: false = Test only,
-- NULL = all environments.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reset_tenant_session_and_forms(
  p_tenant_id uuid, p_is_live boolean DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_contracts uuid[];
BEGIN
  SELECT array_agg(id) INTO v_contracts
  FROM t_contracts
  WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);

  IF v_contracts IS NULL THEN v_contracts := ARRAY[]::uuid[]; END IF;

  -- forms
  BEGIN DELETE FROM m_form_attachments WHERE form_submission_id IN
    (SELECT id FROM m_form_submissions WHERE contract_id = ANY(v_contracts));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM m_form_submissions WHERE contract_id = ANY(v_contracts);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- invoice / receipt allocations (own is_live)
  BEGIN DELETE FROM t_invoice_receipt_allocations
    WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- service tickets tree
  BEGIN DELETE FROM t_service_ticket_events WHERE ticket_id IN
    (SELECT id FROM t_service_tickets WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_service_evidence
    WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_service_tickets
    WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- payments (keyed via invoices / own is_live)
  BEGIN DELETE FROM t_contract_payment_events WHERE invoice_id IN
    (SELECT id FROM t_invoices WHERE contract_id = ANY(v_contracts));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_payment_requests
    WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- appointments (own is_live)
  BEGIN DELETE FROM t_appointments
    WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- remaining contract children the base reset misses
  BEGIN DELETE FROM t_contract_invoice WHERE contract_id = ANY(v_contracts);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_attachments WHERE contract_id = ANY(v_contracts);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_assets
    WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- group session runtime (check-in)
  BEGIN DELETE FROM t_group_session_tokens WHERE contract_id = ANY(v_contracts);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_session_payment_declarations WHERE session_contract_id = ANY(v_contracts);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_session_attendance WHERE session_contract_id = ANY(v_contracts);
  EXCEPTION WHEN OTHERS THEN NULL; END;
END;
$$;

-- ── admin_reset_test_data: add the helper call at the top (Test scope) ──
CREATE OR REPLACE FUNCTION public.admin_reset_test_data(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_deleted_counts jsonb := '{}'::jsonb;
  v_count integer;
  v_total integer := 0;
  v_contract_ids UUID[];
BEGIN
  -- Extended cleanup: sessions, forms, tickets, extra contract children (Test)
  BEGIN PERFORM public.reset_tenant_session_and_forms(p_tenant_id, false);
  EXCEPTION WHEN OTHERS THEN NULL; END;

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
$function$;

-- ── admin_reset_all_data: add the helper call at the top (all environments) ──
CREATE OR REPLACE FUNCTION public.admin_reset_all_data(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_deleted_counts jsonb := '{}'::jsonb;
  v_count integer;
  v_total integer := 0;
BEGIN
  -- Extended cleanup: sessions, forms, tickets, extra contract children (all envs)
  BEGIN PERFORM public.reset_tenant_session_and_forms(p_tenant_id, NULL);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Group tables (leaf first)
  BEGIN DELETE FROM t_group_activity_logs WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('group_activity_logs', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_group_memberships WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('group_memberships', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_audit_log WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('audit_log', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_audit_logs WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('audit_logs', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_service_evidence WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('service_evidence', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_service_tickets WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('service_tickets', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_contract_assets WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('contract_assets', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_client_asset_registry WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('client_asset_registry', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

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

  BEGIN DELETE FROM t_catalog_service_resources WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('catalog_service_resources', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_catalog_resource_pricing WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('catalog_resource_pricing', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_catalog_items WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('catalog_items', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_catalog_categories WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_tenant_industry_segments WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('tenant_industry_segments', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_tenant_served_industries WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('tenant_served_industries', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_catalog_industries WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('catalog_industries', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_tenant_files WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
    v_deleted_counts := v_deleted_counts || jsonb_build_object('files', v_count);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_sequence_counters WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN DELETE FROM t_idempotency_keys WHERE tenant_id = p_tenant_id;
    GET DIAGNOSTICS v_count = ROW_COUNT; v_total := v_total + v_count;
  EXCEPTION WHEN OTHERS THEN NULL; END;

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
$function$;
