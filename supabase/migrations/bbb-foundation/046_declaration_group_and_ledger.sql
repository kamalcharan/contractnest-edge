-- ============================================================================
-- Migration: bbb-foundation/046 — Payment declarations: group identity + AR
--            ledger stitching on confirm
-- ============================================================================
-- Owner-confirmed flow (2026-07-22): a member's payment selection at check-in
-- is ONLY a flag — it surfaces on the dashboard as a pending declaration.
-- Money enters AR exclusively when the chair confirms, and it must go
-- THROUGH THE INVOICE (one-invoice-per-contract + event-settlement model,
-- bbb-foundation/006). Before this migration, gs_confirm_declaration only
-- flipped the billing event's status to 'paid' — no receipt, no invoice
-- amount_paid, no amount_settled — so confirmed dues never reached
-- /ops/finance and the invoice balance stayed overstated.
--
-- Changes:
--   1. gs_pending_declarations — each row now carries block_id + block_name
--      (declaration → t_group_session_schedule.source_block_id → m_cat_blocks)
--      so the dashboard can show and filter by group. Sorted oldest-first.
--   2. gs_confirm_declaration — on confirm:
--        * finds the membership contract's open receivable invoice
--        * records the payment via record_invoice_payment_with_allocations
--          (method 'upi', the declared UPI ref as reference_number, allocated
--          to the declared billing event) → receipt + invoice.amount_paid +
--          event.amount_settled all advance together
--        * amount = LEAST(declared amount, event's unsettled remainder,
--          invoice balance) — never over-settles
--        * the billing event flips to 'paid' only once fully settled
--        * if the ledger write FAILS, the declaration stays pending and an
--          error is returned (chair can retry / record manually)
--        * if there is NO open invoice or nothing left to settle (zero-priced
--          or already-settled event), the declaration still confirms but the
--          response says ledger_recorded=false
--      Reject branch unchanged.
--
-- Depends on: bbb-foundation/006, 017, 019; contracts/044 (record_invoice_payment)
-- Safe to re-run: Yes (CREATE OR REPLACE)
-- Applied live: 2026-07-22 — project uwyqhzotluikawcboldr
-- ============================================================================

-- ── 1. Pending declarations with group identity ──
CREATE OR REPLACE FUNCTION public.gs_pending_declarations(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_out jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'member_contact_id', d.member_contact_id, 'member_name', ct.name,
      'billing_event_id', d.billing_event_id, 'label', coalesce(e.billing_cycle_label, e.block_name),
      'due_date', e.scheduled_date::date, 'amount', d.amount, 'currency', d.currency,
      'upi_reference', d.upi_reference, 'event_status', e.status, 'created_at', d.created_at,
      'block_id', b.id, 'block_name', coalesce(b.name, 'Group Session'))
      ORDER BY d.created_at ASC), '[]'::jsonb)
    INTO v_out
    FROM public.t_session_payment_declarations d
    LEFT JOIN public.t_contacts ct ON ct.id = d.member_contact_id
    LEFT JOIN public.t_contract_events e ON e.id = d.billing_event_id
    LEFT JOIN public.t_group_session_schedule s ON s.id = d.occurrence_event_id
    LEFT JOIN public.m_cat_blocks b ON b.id = s.source_block_id
   WHERE d.tenant_id = p_tenant AND d.status = 'pending';
  RETURN jsonb_build_object('ok', true, 'declarations', v_out);
END;
$$;

GRANT EXECUTE ON FUNCTION public.gs_pending_declarations(uuid) TO authenticated, service_role;

-- ── 2. Confirm routes the money through the invoice ──
CREATE OR REPLACE FUNCTION public.gs_confirm_declaration(
  p_tenant uuid, p_declaration uuid, p_confirm boolean, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_d         public.t_session_payment_declarations;
  v_ev        record;
  v_inv       record;
  v_remaining numeric;
  v_amount    numeric := 0;
  v_res       jsonb;
BEGIN
  SELECT * INTO v_d FROM public.t_session_payment_declarations
   WHERE id = p_declaration AND tenant_id = p_tenant;
  IF v_d.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_d.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_processed');
  END IF;

  IF NOT p_confirm THEN
    UPDATE public.t_session_payment_declarations
       SET status = 'rejected', confirmed_by = p_user, confirmed_at = now()
     WHERE id = p_declaration;
    RETURN jsonb_build_object('ok', true);
  END IF;

  SELECT id, amount, COALESCE(amount_settled, 0) AS settled,
         COALESCE(is_live, true) AS is_live
    INTO v_ev
    FROM public.t_contract_events
   WHERE id = v_d.billing_event_id AND event_type = 'billing';

  -- The membership contract's open receivable invoice (one per contract)
  SELECT id, contract_id, balance
    INTO v_inv
    FROM public.t_invoices
   WHERE contract_id = v_d.membership_contract_id
     AND invoice_type = 'receivable'
     AND is_active = true
     AND status IN ('unpaid', 'partially_paid')
     AND COALESCE(is_live, true) = COALESCE(v_ev.is_live, true)
   ORDER BY created_at ASC
   LIMIT 1;

  v_remaining := GREATEST(COALESCE(v_ev.amount, 0) - COALESCE(v_ev.settled, 0), 0);
  v_amount := LEAST(COALESCE(v_d.amount, v_remaining), v_remaining, COALESCE(v_inv.balance, 0));

  IF v_inv.id IS NOT NULL AND v_amount > 0 THEN
    v_res := public.record_invoice_payment_with_allocations(jsonb_build_object(
      'invoice_id',      v_inv.id,
      'contract_id',     v_inv.contract_id,
      'tenant_id',       p_tenant,
      'recorded_by',     p_user,
      'is_live',         COALESCE(v_ev.is_live, true),
      'amount',          v_amount,
      'payment_method',  'upi',
      'payment_date',    CURRENT_DATE,
      'reference_number', v_d.upi_reference,
      'notes',           'Group session dues — declaration confirmed by chair',
      'event_allocations', jsonb_build_array(
        jsonb_build_object('event_id', v_d.billing_event_id, 'amount', v_amount))
    ));
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
      -- Declaration stays pending so the chair can retry or record manually.
      RETURN jsonb_build_object('ok', false, 'reason', 'ledger_failed',
        'details', COALESCE(v_res->>'error', 'record_invoice_payment failed'));
    END IF;
  END IF;

  UPDATE public.t_session_payment_declarations
     SET status = 'confirmed', confirmed_by = p_user, confirmed_at = now()
   WHERE id = p_declaration;

  -- Flip the billing event to 'paid' only once its settlement is complete
  UPDATE public.t_contract_events
     SET status = 'paid', updated_at = now()
   WHERE id = v_d.billing_event_id
     AND event_type = 'billing'
     AND COALESCE(amount_settled, 0) >= COALESCE(amount, 0);

  RETURN jsonb_build_object('ok', true,
    'ledger_recorded', (v_inv.id IS NOT NULL AND v_amount > 0),
    'receipt_amount', v_amount);
END;
$$;

GRANT EXECUTE ON FUNCTION public.gs_confirm_declaration(uuid, uuid, boolean, uuid) TO authenticated, service_role;
