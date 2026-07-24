-- gs_member_history: surface what the check-in page needs to show a real
-- payment picker instead of a bare list of fixed per-event dues:
--   1. Each billing row now carries amount_settled + remaining (so the UI
--      can cap what a member types to what's actually still owed on the
--      event it will settle against — same event-level fields
--      gs_confirm_declaration already reads).
--   2. `totals` — total_amount / total_paid / balance, pulled straight from
--      t_invoices (the same numbers the seller's Financials tab already
--      shows) — not a new aggregate, just exposing what already exists.
--   3. `cadence_rates` — the membership contract's own cadencePricing rate
--      card (Monthly/Quarterly/etc, real amounts), so check-in's quick-pick
--      chips show what THIS member actually pays, not a hardcoded guess.
-- Everything else (attendance/declarations, the two lookup branches) is
-- unchanged from the 022_checkin_block_schedule.sql definition.

CREATE OR REPLACE FUNCTION public.gs_member_history(p_token text, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens;
  v_mc uuid;
  v_live boolean;
  v_att jsonb;
  v_bill jsonb;
  v_decl jsonb;
  v_totals jsonb;
  v_cadence jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF v_tok.source_block_id IS NOT NULL THEN
    v_live := coalesce(v_tok.is_live, true);
    v_mc := public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, p_member, v_live);
    SELECT coalesce(jsonb_agg(jsonb_build_object('date', occurrence_date, 'status', status) ORDER BY occurrence_date DESC), '[]'::jsonb)
      INTO v_att FROM public.t_session_attendance WHERE source_block_id = v_tok.source_block_id AND member_contact_id = p_member;
  ELSE
    v_mc := public.gs_membership_contract(v_tok.tenant_id, p_member);
    SELECT coalesce(jsonb_agg(jsonb_build_object('date', occurrence_date, 'status', status) ORDER BY occurrence_date DESC), '[]'::jsonb)
      INTO v_att FROM public.t_session_attendance WHERE session_contract_id = v_tok.contract_id AND member_contact_id = p_member;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'event_id', e.id, 'label', coalesce(e.billing_cycle_label, e.block_name),
            'date', e.scheduled_date::date, 'amount', e.amount, 'currency', e.currency, 'status', e.status,
            'sub_type', e.billing_sub_type, 'seq', e.sequence_number,
            'amount_settled', coalesce(e.amount_settled, 0),
            'remaining', greatest(0, coalesce(e.amount, 0) - coalesce(e.amount_settled, 0))
          ) ORDER BY e.scheduled_date), '[]'::jsonb)
    INTO v_bill FROM public.t_contract_events e WHERE e.contract_id = v_mc AND e.event_type = 'billing';

  SELECT coalesce(jsonb_agg(jsonb_build_object('billing_event_id', billing_event_id, 'status', status,
            'upi_reference', upi_reference, 'amount', amount) ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_decl FROM public.t_session_payment_declarations
   WHERE member_contact_id = p_member
     AND ( (v_tok.source_block_id IS NOT NULL AND membership_contract_id = v_mc)
        OR (v_tok.source_block_id IS NULL AND session_contract_id = v_tok.contract_id) );

  SELECT jsonb_build_object(
           'total_amount', coalesce(sum(i.total_amount), 0),
           'total_paid', coalesce(sum(i.amount_paid), 0),
           'balance', coalesce(sum(i.balance), 0)
         )
    INTO v_totals
    FROM public.t_invoices i
   WHERE i.contract_id = v_mc AND i.is_active = true;

  SELECT cb.custom_fields->'config'->'cadencePricing'
    INTO v_cadence
    FROM public.t_contract_blocks cb
   WHERE cb.contract_id = v_mc
     AND cb.custom_fields->'config'->'cadencePricing' IS NOT NULL
   LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true, 'membership_contract_id', v_mc,
    'attendance', v_att, 'billing', v_bill, 'declarations', v_decl,
    'totals', coalesce(v_totals, jsonb_build_object('total_amount', 0, 'total_paid', 0, 'balance', 0)),
    'cadence_rates', coalesce(v_cadence, 'null'::jsonb)
  );
END $function$;
