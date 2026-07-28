-- ============================================================================
-- 052_checkin_payment_declaration_dedup.sql
-- ============================================================================
-- Closes a real race condition: nothing stopped a double-tap / resubmit from
-- creating two (or three) payment declarations for the same due. Confirmed
-- live right now: one member has 3 pending declarations for the same due,
-- another has 2 -- these predate this fix and are left alone (chair rejects
-- the extras manually); this migration only guards NEW inserts going forward
-- via a cutover timestamp, since a real unique index can't be created while
-- violating rows already exist.
-- ============================================================================

-- Partial unique indexes -- one pending declaration per member+due (member
-- path), one per member+service+occurrence (guest path). Scoped to rows
-- created after this migration so the pre-existing duplicates don't block
-- index creation.
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_decl_member_billing_pending
  ON public.t_session_payment_declarations (member_contact_id, billing_event_id)
  WHERE billing_event_id IS NOT NULL AND status = 'pending'
    AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_decl_guest_catblock_pending
  ON public.t_session_payment_declarations (member_contact_id, cat_block_id, occurrence_event_id)
  WHERE cat_block_id IS NOT NULL AND status = 'pending'
    AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz;

-- gs_submit_checkin -- same body as before, with ON CONFLICT DO NOTHING added
-- to all three payment-declaration inserts (member path).
CREATE OR REPLACE FUNCTION public.gs_submit_checkin(p_token text, p_member uuid, p_member_name text, p_member_phone text, p_status text, p_payment jsonb DEFAULT NULL::jsonb, p_responses jsonb DEFAULT NULL::jsonb, p_form_template_id uuid DEFAULT NULL::uuid, p_form_template_version integer DEFAULT NULL::integer, p_device_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens; v_occ public.t_contract_events;
  v_soid uuid; v_odate date; v_mc uuid; v_live boolean;
  v_status text := CASE WHEN p_status='apologies' THEN 'apologies' ELSE 'present' END;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF v_tok.source_block_id IS NOT NULL THEN
    v_live := coalesce(v_tok.is_live, true);
    SELECT id, occurrence_date INTO v_soid, v_odate FROM public.t_group_session_schedule
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id
       AND is_live=v_live AND occurrence_date=(now() at time zone 'Asia/Kolkata')::date AND status IN ('scheduled','held') LIMIT 1;
    IF v_soid IS NULL THEN
      IF p_member IS NOT NULL AND p_payment IS NOT NULL AND (p_payment->>'billing_event_id') IS NOT NULL THEN
        v_mc := public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, p_member, v_live);
        INSERT INTO public.t_session_payment_declarations
          (tenant_id, session_contract_id, occurrence_event_id, member_contact_id, membership_contract_id, billing_event_id, upi_reference, amount, currency)
        VALUES (v_tok.tenant_id, v_mc, NULL, p_member, v_mc, (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'))
        ON CONFLICT (member_contact_id, billing_event_id) WHERE billing_event_id IS NOT NULL AND status = 'pending' AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz DO NOTHING;
        PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, v_tok.source_block_id, v_live, p_device_token, 'member', p_member, NULL);
        RETURN public.gs_member_history(p_token, p_member);
      END IF;
      RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today');
    END IF;
    IF p_member IS NOT NULL THEN
      INSERT INTO public.t_session_attendance
        (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
      VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate, p_member, p_member_name, p_member_phone, v_status, p_responses, p_form_template_id, p_form_template_version)
      ON CONFLICT (schedule_occurrence_id, member_contact_id) WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
        DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                      form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version;
    ELSE
      INSERT INTO public.t_session_attendance
        (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
      VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate, p_member_name, p_member_phone, v_status, p_responses, p_form_template_id, p_form_template_version);
    END IF;
    UPDATE public.t_group_session_schedule SET status='held', updated_at=now() WHERE id=v_soid AND status='scheduled';
    IF p_member IS NOT NULL AND p_payment IS NOT NULL AND (p_payment->>'billing_event_id') IS NOT NULL THEN
      v_mc := public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, p_member, v_live);
      INSERT INTO public.t_session_payment_declarations (tenant_id, session_contract_id, occurrence_event_id, member_contact_id, membership_contract_id, billing_event_id, upi_reference, amount, currency)
      VALUES (v_tok.tenant_id, v_tok.contract_id, v_soid, p_member, v_mc, (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'))
      ON CONFLICT (member_contact_id, billing_event_id) WHERE billing_event_id IS NOT NULL AND status = 'pending' AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz DO NOTHING;
    END IF;
    IF p_member IS NOT NULL THEN
      PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, v_tok.source_block_id, v_live, p_device_token, 'member', p_member, NULL);
    END IF;
    RETURN public.gs_member_history(p_token, p_member);
  END IF;
  SELECT * INTO v_occ FROM public.t_contract_events WHERE contract_id=v_tok.contract_id AND event_type='service' AND scheduled_date::date=(now() at time zone 'Asia/Kolkata')::date ORDER BY scheduled_date LIMIT 1;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
  IF p_member IS NOT NULL THEN
    INSERT INTO public.t_session_attendance (tenant_id, session_contract_id, occurrence_event_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date, p_member, p_member_name, p_member_phone, v_status, p_responses, p_form_template_id, p_form_template_version)
    ON CONFLICT (occurrence_event_id, member_contact_id)
      DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                    form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version;
  ELSE
    INSERT INTO public.t_session_attendance (tenant_id, session_contract_id, occurrence_event_id, occurrence_date, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date, p_member_name, p_member_phone, v_status, p_responses, p_form_template_id, p_form_template_version);
  END IF;
  IF p_member IS NOT NULL AND p_payment IS NOT NULL AND (p_payment->>'billing_event_id') IS NOT NULL THEN
    v_mc := public.gs_membership_contract(v_tok.tenant_id, p_member);
    INSERT INTO public.t_session_payment_declarations (tenant_id, session_contract_id, occurrence_event_id, member_contact_id, membership_contract_id, billing_event_id, upi_reference, amount, currency)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, p_member, v_mc, (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'))
    ON CONFLICT (member_contact_id, billing_event_id) WHERE billing_event_id IS NOT NULL AND status = 'pending' AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz DO NOTHING;
  END IF;
  IF p_member IS NOT NULL THEN
    PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, NULL, coalesce(v_tok.is_live, true), p_device_token, 'member', p_member, NULL);
  END IF;
  RETURN public.gs_member_history(p_token, p_member);
END $function$;

-- gs_checkin_guest -- same body as migration 051, with ON CONFLICT DO NOTHING
-- added to both payment-declaration inserts (guest path).
CREATE OR REPLACE FUNCTION public.gs_checkin_guest(p_token text, p_name text, p_phone text, p_company text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_status text DEFAULT 'present'::text, p_responses jsonb DEFAULT NULL::jsonb, p_form_template_id uuid DEFAULT NULL::uuid, p_form_template_version integer DEFAULT NULL::integer, p_device_token text DEFAULT NULL::text, p_referred_by uuid DEFAULT NULL::uuid, p_payment jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens; v_live boolean; v_soid uuid; v_odate date; v_occ public.t_contract_events; v_cid uuid;
  v_status text := CASE WHEN p_status='apologies' THEN 'apologies' ELSE 'present' END;
  v_tags jsonb := jsonb_build_array(jsonb_build_object('tag_color','#6B7280','tag_label','Guest','tag_value','Guest'));
  v_svc_name text;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF coalesce(btrim(p_name),'') = '' THEN RETURN jsonb_build_object('ok', false, 'reason', 'name_required'); END IF;
  v_live := coalesce(v_tok.is_live, true);
  IF coalesce(btrim(p_phone),'') <> '' THEN
    SELECT c.id INTO v_cid FROM public.t_contacts c
    JOIN public.t_contact_channels ch ON ch.contact_id = c.id AND ch.channel_type='mobile' AND ch.value = p_phone
    WHERE c.tenant_id = v_tok.tenant_id AND coalesce(c.is_live, v_live) = v_live AND c.tags @> '[{"tag_value":"Guest"}]'
    ORDER BY c.created_at DESC LIMIT 1;
  END IF;
  IF v_cid IS NULL THEN
    INSERT INTO public.t_contacts
      (tenant_id, type, status, name, tags, industries, is_seed, is_live, is_primary_contact, source, notes, created_at, updated_at)
    VALUES (v_tok.tenant_id, 'individual', 'active', p_name, v_tags, '[]'::jsonb, false, v_live, false, 'session_checkin',
       CASE WHEN coalesce(btrim(p_company),'') <> '' THEN 'Company: ' || btrim(p_company) ELSE NULL END, now(), now())
    RETURNING id INTO v_cid;
    IF coalesce(btrim(p_phone),'') <> '' THEN
      INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary, created_at, updated_at) VALUES (v_cid, 'mobile', p_phone, true, now(), now());
    END IF;
    IF coalesce(btrim(p_email),'') <> '' THEN
      INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary, created_at, updated_at) VALUES (v_cid, 'email', p_email, true, now(), now());
    END IF;
  END IF;
  IF v_tok.source_block_id IS NOT NULL THEN
    SELECT id, occurrence_date INTO v_soid, v_odate FROM public.t_group_session_schedule
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id AND is_live=v_live AND occurrence_date=(now() at time zone 'Asia/Kolkata')::date AND status IN ('scheduled','held') LIMIT 1;
    IF v_soid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
    INSERT INTO public.t_session_attendance
      (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version, referred_by_contact_id)
    VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate, v_cid, p_name, p_phone, v_status, p_responses, p_form_template_id, p_form_template_version, p_referred_by)
    ON CONFLICT (schedule_occurrence_id, member_contact_id) WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
      DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                    form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version,
                    referred_by_contact_id=excluded.referred_by_contact_id;
    UPDATE public.t_group_session_schedule SET status='held', updated_at=now() WHERE id=v_soid AND status='scheduled';
    IF p_payment IS NOT NULL AND (p_payment->>'cat_block_id') IS NOT NULL THEN
      SELECT coalesce(display_name, name) INTO v_svc_name FROM public.m_cat_blocks WHERE id = (p_payment->>'cat_block_id')::uuid AND tenant_id = v_tok.tenant_id;
      IF v_svc_name IS NOT NULL THEN
        INSERT INTO public.t_session_payment_declarations
          (tenant_id, session_contract_id, occurrence_event_id, member_contact_id, cat_block_id, description, upi_reference, amount, currency)
        VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_cid, (p_payment->>'cat_block_id')::uuid, v_svc_name, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'))
        ON CONFLICT (member_contact_id, cat_block_id, occurrence_event_id) WHERE cat_block_id IS NOT NULL AND status = 'pending' AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz DO NOTHING;
      END IF;
    END IF;
    PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, v_tok.source_block_id, v_live, p_device_token, 'guest', v_cid, NULL);
    RETURN jsonb_build_object('ok', true, 'kind', 'guest', 'contact_id', v_cid);
  END IF;
  SELECT * INTO v_occ FROM public.t_contract_events WHERE contract_id=v_tok.contract_id AND event_type='service' AND scheduled_date::date=(now() at time zone 'Asia/Kolkata')::date ORDER BY scheduled_date LIMIT 1;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
  INSERT INTO public.t_session_attendance
    (tenant_id, session_contract_id, occurrence_event_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version, referred_by_contact_id)
  VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date, v_cid, p_name, p_phone, v_status, p_responses, p_form_template_id, p_form_template_version, p_referred_by)
  ON CONFLICT (occurrence_event_id, member_contact_id)
    DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                  form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version,
                  referred_by_contact_id=excluded.referred_by_contact_id;
  IF p_payment IS NOT NULL AND (p_payment->>'cat_block_id') IS NOT NULL THEN
    SELECT coalesce(display_name, name) INTO v_svc_name FROM public.m_cat_blocks WHERE id = (p_payment->>'cat_block_id')::uuid AND tenant_id = v_tok.tenant_id;
    IF v_svc_name IS NOT NULL THEN
      INSERT INTO public.t_session_payment_declarations
        (tenant_id, session_contract_id, occurrence_event_id, member_contact_id, cat_block_id, description, upi_reference, amount, currency)
      VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_cid, (p_payment->>'cat_block_id')::uuid, v_svc_name, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'))
      ON CONFLICT (member_contact_id, cat_block_id, occurrence_event_id) WHERE cat_block_id IS NOT NULL AND status = 'pending' AND created_at >= '2026-07-27 16:29:57.432347+00'::timestamptz DO NOTHING;
    END IF;
  END IF;
  PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, NULL, v_live, p_device_token, 'guest', v_cid, NULL);
  RETURN jsonb_build_object('ok', true, 'kind', 'guest', 'contact_id', v_cid);
END $function$;
