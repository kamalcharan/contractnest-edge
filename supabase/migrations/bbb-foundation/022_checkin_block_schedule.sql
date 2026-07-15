-- ============================================================================
-- bbb-foundation/022_checkin_block_schedule.sql
-- Phase C: wire check-in + attendance to the block schedule (021).
-- ----------------------------------------------------------------------------
-- The QR token now identifies a BLOCK (+ environment), not a contract. Check-in
-- resolves "today's session" from t_group_session_schedule, and attendance is
-- written against the schedule occurrence — which lights up the dashboard's
-- present counts, attendance %, and QR-ready. Legacy contract-token behaviour is
-- kept as a fallback so older links still resolve.
--
-- SECURITY DEFINER; RLS-on-no-policies. Idempotent. Return shapes unchanged so
-- the existing member check-in page keeps working (contract_id may be null in
-- block mode; the page uses contract_name + occurrence).
-- ============================================================================

-- columns: token → block; attendance → schedule occurrence --------------------
-- contract_id was NOT NULL (legacy contract tokens); block tokens leave it null.
ALTER TABLE public.t_group_session_tokens ALTER COLUMN contract_id DROP NOT NULL;
ALTER TABLE public.t_group_session_tokens
  ADD COLUMN IF NOT EXISTS source_block_id uuid,
  ADD COLUMN IF NOT EXISTS is_live         boolean;
CREATE UNIQUE INDEX IF NOT EXISTS uq_gs_token_block
  ON public.t_group_session_tokens (tenant_id, source_block_id, is_live)
  WHERE source_block_id IS NOT NULL;

-- block attendance has no single session contract; occurrence lives on the block
ALTER TABLE public.t_session_attendance ALTER COLUMN session_contract_id DROP NOT NULL;
ALTER TABLE public.t_session_attendance
  ADD COLUMN IF NOT EXISTS schedule_occurrence_id uuid,
  ADD COLUMN IF NOT EXISTS source_block_id        uuid;
CREATE UNIQUE INDEX IF NOT EXISTS uq_session_attendance_sched_member
  ON public.t_session_attendance (schedule_occurrence_id, member_contact_id)
  WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL;

-- helper: a member's active contract that carries the block -------------------
CREATE OR REPLACE FUNCTION public.gs_block_membership_contract(
  p_tenant uuid, p_block uuid, p_member uuid, p_is_live boolean DEFAULT true)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT c.id FROM public.t_contracts c
  JOIN public.t_contract_blocks cb ON cb.contract_id = c.id
  WHERE c.tenant_id = p_tenant AND c.buyer_id = p_member AND c.status = 'active'
    AND coalesce(c.is_live,true) = p_is_live AND cb.source_block_id = p_block
  ORDER BY c.created_at DESC LIMIT 1;
$$;

-- chair: mint/return a token for a block (+ environment) ----------------------
CREATE OR REPLACE FUNCTION public.gs_ensure_block_token(
  p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_token text;
BEGIN
  SELECT token INTO v_token FROM public.t_group_session_tokens
   WHERE tenant_id=p_tenant AND source_block_id=p_block AND is_live=p_is_live;
  IF v_token IS NULL THEN
    v_token := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
    INSERT INTO public.t_group_session_tokens (tenant_id, source_block_id, is_live, token)
    VALUES (p_tenant, p_block, p_is_live, v_token);
  END IF;
  RETURN jsonb_build_object('token', v_token, 'block_id', p_block);
END $$;

-- public: resolve token → today's occurrence (block-aware) --------------------
CREATE OR REPLACE FUNCTION public.gs_resolve_checkin(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_c public.t_contracts;
  v_occ public.t_contract_events; v_next public.t_contract_events;
  v_name text; v_soid uuid; v_odate date; v_nid uuid; v_ndate date; v_live boolean;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

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
      'contract_name', coalesce(v_name,'Group Session'), 'today', current_date,
      'occurrence', CASE WHEN v_soid IS NULL THEN NULL ELSE
        jsonb_build_object('event_id', v_soid, 'date', v_odate, 'name', v_name) END,
      'next_occurrence', CASE WHEN v_nid IS NULL THEN NULL ELSE
        jsonb_build_object('event_id', v_nid, 'date', v_ndate) END);
  END IF;

  -- legacy contract-token behaviour (unchanged)
  SELECT * INTO v_c FROM public.t_contracts WHERE id = v_tok.contract_id;
  SELECT * INTO v_occ FROM public.t_contract_events
   WHERE contract_id=v_tok.contract_id AND event_type='service'
     AND scheduled_date::date = current_date ORDER BY scheduled_date LIMIT 1;
  SELECT * INTO v_next FROM public.t_contract_events
   WHERE contract_id=v_tok.contract_id AND event_type='service'
     AND scheduled_date::date > current_date ORDER BY scheduled_date LIMIT 1;
  RETURN jsonb_build_object('ok', true, 'tenant_id', v_tok.tenant_id,
    'contract_id', v_tok.contract_id, 'contract_name', v_c.name, 'today', current_date,
    'occurrence', CASE WHEN v_occ.id IS NULL THEN NULL ELSE jsonb_build_object(
        'event_id', v_occ.id, 'date', v_occ.scheduled_date::date, 'name', v_occ.block_name) END,
    'next_occurrence', CASE WHEN v_next.id IS NULL THEN NULL ELSE jsonb_build_object(
        'event_id', v_next.id, 'date', v_next.scheduled_date::date) END);
END $$;

-- public: match a phone to a roster member (block-aware) ----------------------
CREATE OR REPLACE FUNCTION public.gs_lookup_member(p_token text, p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_member uuid; v_name text; v_mc uuid;
  v_live boolean; v_digits text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF length(v_digits) < 6 THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;

  IF v_tok.source_block_id IS NOT NULL THEN
    v_live := coalesce(v_tok.is_live, true);
    SELECT ct.id, ct.name INTO v_member, v_name
    FROM public.t_contacts ct
    JOIN public.t_contact_channels ch ON ch.contact_id = ct.id
    WHERE ct.tenant_id = v_tok.tenant_id
      AND ch.channel_type IN ('phone','mobile','whatsapp')
      AND right(regexp_replace(ch.value, '\D', '', 'g'), 10) = right(v_digits, 10)
      AND public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, ct.id, v_live) IS NOT NULL
    LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    v_mc := public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, v_member, v_live);
    RETURN jsonb_build_object('ok', true, 'found', true,
      'member', jsonb_build_object('contact_id', v_member, 'name', v_name, 'membership_contract_id', v_mc));
  END IF;

  -- legacy
  SELECT ct.id, ct.name INTO v_member, v_name
  FROM public.t_contacts ct
  JOIN public.t_contact_channels ch ON ch.contact_id = ct.id
  WHERE ct.tenant_id = v_tok.tenant_id
    AND ch.channel_type IN ('phone','mobile','whatsapp')
    AND right(regexp_replace(ch.value, '\D', '', 'g'), 10) = right(v_digits, 10)
    AND public.gs_membership_contract(v_tok.tenant_id, ct.id) IS NOT NULL
  LIMIT 1;
  IF v_member IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
  v_mc := public.gs_membership_contract(v_tok.tenant_id, v_member);
  RETURN jsonb_build_object('ok', true, 'found', true,
    'member', jsonb_build_object('contact_id', v_member, 'name', v_name, 'membership_contract_id', v_mc));
END $$;

-- public: member attendance + billing history (block-aware) -------------------
CREATE OR REPLACE FUNCTION public.gs_member_history(p_token text, p_member uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_mc uuid; v_live boolean;
  v_att jsonb; v_bill jsonb; v_decl jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  IF v_tok.source_block_id IS NOT NULL THEN
    v_live := coalesce(v_tok.is_live, true);
    v_mc := public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, p_member, v_live);
    SELECT coalesce(jsonb_agg(jsonb_build_object('date', occurrence_date, 'status', status)
                              ORDER BY occurrence_date DESC), '[]'::jsonb)
      INTO v_att FROM public.t_session_attendance
     WHERE source_block_id = v_tok.source_block_id AND member_contact_id = p_member;
  ELSE
    v_mc := public.gs_membership_contract(v_tok.tenant_id, p_member);
    SELECT coalesce(jsonb_agg(jsonb_build_object('date', occurrence_date, 'status', status)
                              ORDER BY occurrence_date DESC), '[]'::jsonb)
      INTO v_att FROM public.t_session_attendance
     WHERE session_contract_id = v_tok.contract_id AND member_contact_id = p_member;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'event_id', e.id, 'label', coalesce(e.billing_cycle_label, e.block_name),
            'date', e.scheduled_date::date, 'amount', e.amount, 'currency', e.currency,
            'status', e.status, 'sub_type', e.billing_sub_type, 'seq', e.sequence_number)
            ORDER BY e.scheduled_date), '[]'::jsonb)
    INTO v_bill FROM public.t_contract_events e
   WHERE e.contract_id = v_mc AND e.event_type = 'billing';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'billing_event_id', billing_event_id, 'status', status,
            'upi_reference', upi_reference, 'amount', amount)
            ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_decl FROM public.t_session_payment_declarations
   WHERE member_contact_id = p_member
     AND ( (v_tok.source_block_id IS NOT NULL AND membership_contract_id = v_mc)
        OR (v_tok.source_block_id IS NULL AND session_contract_id = v_tok.contract_id) );

  RETURN jsonb_build_object('ok', true, 'membership_contract_id', v_mc,
    'attendance', v_att, 'billing', v_bill, 'declarations', v_decl);
END $$;

-- public: submit check-in (block-aware; writes schedule-linked attendance) -----
CREATE OR REPLACE FUNCTION public.gs_submit_checkin(
  p_token text, p_member uuid, p_member_name text, p_member_phone text,
  p_status text, p_payment jsonb DEFAULT NULL,
  p_responses jsonb DEFAULT NULL, p_form_template_id uuid DEFAULT NULL,
  p_form_template_version int DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_occ public.t_contract_events;
  v_soid uuid; v_odate date; v_mc uuid; v_live boolean;
  v_status text := CASE WHEN p_status='apologies' THEN 'apologies' ELSE 'present' END;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  IF v_tok.source_block_id IS NOT NULL THEN
    v_live := coalesce(v_tok.is_live, true);
    SELECT id, occurrence_date INTO v_soid, v_odate
      FROM public.t_group_session_schedule
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id
       AND is_live=v_live AND occurrence_date=current_date AND status IN ('scheduled','held')
     LIMIT 1;
    IF v_soid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;

    IF p_member IS NOT NULL THEN
      INSERT INTO public.t_session_attendance
        (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date,
         member_contact_id, member_name, member_phone, status,
         form_responses, form_template_id, form_template_version)
      VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate,
         p_member, p_member_name, p_member_phone, v_status,
         p_responses, p_form_template_id, p_form_template_version)
      ON CONFLICT (schedule_occurrence_id, member_contact_id)
        WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
        DO UPDATE SET status=excluded.status, member_name=excluded.member_name,
                      member_phone=excluded.member_phone, checked_in_at=now(),
                      form_responses=excluded.form_responses,
                      form_template_id=excluded.form_template_id,
                      form_template_version=excluded.form_template_version;
    ELSE
      INSERT INTO public.t_session_attendance
        (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date,
         member_name, member_phone, status, form_responses, form_template_id, form_template_version)
      VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate,
         p_member_name, p_member_phone, v_status, p_responses, p_form_template_id, p_form_template_version);
    END IF;

    UPDATE public.t_group_session_schedule SET status='held', updated_at=now()
     WHERE id=v_soid AND status='scheduled';

    IF p_member IS NOT NULL AND p_payment IS NOT NULL AND (p_payment->>'billing_event_id') IS NOT NULL THEN
      v_mc := public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, p_member, v_live);
      INSERT INTO public.t_session_payment_declarations
        (tenant_id, session_contract_id, occurrence_event_id, member_contact_id,
         membership_contract_id, billing_event_id, upi_reference, amount, currency)
      VALUES (v_tok.tenant_id, v_mc, v_soid, p_member, v_mc,
         (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference',
         nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
    END IF;

    RETURN public.gs_member_history(p_token, p_member);
  END IF;

  -- legacy contract-token path (unchanged)
  SELECT * INTO v_occ FROM public.t_contract_events
   WHERE contract_id=v_tok.contract_id AND event_type='service'
     AND scheduled_date::date=current_date ORDER BY scheduled_date LIMIT 1;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
  IF p_member IS NOT NULL THEN
    INSERT INTO public.t_session_attendance
      (tenant_id, session_contract_id, occurrence_event_id, occurrence_date,
       member_contact_id, member_name, member_phone, status,
       form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date,
       p_member, p_member_name, p_member_phone, v_status,
       p_responses, p_form_template_id, p_form_template_version)
    ON CONFLICT (occurrence_event_id, member_contact_id)
      DO UPDATE SET status=excluded.status, member_name=excluded.member_name,
                    member_phone=excluded.member_phone, checked_in_at=now(),
                    form_responses=excluded.form_responses,
                    form_template_id=excluded.form_template_id,
                    form_template_version=excluded.form_template_version;
  ELSE
    INSERT INTO public.t_session_attendance
      (tenant_id, session_contract_id, occurrence_event_id, occurrence_date,
       member_name, member_phone, status, form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date,
       p_member_name, p_member_phone, v_status, p_responses, p_form_template_id, p_form_template_version);
  END IF;
  IF p_member IS NOT NULL AND p_payment IS NOT NULL AND (p_payment->>'billing_event_id') IS NOT NULL THEN
    v_mc := public.gs_membership_contract(v_tok.tenant_id, p_member);
    INSERT INTO public.t_session_payment_declarations
      (tenant_id, session_contract_id, occurrence_event_id, member_contact_id,
       membership_contract_id, billing_event_id, upi_reference, amount, currency)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, p_member, v_mc,
       (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference',
       nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
  END IF;
  RETURN public.gs_member_history(p_token, p_member);
END $$;

-- public: check-in form schema (block-aware mapping lookup) --------------------
CREATE OR REPLACE FUNCTION public.gs_checkin_form(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tok public.t_group_session_tokens; v_tid uuid; v_ver int; v_schema jsonb;
  v_default jsonb := jsonb_build_object(
    'id','checkin_default','title','Session Check-in','version',1,
    'sections', jsonb_build_array(jsonb_build_object(
      'id','attendance','title','Attendance',
      'fields', jsonb_build_array(jsonb_build_object(
        'id','attendance_status','type','radio','label','Are you attending today?',
        'default_value','present','validation', jsonb_build_object('required', true),
        'options', jsonb_build_array(
          jsonb_build_object('label','Present','value','present'),
          jsonb_build_object('label','Apologies (not attending)','value','apologies')))))));
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  IF v_tok.source_block_id IS NOT NULL THEN
    SELECT t.id, t.version, t.schema INTO v_tid, v_ver, v_schema
    FROM public.m_form_template_mappings m
    JOIN public.m_form_templates t ON t.id = m.form_template_id
    JOIN public.t_contract_blocks cb ON cb.contract_id = m.contract_id
    WHERE m.tenant_id = v_tok.tenant_id AND cb.source_block_id = v_tok.source_block_id
      AND coalesce(m.status,'active')='active' AND m.timing='during_service'
      AND m.effective_from <= current_date AND (m.effective_to IS NULL OR m.effective_to >= current_date)
      AND t.status='approved'
    ORDER BY m.effective_from DESC, t.version DESC LIMIT 1;
  ELSE
    SELECT t.id, t.version, t.schema INTO v_tid, v_ver, v_schema
    FROM public.m_form_template_mappings m
    JOIN public.m_form_templates t ON t.id = m.form_template_id
    WHERE m.tenant_id = v_tok.tenant_id AND m.contract_id = v_tok.contract_id
      AND coalesce(m.status,'active')='active' AND m.timing='during_service'
      AND m.effective_from <= current_date AND (m.effective_to IS NULL OR m.effective_to >= current_date)
      AND t.status='approved'
    ORDER BY m.effective_from DESC, t.version DESC LIMIT 1;
  END IF;

  IF v_schema IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'source', 'default',
      'form_template_id', NULL, 'form_template_version', NULL, 'schema', v_default);
  END IF;
  RETURN jsonb_build_object('ok', true, 'source', 'template',
    'form_template_id', v_tid, 'form_template_version', v_ver, 'schema', v_schema);
END $$;

-- dashboard: occurrences now carry real present counts ------------------------
CREATE OR REPLACE FUNCTION gs_dash_occurrences(p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_total int;
BEGIN
  SELECT count(*) INTO v_total FROM t_group_session_schedule
   WHERE tenant_id=p_tenant AND source_block_id=p_block AND is_live=p_is_live AND status<>'cancelled';
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'date')), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'event_id', s.id, 'date', s.occurrence_date,
      'seq', s.seq, 'total', v_total, 'status', s.status,
      'is_past', s.occurrence_date < current_date, 'note', s.note,
      'present', (SELECT count(*) FROM t_session_attendance a
                   WHERE a.schedule_occurrence_id=s.id AND a.status='present')
    ) AS r
    FROM t_group_session_schedule s
    WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live
  ) x;
  RETURN jsonb_build_object('occurrences', v);
END $$;

-- dashboard: sessions gain qr_ready + attendance_pct --------------------------
CREATE OR REPLACE FUNCTION gs_dash_sessions(p_tenant uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_total_roster int;
BEGIN
  SELECT count(DISTINCT c.buyer_id) INTO v_total_roster
  FROM t_contract_blocks cb
  JOIN t_contracts c   ON c.id = cb.contract_id
  JOIN m_cat_blocks b  ON b.id = cb.source_block_id
  WHERE c.tenant_id = p_tenant AND coalesce(c.is_live,true) = p_is_live
    AND c.status = 'active' AND b.config->>'audience' = 'group';

  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'block_id', blk.id, 'name', coalesce(blk.name, 'Group Session'),
      'roster_size', blk.roster,
      'occurrences_total', blk.occ_total,
      'occurrences_done', blk.occ_done,
      'next_occurrence', blk.occ_next,
      'qr_ready', exists(SELECT 1 FROM t_group_session_tokens tk
                          WHERE tk.tenant_id=p_tenant AND tk.source_block_id=blk.id
                            AND tk.is_live=p_is_live AND tk.is_active),
      'attendance_pct', CASE WHEN blk.occ_done=0 OR blk.roster=0 THEN NULL
        ELSE round(100.0 * blk.present / (blk.occ_done * blk.roster)) END
    ) AS r
    FROM (
      SELECT b.id, b.name,
        (SELECT count(DISTINCT c2.buyer_id) FROM t_contract_blocks cb2
          JOIN t_contracts c2 ON c2.id=cb2.contract_id
          WHERE cb2.source_block_id=b.id AND c2.tenant_id=p_tenant
            AND coalesce(c2.is_live,true)=p_is_live AND c2.status='active') AS roster,
        (SELECT count(*) FROM t_group_session_schedule s
          WHERE s.tenant_id=p_tenant AND s.source_block_id=b.id AND s.is_live=p_is_live AND s.status<>'cancelled') AS occ_total,
        (SELECT count(*) FROM t_group_session_schedule s
          WHERE s.tenant_id=p_tenant AND s.source_block_id=b.id AND s.is_live=p_is_live
            AND s.status<>'cancelled' AND s.occurrence_date < current_date) AS occ_done,
        (SELECT min(s.occurrence_date) FROM t_group_session_schedule s
          WHERE s.tenant_id=p_tenant AND s.source_block_id=b.id AND s.is_live=p_is_live
            AND s.status='scheduled' AND s.occurrence_date >= current_date) AS occ_next,
        (SELECT count(*) FROM t_session_attendance a
          JOIN t_group_session_schedule s ON s.id=a.schedule_occurrence_id
          WHERE a.source_block_id=b.id AND a.status='present'
            AND s.is_live=p_is_live AND s.occurrence_date < current_date) AS present
      FROM (
        SELECT DISTINCT b.id, b.name FROM t_contract_blocks cb
        JOIN t_contracts c  ON c.id = cb.contract_id
        JOIN m_cat_blocks b ON b.id = cb.source_block_id
        WHERE c.tenant_id=p_tenant AND coalesce(c.is_live,true)=p_is_live
          AND c.status='active' AND b.config->>'audience'='group'
      ) b
    ) blk
  ) s;
  RETURN jsonb_build_object('sessions', v, 'roster_size', v_total_roster);
END $$;

-- dashboard: roster attended = present count for member+block -----------------
CREATE OR REPLACE FUNCTION gs_dash_roster(p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'contact_id', m.buyer_id, 'name', m.buyer_name,
      'membership_contract_id', m.contract_id, 'contract_name', m.contract_name,
      'start_date', m.start_date, 'end_date', m.end_date,
      'attended', (SELECT count(*) FROM t_session_attendance a
                    WHERE a.source_block_id=p_block AND a.member_contact_id=m.buyer_id AND a.status='present'),
      'dues_pending', exists(
        select 1 from t_contract_events be
        where be.contract_id=m.contract_id and be.event_type='billing' and coalesce(be.status,'')<>'paid')
    ) AS r
    FROM (
      SELECT DISTINCT ON (c.buyer_id)
        c.buyer_id, c.buyer_name, c.id AS contract_id, c.name AS contract_name, c.start_date, c.end_date
      FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
      WHERE cb.source_block_id=p_block AND c.tenant_id=p_tenant
        AND coalesce(c.is_live,true)=p_is_live AND c.status='active'
      ORDER BY c.buyer_id, c.start_date DESC NULLS LAST
    ) m
  ) s;
  RETURN jsonb_build_object('roster', v);
END $$;

GRANT EXECUTE ON FUNCTION public.gs_block_membership_contract(uuid,uuid,uuid,boolean) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gs_ensure_block_token(uuid,uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_occurrences(uuid,uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_sessions(uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_roster(uuid,uuid,boolean) TO authenticated, service_role;
