-- ============================================================================
-- 019_sandbox_reset_env_scope.sql — scope Sandbox reset to ONE environment
-- ============================================================================
-- CRITICAL FIX for 018: records carry is_live (true = Live, false = Test/Sandbox)
-- within the same tables. The 018 RPCs ignored it and counted / would delete
-- BOTH environments. These versions take p_is_live and only ever touch the
-- caller's current environment. Child tables without their own is_live are
-- scoped through their is_live parent (contract / event / invoice / ticket).
--
-- Equipment toggle is limited to the asset registries that carry is_live;
-- KT-derived equipment/custom tables (no environment marker) are left alone.
-- ============================================================================

DROP FUNCTION IF EXISTS public.sandbox_preview_counts(uuid);
DROP FUNCTION IF EXISTS public.sandbox_reset_transactions(uuid, boolean, boolean);

CREATE OR REPLACE FUNCTION public.sandbox_preview_counts(p_tenant uuid, p_is_live boolean)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'is_live', p_is_live,
    'contracts',            (SELECT count(*) FROM t_contracts       WHERE tenant_id = p_tenant AND is_live = p_is_live),
    'contract_events',      (SELECT count(*) FROM t_contract_events WHERE tenant_id = p_tenant AND is_live = p_is_live),
    'invoices',             (SELECT count(*) FROM t_invoices        WHERE tenant_id = p_tenant AND is_live = p_is_live)
                          + (SELECT count(*) FROM t_contract_invoice WHERE contract_id IN
                               (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live)),
    'appointments',         (SELECT count(*) FROM t_appointments    WHERE tenant_id = p_tenant AND is_live = p_is_live),
    'service_tickets',      (SELECT count(*) FROM t_service_tickets WHERE tenant_id = p_tenant AND is_live = p_is_live),
    'form_submissions',     (SELECT count(*) FROM m_form_submissions WHERE contract_id IN
                               (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live)),
    'session_attendance',   (SELECT count(*) FROM t_session_attendance WHERE session_contract_id IN
                               (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live)),
    'payment_declarations', (SELECT count(*) FROM t_session_payment_declarations WHERE session_contract_id IN
                               (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live)),
    'contacts',             (SELECT count(*) FROM t_contacts        WHERE tenant_id = p_tenant AND is_live = p_is_live),
    'equipment',            (SELECT count(*) FROM t_tenant_asset_registry WHERE tenant_id = p_tenant AND is_live = p_is_live)
                          + (SELECT count(*) FROM t_client_asset_registry WHERE tenant_id = p_tenant AND is_live = p_is_live)
  );
$$;

CREATE OR REPLACE FUNCTION public.sandbox_reset_transactions(
  p_tenant uuid, p_is_live boolean,
  p_include_contacts boolean DEFAULT false, p_include_equipment boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_counts jsonb;
BEGIN
  IF p_tenant IS NULL OR p_is_live IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'tenant_and_environment_required');
  END IF;

  v_counts := public.sandbox_preview_counts(p_tenant, p_is_live);

  -- Environment-scoped id sets (parents that carry is_live). Children reference
  -- these while the parents still exist, so all child deletes come first.
  -- ── children keyed via parent (no own is_live) ──
  DELETE FROM m_form_attachments WHERE form_submission_id IN
    (SELECT id FROM m_form_submissions WHERE contract_id IN
      (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live));
  DELETE FROM m_form_submissions WHERE contract_id IN
    (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_invoice_receipt_allocations WHERE tenant_id = p_tenant AND is_live = p_is_live;
  DELETE FROM t_invoice_receipts WHERE contract_id IN
    (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_service_ticket_events WHERE ticket_id IN
    (SELECT id FROM t_service_tickets WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_service_evidence WHERE tenant_id = p_tenant AND is_live = p_is_live;
  DELETE FROM t_contract_event_audit WHERE event_id IN
    (SELECT id FROM t_contract_events WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_appointments WHERE tenant_id = p_tenant AND is_live = p_is_live;
  DELETE FROM t_contract_payment_events WHERE invoice_id IN
    (SELECT id FROM t_invoices WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_contract_payment_requests WHERE tenant_id = p_tenant AND is_live = p_is_live;
  DELETE FROM t_contract_invoice WHERE contract_id IN
    (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);

  -- ── mid-level (own is_live) ──
  DELETE FROM t_service_tickets WHERE tenant_id = p_tenant AND is_live = p_is_live;
  DELETE FROM t_invoices        WHERE tenant_id = p_tenant AND is_live = p_is_live;  -- SET NULL breaks cycle
  DELETE FROM t_contract_events WHERE tenant_id = p_tenant AND is_live = p_is_live;
  DELETE FROM t_contract_assets WHERE tenant_id = p_tenant AND is_live = p_is_live;

  -- ── remaining contract children (keyed by contract_id, contracts still exist) ──
  DELETE FROM t_contract_attachments WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_contract_blocks      WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_contract_access      WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_contract_vendors     WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_contract_history     WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_group_session_tokens WHERE contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_session_payment_declarations WHERE session_contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);
  DELETE FROM t_session_attendance   WHERE session_contract_id IN (SELECT id FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live);

  -- ── parents ──
  DELETE FROM t_contracts WHERE tenant_id = p_tenant AND is_live = p_is_live;

  -- optional: equipment / asset registries (only the ones carrying is_live)
  IF p_include_equipment THEN
    DELETE FROM t_client_asset_registry WHERE tenant_id = p_tenant AND is_live = p_is_live;
    DELETE FROM t_tenant_asset_registry WHERE tenant_id = p_tenant AND is_live = p_is_live;
  END IF;

  -- optional: contacts (own is_live) + their channels & addresses
  IF p_include_contacts THEN
    DELETE FROM t_contact_channels  WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant AND is_live = p_is_live);
    DELETE FROM t_contact_addresses WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant AND is_live = p_is_live);
    DELETE FROM t_contacts          WHERE tenant_id = p_tenant AND is_live = p_is_live;
  END IF;

  RETURN jsonb_build_object('ok', true, 'is_live', p_is_live, 'deleted', v_counts,
    'included', jsonb_build_object('contacts', p_include_contacts, 'equipment', p_include_equipment));
END;
$$;
