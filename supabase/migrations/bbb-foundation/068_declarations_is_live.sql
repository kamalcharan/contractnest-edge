-- Migration 068: gs_pending_declarations environment-aware overload
-- Already applied live (2026-08-13, Supabase MCP: declarations_is_live_overload).
-- Source-of-record copy — DO NOT RE-RUN on the live project.
--
-- The 1-arg gs_pending_declarations(p_tenant) filtered only tenant+pending,
-- so Live and Test declarations mixed on every consumer (Group Sessions
-- "Payments to confirm" panel since it shipped; Money In strip since A4).
-- t_session_payment_declarations has no is_live column; environment is
-- DERIVED: the check-in occurrence's schedule row first (guest fees always
-- have one), the membership contract as fallback, defaulting LIVE for
-- legacy rows with neither. The 1-arg version is deliberately kept so an
-- un-updated API keeps working mid-deploy; retire it once nothing calls it.
--
-- Verified live on BBB after apply: 6 pending total -> 6 live / 0 test.

CREATE OR REPLACE FUNCTION public.gs_pending_declarations(p_tenant uuid, p_is_live boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_out jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'member_contact_id', d.member_contact_id, 'member_name', ct.name, 'member_salutation', ct.salutation,
      'billing_event_id', d.billing_event_id, 'label', coalesce(e.billing_cycle_label, e.block_name, d.description, cb.name),
      'due_date', e.scheduled_date::date, 'amount', d.amount, 'currency', d.currency,
      'upi_reference', d.upi_reference, 'event_status', e.status, 'created_at', d.created_at,
      'block_id', b.id, 'block_name', coalesce(b.name, d.description, 'Group Session'),
      'is_guest_fee', (d.billing_event_id IS NULL),
      'adhoc_invoice_id', d.adhoc_invoice_id, 'adhoc_invoice_number', inv.invoice_number)
      ORDER BY d.created_at ASC), '[]'::jsonb)
    INTO v_out
    FROM public.t_session_payment_declarations d
    LEFT JOIN public.t_contacts ct ON ct.id = d.member_contact_id
    LEFT JOIN public.t_contract_events e ON e.id = d.billing_event_id
    LEFT JOIN public.t_group_session_schedule s ON s.id = d.occurrence_event_id
    LEFT JOIN public.m_cat_blocks b ON b.id = s.source_block_id
    LEFT JOIN public.m_cat_blocks cb ON cb.id = d.cat_block_id
    LEFT JOIN public.t_invoices inv ON inv.id = d.adhoc_invoice_id
    LEFT JOIN public.t_contracts mc ON mc.id = d.membership_contract_id
   WHERE d.tenant_id = p_tenant AND d.status = 'pending'
     AND coalesce(s.is_live, mc.is_live, true) = p_is_live;
  RETURN jsonb_build_object('ok', true, 'declarations', v_out);
END;
$function$;
