-- reset_tenant_session_and_forms: fix two dead-column deletes that made
-- "reset test data" silently fail to clear group-session attendance.
--
-- t_session_attendance.session_contract_id and
-- t_session_payment_declarations.session_contract_id are NEVER populated by
-- the check-in flow (confirmed: 0 non-null rows across the entire table for
-- either column, all tenants) — attendance is actually linked via
-- member_contact_id + schedule_occurrence_id/source_block_id. The reset
-- function's `DELETE ... WHERE session_contract_id = ANY(v_contracts)` was
-- therefore always a silent no-op (further masked by its
-- `EXCEPTION WHEN OTHERS THEN NULL` wrapper), so old test contacts/contracts
-- got deleted but their attendance rows survived, showing up as inflated/
-- impossible present-counts (e.g. "4/1 present") against the next contract
-- created for the same recurring block.
--
-- Fix: scope both deletes by tenant_id (both tables have it directly) and,
-- for the is_live-scoped case, by joining through the linked occurrence's
-- own is_live flag (t_group_session_schedule.is_live /
-- t_contract_events.is_live) rather than a contract id that was never
-- recorded. Deliberately NOT joined through member_contact_id: that would
-- fail to clean up exactly the already-orphaned rows this migration exists
-- to fix, since their contact no longer exists at all.

CREATE OR REPLACE FUNCTION public.reset_tenant_session_and_forms(p_tenant_id uuid, p_is_live boolean DEFAULT NULL::boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_contracts uuid[];
BEGIN
  SELECT array_agg(id) INTO v_contracts FROM t_contracts
   WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live);
  IF v_contracts IS NULL THEN v_contracts := ARRAY[]::uuid[]; END IF;
  BEGIN DELETE FROM m_form_attachments WHERE form_submission_id IN (SELECT id FROM m_form_submissions WHERE contract_id = ANY(v_contracts)); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM m_form_submissions WHERE contract_id = ANY(v_contracts); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_invoice_receipt_allocations WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_service_ticket_events WHERE ticket_id IN (SELECT id FROM t_service_tickets WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live)); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_service_evidence WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_service_tickets WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_payment_events WHERE invoice_id IN (SELECT id FROM t_invoices WHERE contract_id = ANY(v_contracts)); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_payment_requests WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_appointments WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_invoice WHERE contract_id = ANY(v_contracts); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_attachments WHERE contract_id = ANY(v_contracts); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_contract_assets WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM t_group_session_tokens WHERE contract_id = ANY(v_contracts); EXCEPTION WHEN OTHERS THEN NULL; END;
  -- FIXED: was `WHERE session_contract_id = ANY(v_contracts)` — that column
  -- is never populated, so this always deleted 0 rows.
  BEGIN
    DELETE FROM t_session_payment_declarations spd
    WHERE spd.tenant_id = p_tenant_id
      AND (p_is_live IS NULL OR EXISTS (
        SELECT 1 FROM t_contract_events e WHERE e.id = spd.occurrence_event_id AND e.is_live = p_is_live
      ));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  -- FIXED: same dead-column issue — was `WHERE session_contract_id = ANY(v_contracts)`.
  BEGIN
    DELETE FROM t_session_attendance a
    WHERE a.tenant_id = p_tenant_id
      AND (p_is_live IS NULL OR EXISTS (
        SELECT 1 FROM t_group_session_schedule s WHERE s.id = a.schedule_occurrence_id AND s.is_live = p_is_live
      ));
  EXCEPTION WHEN OTHERS THEN NULL; END;
END;
$function$
