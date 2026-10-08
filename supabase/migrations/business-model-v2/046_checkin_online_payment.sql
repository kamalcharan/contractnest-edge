-- ============================================================================
-- 046 · Online payment (payment gateway) at group-session check-in
-- ============================================================================
-- Any tenant with a payment gateway in the token's environment can take a
-- member's instalment online from the check-in page. Nothing here is
-- tenant-specific.
--
--   gs_checkin_payment_config   + online (gateway configured in this env)
--   gs_checkin_gateway_order    which invoice + amount pays THIS instalment
--   gs_checkin_gateway_attach   stamps the instalment on the payment request
--   gs_checkin_gateway_request  token → request check for verify
--   fn_payment_request_allocations  the request's instalment allocation,
--       only while that instalment still has room (locks the event row)
--   verify_gateway_payment / process_payment_webhook
--       now record through record_invoice_payment_with_allocations, so a
--       payment carrying an allocation settles that instalment; requests
--       without one (every contract pay-page payment today) get [] and
--       behave exactly as before.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gs_checkin_payment_config(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_tok public.t_group_session_tokens; v_cfg jsonb; v_live boolean;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  v_live := COALESCE(v_tok.is_live, true);
  v_cfg := fn_tenant_offline_upi(v_tok.tenant_id, v_live);
  RETURN jsonb_build_object('ok', true) || v_cfg || jsonb_build_object(
    'online', COALESCE((fn_tenant_payment_options(v_tok.tenant_id, v_live)->>'gateway')::boolean, false));
END $$;

-- The membership contract behind a token for a member (block or legacy token).
CREATE OR REPLACE FUNCTION public.gs__token_membership(p_tok public.t_group_session_tokens, p_member uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF p_tok.source_block_id IS NOT NULL THEN
    RETURN public.gs_block_membership_contract(p_tok.tenant_id, p_tok.source_block_id, p_member, COALESCE(p_tok.is_live, true));
  END IF;
  RETURN public.gs_membership_contract(p_tok.tenant_id, p_member);
END $$;

CREATE OR REPLACE FUNCTION public.gs_checkin_gateway_order(p_token text, p_member uuid, p_billing_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_live boolean; v_mc uuid;
  v_ev record; v_inv record; v_remaining numeric; v_amount numeric;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  v_live := COALESCE(v_tok.is_live, true);

  IF NOT COALESCE((fn_tenant_payment_options(v_tok.tenant_id, v_live)->>'gateway')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gateway');
  END IF;

  v_mc := public.gs__token_membership(v_tok, p_member);
  IF v_mc IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_membership'); END IF;

  SELECT id, amount, COALESCE(amount_settled, 0) AS settled, currency, status,
         COALESCE(billing_cycle_label, block_name) AS label
    INTO v_ev FROM public.t_contract_events
   WHERE id = p_billing_event AND contract_id = v_mc AND event_type = 'billing';
  IF v_ev.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_ev.status IN ('cancelled', 'bad_debt') THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_payable'); END IF;
  v_remaining := GREATEST(COALESCE(v_ev.amount, 0) - v_ev.settled, 0);
  IF v_remaining <= 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'already_paid'); END IF;

  -- Same invoice rule the chair's confirm uses (gs_confirm_declaration).
  SELECT id, balance, currency INTO v_inv FROM public.t_invoices
   WHERE contract_id = v_mc AND invoice_type = 'receivable' AND is_active = true
     AND status IN ('unpaid', 'partially_paid') AND COALESCE(is_live, true) = v_live
   ORDER BY created_at ASC LIMIT 1;
  IF v_inv.id IS NULL OR COALESCE(v_inv.balance, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_invoice');
  END IF;

  v_amount := LEAST(v_remaining, v_inv.balance);
  RETURN jsonb_build_object('ok', true,
    'tenant_id', v_tok.tenant_id, 'is_live', v_live, 'contract_id', v_mc,
    'invoice_id', v_inv.id, 'billing_event_id', v_ev.id, 'label', v_ev.label,
    'amount', v_amount, 'currency', COALESCE(v_ev.currency, v_inv.currency, 'INR'));
END $$;

CREATE OR REPLACE FUNCTION public.gs_checkin_gateway_attach(p_token text, p_member uuid, p_billing_event uuid, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_t jsonb; v_req record;
BEGIN
  v_t := public.gs_checkin_gateway_order(p_token, p_member, p_billing_event);
  IF NOT COALESCE((v_t->>'ok')::boolean, false) THEN RETURN v_t; END IF;

  SELECT * INTO v_req FROM public.t_contract_payment_requests
   WHERE id = p_request_id AND tenant_id = (v_t->>'tenant_id')::uuid AND is_active = true
   FOR UPDATE;
  IF v_req.id IS NULL OR v_req.status <> 'created'
     OR v_req.invoice_id <> (v_t->>'invoice_id')::uuid
     OR round(v_req.amount, 2) <> round((v_t->>'amount')::numeric, 2) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'request_mismatch');
  END IF;

  UPDATE public.t_contract_payment_requests
     SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
           'source', 'group_session_checkin',
           'checkin_token', p_token,
           'member_contact_id', p_member,
           'billing_event_id', p_billing_event,
           'event_allocations', jsonb_build_array(jsonb_build_object('event_id', p_billing_event, 'amount', v_req.amount))),
         updated_at = now()
   WHERE id = p_request_id;
  RETURN jsonb_build_object('ok', true, 'request_id', p_request_id);
END $$;

CREATE OR REPLACE FUNCTION public.gs_checkin_gateway_request(p_token text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_tok public.t_group_session_tokens; v_req record;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  SELECT id, tenant_id, is_live, metadata INTO v_req FROM public.t_contract_payment_requests
   WHERE id = p_request_id AND tenant_id = v_tok.tenant_id AND is_active = true;
  IF v_req.id IS NULL OR COALESCE(v_req.metadata->>'checkin_token', '') <> p_token THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  RETURN jsonb_build_object('ok', true, 'tenant_id', v_req.tenant_id, 'is_live', COALESCE(v_req.is_live, true));
END $$;

-- The allocation a gateway payment request carries, if it can still be
-- applied in full. Locks the instalment rows so two payments for the same
-- instalment settle one after the other; the later one finds no room and is
-- recorded on the invoice without an allocation (the money is never lost).
CREATE OR REPLACE FUNCTION public.fn_payment_request_allocations(p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_req record; v_alloc jsonb; v_a jsonb; v_room numeric; v_sum numeric := 0;
BEGIN
  SELECT amount, metadata INTO v_req FROM public.t_contract_payment_requests WHERE id = p_request_id;
  v_alloc := v_req.metadata->'event_allocations';
  IF v_alloc IS NULL OR jsonb_typeof(v_alloc) <> 'array' OR jsonb_array_length(v_alloc) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;
  FOR v_a IN SELECT * FROM jsonb_array_elements(v_alloc) LOOP
    SELECT GREATEST(COALESCE(amount, 0) - COALESCE(amount_settled, 0), 0) INTO v_room
      FROM public.t_contract_events WHERE id = (v_a->>'event_id')::uuid FOR UPDATE;
    IF v_room IS NULL OR v_room + 0.005 < (v_a->>'amount')::numeric THEN RETURN '[]'::jsonb; END IF;
    v_sum := v_sum + (v_a->>'amount')::numeric;
  END LOOP;
  IF round(v_sum, 2) <> round(v_req.amount, 2) THEN RETURN '[]'::jsonb; END IF;
  RETURN v_alloc;
END $$;

-- Both gateway recorders: same receipt, plus the allocation when there is one.
SELECT public.jtd__rewrite_fn('verify_gateway_payment',
  'record_invoice_payment(jsonb_build_object(',
  'record_invoice_payment_with_allocations(jsonb_build_object(''event_allocations'', public.fn_payment_request_allocations(v_request.id), ',
  '046 verify');
SELECT public.jtd__rewrite_fn('process_payment_webhook',
  'record_invoice_payment(jsonb_build_object(',
  'record_invoice_payment_with_allocations(jsonb_build_object(''event_allocations'', public.fn_payment_request_allocations(v_request.id), ',
  '046 webhook');

-- Token-gated like every other public check-in RPC (same grants as
-- gs_submit_checkin). The allocation helper is internal only.
REVOKE EXECUTE ON FUNCTION public.fn_payment_request_allocations(uuid) FROM PUBLIC, anon, authenticated;
