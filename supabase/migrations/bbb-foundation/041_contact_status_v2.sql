-- Contact status change — replaces the guardrail-free bare
-- `UPDATE t_contacts SET status = ...` currently issued from edge-function
-- application code (contractnest-edge/_shared/contacts/contactService.ts
-- updateContactStatus()). That path has no RPC, no row lock, silently
-- blocks archived -> active forever, has zero dependency checks (a contact
-- with active contracts / unpaid invoices could be archived with no
-- warning), and its only audit trail is a best-effort t_audit_logs write
-- wrapped in .catch(() => {}) — a failure there is invisible.
--
-- Mirrors two already-proven patterns in this codebase:
--   - update_contract_status: row-locked, structured result.
--   - delete_service_catalog_item: dependency-check-before-archive,
--     refuses with code DEPENDENCY_EXISTS if live obligations exist.
--
-- Design decisions (per owner, this session):
--   - archived -> active IS allowed (reactivation is user-facing, not
--     admin-only or permanently blocked as the old code enforced).
--   - Archiving IS blocked while the contact has active contracts
--     (status not in cancelled/expired/completed) or unpaid invoices
--     (status not in paid/cancelled/bad_debt/adjustment) — either as the
--     contract's buyer_id or buyer_contact_person_id.
--   - Inactive has no such block — it's a soft pause, not terminal.
--   - Audit write happens INSIDE this transaction (not a fire-and-forget
--     edge-function side call), so a failure there fails the whole call
--     instead of being silently swallowed.

CREATE OR REPLACE FUNCTION public.update_contact_status_v2(
  p_contact_id uuid,
  p_tenant_id uuid,
  p_new_status text,
  p_is_live boolean DEFAULT true,
  p_performed_by uuid DEFAULT NULL::uuid,
  p_performed_by_name text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact RECORD;
  v_active_contracts integer := 0;
  v_unpaid_invoices integer := 0;
BEGIN
  IF p_contact_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'contact_id and tenant_id are required', 'code', 'VALIDATION_ERROR');
  END IF;
  IF p_new_status NOT IN ('active', 'inactive', 'archived') THEN
    RETURN jsonb_build_object('success', false, 'error', 'status must be active, inactive or archived', 'code', 'VALIDATION_ERROR');
  END IF;

  SELECT id, tenant_id, status INTO v_contact
  FROM t_contacts
  WHERE id = p_contact_id AND tenant_id = p_tenant_id AND is_live = p_is_live
  FOR UPDATE NOWAIT;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contact not found or access denied', 'code', 'RECORD_NOT_FOUND');
  END IF;

  IF v_contact.status = p_new_status THEN
    RETURN jsonb_build_object('success', true, 'message', 'Status already ' || p_new_status,
      'data', jsonb_build_object('id', p_contact_id, 'status', p_new_status));
  END IF;

  -- Dependency guard — only when archiving
  IF p_new_status = 'archived' THEN
    SELECT COUNT(*) INTO v_active_contracts
    FROM t_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND (c.buyer_id = p_contact_id OR c.buyer_contact_person_id = p_contact_id)
      AND c.status NOT IN ('cancelled', 'expired', 'completed');

    SELECT COUNT(*) INTO v_unpaid_invoices
    FROM t_invoices i
    JOIN t_contracts c ON c.id = i.contract_id
    WHERE i.tenant_id = p_tenant_id
      AND i.is_live = p_is_live
      AND (c.buyer_id = p_contact_id OR c.buyer_contact_person_id = p_contact_id)
      AND i.status NOT IN ('paid', 'cancelled', 'bad_debt', 'adjustment');

    IF v_active_contracts > 0 OR v_unpaid_invoices > 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Cannot archive: ' || v_active_contracts || ' active contract(s), ' || v_unpaid_invoices || ' unpaid invoice(s)',
        'code', 'DEPENDENCY_EXISTS',
        'dependencies', jsonb_build_object('active_contracts', v_active_contracts, 'unpaid_invoices', v_unpaid_invoices)
      );
    END IF;
  END IF;

  UPDATE t_contacts
  SET status = p_new_status, updated_at = now(), updated_by = p_performed_by
  WHERE id = p_contact_id;

  INSERT INTO t_audit_logs (id, tenant_id, user_id, action, resource, resource_id, metadata, success, severity, created_at)
  VALUES (
    gen_random_uuid(), p_tenant_id, p_performed_by, 'contact.status_changed', 'contact', p_contact_id::text,
    jsonb_build_object('from_status', v_contact.status, 'to_status', p_new_status, 'performed_by_name', p_performed_by_name),
    true, 'info', now()
  );

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'id', p_contact_id, 'previous_status', v_contact.status, 'status', p_new_status));

EXCEPTION
  WHEN lock_not_available THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contact is being updated by another user. Please try again.', 'code', 'CONCURRENT_UPDATE');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'OPERATION_ERROR');
END;
$function$;
