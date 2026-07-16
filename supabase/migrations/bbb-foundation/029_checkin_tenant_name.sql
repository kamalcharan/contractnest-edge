-- ============================================================================
-- gs_resolve_checkin — add business_name (tenant/org name) to the payload
-- Migration: bbb-foundation/029_checkin_tenant_name.sql
--
-- The public check-in page (/checkin/:token) shows the cadence/session name
-- ("Saturday Cadence") but has no way to show which tenant/organization it
-- belongs to — t_tenant_profiles.business_name was never in this RPC's
-- output. Adds it as `business_name` in both the block-token and legacy
-- contract-token branches. No other fields change.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gs_resolve_checkin(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_c public.t_contracts;
  v_occ public.t_contract_events; v_next public.t_contract_events;
  v_name text; v_soid uuid; v_odate date; v_nid uuid; v_ndate date; v_live boolean;
  v_business_name text;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  SELECT business_name INTO v_business_name
    FROM public.t_tenant_profiles WHERE tenant_id = v_tok.tenant_id;

  IF v_tok.source_block_id IS NOT NULL THEN
    v_live := coalesce(v_tok.is_live, true);
    SELECT name INTO v_name FROM public.m_cat_blocks WHERE id = v_tok.source_block_id;
    SELECT id, occurrence_date INTO v_soid, v_odate
      FROM public.t_group_session_schedule
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id
       AND is_live=v_live AND occurrence_date=current_date AND status IN ('scheduled','held')
     LIMIT 1;
    SELECT id, occurrence_date INTO v_nid, v_ndate
      FROM public.t_group_session_schedule
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id
       AND is_live=v_live AND occurrence_date>current_date AND status='scheduled'
     ORDER BY occurrence_date LIMIT 1;
    RETURN jsonb_build_object('ok', true,
      'tenant_id', v_tok.tenant_id, 'contract_id', NULL, 'block_id', v_tok.source_block_id,
      'contract_name', coalesce(v_name,'Group Session'), 'business_name', v_business_name, 'today', current_date,
      'occurrence', CASE WHEN v_soid IS NULL THEN NULL ELSE
        jsonb_build_object('event_id', v_soid, 'date', v_odate, 'name', v_name) END,
      'next_occurrence', CASE WHEN v_nid IS NULL THEN NULL ELSE
        jsonb_build_object('event_id', v_nid, 'date', v_ndate) END);
  END IF;

  -- legacy contract-token behaviour (unchanged apart from business_name)
  SELECT * INTO v_c FROM public.t_contracts WHERE id = v_tok.contract_id;
  SELECT * INTO v_occ FROM public.t_contract_events
   WHERE contract_id=v_tok.contract_id AND event_type='service'
     AND scheduled_date::date = current_date ORDER BY scheduled_date LIMIT 1;
  SELECT * INTO v_next FROM public.t_contract_events
   WHERE contract_id=v_tok.contract_id AND event_type='service'
     AND scheduled_date::date > current_date ORDER BY scheduled_date LIMIT 1;
  RETURN jsonb_build_object('ok', true, 'tenant_id', v_tok.tenant_id,
    'contract_id', v_tok.contract_id, 'contract_name', v_c.name, 'business_name', v_business_name, 'today', current_date,
    'occurrence', CASE WHEN v_occ.id IS NULL THEN NULL ELSE jsonb_build_object(
        'event_id', v_occ.id, 'date', v_occ.scheduled_date::date, 'name', v_occ.block_name) END,
    'next_occurrence', CASE WHEN v_next.id IS NULL THEN NULL ELSE jsonb_build_object(
        'event_id', v_next.id, 'date', v_next.scheduled_date::date) END);
END $$;
