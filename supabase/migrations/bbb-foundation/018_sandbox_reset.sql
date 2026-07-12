-- ============================================================================
-- 018_sandbox_reset.sql — Sandbox: clear a tenant's transactional data
-- ============================================================================
-- A tenant-scoped reset that wipes transactional records (contracts, events,
-- billing, invoices, appointments, tickets, form submissions, group-session
-- runtime) while KEEPING masterdata / config / sequences (catalog, templates,
-- categories, cadence settings, event-status config, tax, tenant profile,
-- users, and — critically — t_sequence_counters so numbering continues).
--
-- Two optional toggles: also clear Contacts, and/or Equipment/asset registries.
--
-- SECURITY DEFINER (tables enforce their own RLS elsewhere); callers pass the
-- tenant explicitly and the API scopes it to the authenticated tenant. Deletes
-- run child -> parent; the t_contract_events <-> t_invoices cycle is ON DELETE
-- SET NULL so either order is safe.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sandbox_preview_counts(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'contracts',            (SELECT count(*) FROM t_contracts                    WHERE tenant_id = p_tenant),
    'contract_events',      (SELECT count(*) FROM t_contract_events              WHERE tenant_id = p_tenant),
    'invoices',             (SELECT count(*) FROM t_invoices                     WHERE tenant_id = p_tenant)
                          + (SELECT count(*) FROM t_contract_invoice             WHERE tenant_id = p_tenant),
    'appointments',         (SELECT count(*) FROM t_appointments                 WHERE tenant_id = p_tenant),
    'service_tickets',      (SELECT count(*) FROM t_service_tickets              WHERE tenant_id = p_tenant),
    'form_submissions',     (SELECT count(*) FROM m_form_submissions             WHERE tenant_id = p_tenant),
    'session_attendance',   (SELECT count(*) FROM t_session_attendance           WHERE tenant_id = p_tenant),
    'payment_declarations', (SELECT count(*) FROM t_session_payment_declarations WHERE tenant_id = p_tenant),
    'contacts',             (SELECT count(*) FROM t_contacts                     WHERE tenant_id = p_tenant),
    'equipment',            (SELECT count(*) FROM t_equipment                    WHERE tenant_id = p_tenant)
  );
$$;

CREATE OR REPLACE FUNCTION public.sandbox_reset_transactions(
  p_tenant uuid,
  p_include_contacts  boolean DEFAULT false,
  p_include_equipment boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_counts jsonb;
BEGIN
  IF p_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'tenant_required');
  END IF;

  v_counts := public.sandbox_preview_counts(p_tenant);  -- snapshot before delete

  -- ── children / grandchildren first ──
  DELETE FROM m_form_attachments            WHERE tenant_id = p_tenant;
  DELETE FROM t_invoice_receipt_allocations WHERE tenant_id = p_tenant;
  DELETE FROM t_service_ticket_events       WHERE ticket_id IN (SELECT id FROM t_service_tickets WHERE tenant_id = p_tenant);
  DELETE FROM t_service_evidence            WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_event_audit        WHERE tenant_id = p_tenant;
  DELETE FROM t_appointments                WHERE tenant_id = p_tenant;
  DELETE FROM t_invoice_receipts            WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_payment_events     WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_payment_requests   WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_invoice            WHERE tenant_id = p_tenant;
  DELETE FROM m_form_submissions            WHERE tenant_id = p_tenant;
  DELETE FROM t_service_tickets             WHERE tenant_id = p_tenant;
  DELETE FROM t_invoices                    WHERE tenant_id = p_tenant;  -- SET NULL breaks the cycle
  DELETE FROM t_contract_events             WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_attachments        WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_assets             WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_blocks             WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_access             WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_vendors            WHERE tenant_id = p_tenant;
  DELETE FROM t_contract_history            WHERE tenant_id = p_tenant;
  DELETE FROM t_contracts                   WHERE tenant_id = p_tenant;

  -- group session runtime
  DELETE FROM t_session_payment_declarations WHERE tenant_id = p_tenant;
  DELETE FROM t_session_attendance           WHERE tenant_id = p_tenant;
  DELETE FROM t_group_session_tokens         WHERE tenant_id = p_tenant;

  -- optional: equipment / asset data
  IF p_include_equipment THEN
    DELETE FROM t_custom_checkpoint_values WHERE tenant_id = p_tenant;
    DELETE FROM t_custom_checkpoints       WHERE tenant_id = p_tenant;
    DELETE FROM t_custom_spare_parts       WHERE tenant_id = p_tenant;
    DELETE FROM t_custom_variants          WHERE tenant_id = p_tenant;
    DELETE FROM t_cycle_overrides          WHERE tenant_id = p_tenant;
    DELETE FROM t_equipment                WHERE tenant_id = p_tenant;
    DELETE FROM t_client_asset_registry    WHERE tenant_id = p_tenant;
    DELETE FROM t_tenant_asset_registry    WHERE tenant_id = p_tenant;
  END IF;

  -- optional: contacts (members / leads) + their channels & addresses
  IF p_include_contacts THEN
    DELETE FROM t_contact_channels  WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant);
    DELETE FROM t_contact_addresses WHERE contact_id IN (SELECT id FROM t_contacts WHERE tenant_id = p_tenant);
    DELETE FROM t_contacts          WHERE tenant_id = p_tenant;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deleted', v_counts,
    'included', jsonb_build_object('contacts', p_include_contacts, 'equipment', p_include_equipment));
END;
$$;
