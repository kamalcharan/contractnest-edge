-- Session check-in currently forces every visitor to type their mobile number
-- on every single scan, even a member rescanning the same chapter's QR every
-- week on the same phone. Add browser-local device recognition:
--   - t_checkin_devices: one row per (tenant, block, device_token) mapping a
--     browser-local random token (generated client-side, stored in
--     localStorage) to the contact it resolved to last time.
--   - gs_checkin_device_lookup: resolve a device_token straight to a member /
--     substitute / guest match, mirroring gs_lookup_member's phone-based
--     lookup but keyed by the stored token instead.
--   - gs_checkin_remember_device: shared upsert helper called from each
--     checkin path on success.
--   - gs_checkin_guest / gs_checkin_substitute / gs_submit_checkin: extended
--     with an optional p_device_token param (defaults NULL, fully backward
--     compatible) that records the device->contact mapping on success.
--
-- UX: member recognition is silent (skip straight to attendance); substitute
-- and guest recognition surface a one-tap confirm in the UI before
-- submitting, since a shared/borrowed phone is a weaker identity signal for
-- those two. No real device ID is available from a browser — this is a
-- persisted-per-browser token, not a verified hardware identity.
--
-- IMPORTANT: adding a parameter via CREATE OR REPLACE does NOT replace a
-- Postgres function if the parameter signature changes — it creates a
-- second overload instead, and any call that omits the new param becomes
-- ambiguous between the two (breaks every existing caller). Drop the old
-- signatures first so only the new one exists. Confirmed live: this exact
-- ambiguity was hit and fixed during development of this migration.

DROP FUNCTION IF EXISTS public.gs_checkin_guest(text, text, text, text, text, text, jsonb, uuid, integer);
DROP FUNCTION IF EXISTS public.gs_checkin_substitute(text, uuid, text, text, text, jsonb, uuid, integer);
DROP FUNCTION IF EXISTS public.gs_submit_checkin(text, uuid, text, text, text, jsonb, jsonb, uuid, integer);

CREATE TABLE IF NOT EXISTS public.t_checkin_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  source_block_id uuid NULL,
  is_live boolean NOT NULL DEFAULT true,
  device_token text NOT NULL,
  role text NOT NULL CHECK (role IN ('member','substitute','guest')),
  contact_id uuid NOT NULL,
  last_member_id uuid NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS t_checkin_devices_lookup_idx
  ON public.t_checkin_devices (tenant_id, is_live, source_block_id, device_token);

CREATE INDEX IF NOT EXISTS t_checkin_devices_contact_idx
  ON public.t_checkin_devices (tenant_id, contact_id);

CREATE OR REPLACE FUNCTION public.gs_checkin_remember_device(
  p_tenant uuid, p_block uuid, p_live boolean, p_device_token text,
  p_role text, p_contact uuid, p_last_member uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(btrim(p_device_token), '') = '' THEN RETURN; END IF;
  UPDATE public.t_checkin_devices
     SET role = p_role, contact_id = p_contact, last_member_id = p_last_member, last_seen_at = now()
   WHERE tenant_id = p_tenant AND is_live = p_live AND device_token = p_device_token
     AND source_block_id IS NOT DISTINCT FROM p_block;
  IF NOT FOUND THEN
    INSERT INTO public.t_checkin_devices
      (tenant_id, source_block_id, is_live, device_token, role, contact_id, last_member_id, last_seen_at)
    VALUES (p_tenant, p_block, p_live, p_device_token, p_role, p_contact, p_last_member, now());
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.gs_checkin_device_lookup(p_token text, p_device_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens; v_live boolean; v_dev public.t_checkin_devices;
  v_name text; v_mc uuid; v_last_mc uuid; v_last_name text; v_member_phone text;
  v_sub_phone text; v_guest_phone text; v_guest_email text; v_guest_company text;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF coalesce(btrim(p_device_token), '') = '' THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
  v_live := coalesce(v_tok.is_live, true);

  SELECT * INTO v_dev FROM public.t_checkin_devices
   WHERE tenant_id = v_tok.tenant_id AND is_live = v_live
     AND source_block_id IS NOT DISTINCT FROM v_tok.source_block_id
     AND device_token = p_device_token
   LIMIT 1;
  IF v_dev.id IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;

  IF v_dev.role = 'member' THEN
    SELECT name INTO v_name FROM public.t_contacts WHERE id = v_dev.contact_id AND tenant_id = v_tok.tenant_id;
    IF v_name IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    v_mc := CASE WHEN v_tok.source_block_id IS NOT NULL
      THEN public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, v_dev.contact_id, v_live)
      ELSE public.gs_membership_contract(v_tok.tenant_id, v_dev.contact_id) END;
    IF v_mc IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    SELECT ch.value INTO v_member_phone FROM public.t_contact_channels ch
      WHERE ch.contact_id = v_dev.contact_id AND ch.channel_type IN ('mobile','whatsapp')
      ORDER BY CASE ch.channel_type WHEN 'mobile' THEN 0 ELSE 1 END, ch.is_primary DESC NULLS LAST LIMIT 1;
    RETURN jsonb_build_object('ok', true, 'found', true, 'role', 'member',
      'member', jsonb_build_object('contact_id', v_dev.contact_id, 'name', v_name, 'membership_contract_id', v_mc, 'phone', v_member_phone));
  END IF;

  IF v_dev.role = 'substitute' THEN
    SELECT name INTO v_name FROM public.t_contacts WHERE id = v_dev.contact_id AND tenant_id = v_tok.tenant_id;
    IF v_name IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    SELECT ch.value INTO v_sub_phone FROM public.t_contact_channels ch
      WHERE ch.contact_id = v_dev.contact_id AND ch.channel_type = 'mobile'
      ORDER BY ch.is_primary DESC NULLS LAST LIMIT 1;
    IF v_dev.last_member_id IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    SELECT name INTO v_last_name FROM public.t_contacts WHERE id = v_dev.last_member_id AND tenant_id = v_tok.tenant_id;
    IF v_last_name IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    v_last_mc := CASE WHEN v_tok.source_block_id IS NOT NULL
      THEN public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, v_dev.last_member_id, v_live)
      ELSE public.gs_membership_contract(v_tok.tenant_id, v_dev.last_member_id) END;
    IF v_last_mc IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    RETURN jsonb_build_object('ok', true, 'found', true, 'role', 'substitute',
      'substitute', jsonb_build_object('contact_id', v_dev.contact_id, 'name', v_name, 'phone', v_sub_phone),
      'last_member', jsonb_build_object('contact_id', v_dev.last_member_id, 'name', v_last_name, 'membership_contract_id', v_last_mc));
  END IF;

  IF v_dev.role = 'guest' THEN
    SELECT name, CASE WHEN notes LIKE 'Company: %' THEN substr(notes, 10) ELSE NULL END
      INTO v_name, v_guest_company
      FROM public.t_contacts WHERE id = v_dev.contact_id AND tenant_id = v_tok.tenant_id;
    IF v_name IS NULL THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;
    SELECT ch.value INTO v_guest_phone FROM public.t_contact_channels ch
      WHERE ch.contact_id = v_dev.contact_id AND ch.channel_type = 'mobile'
      ORDER BY ch.is_primary DESC NULLS LAST LIMIT 1;
    SELECT ch.value INTO v_guest_email FROM public.t_contact_channels ch
      WHERE ch.contact_id = v_dev.contact_id AND ch.channel_type = 'email'
      ORDER BY ch.is_primary DESC NULLS LAST LIMIT 1;
    RETURN jsonb_build_object('ok', true, 'found', true, 'role', 'guest',
      'guest', jsonb_build_object('contact_id', v_dev.contact_id, 'name', v_name, 'phone', v_guest_phone, 'email', v_guest_email, 'company', v_guest_company));
  END IF;

  RETURN jsonb_build_object('ok', true, 'found', false);
END $function$;

-- ── gs_checkin_guest: + p_device_token (defaults NULL, backward compatible) ──
CREATE OR REPLACE FUNCTION public.gs_checkin_guest(p_token text, p_name text, p_phone text, p_company text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_status text DEFAULT 'present'::text, p_responses jsonb DEFAULT NULL::jsonb, p_form_template_id uuid DEFAULT NULL::uuid, p_form_template_version integer DEFAULT NULL::integer, p_device_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens; v_live boolean; v_soid uuid; v_odate date; v_occ public.t_contract_events; v_cid uuid;
  v_status text := CASE WHEN p_status='apologies' THEN 'apologies' ELSE 'present' END;
  v_tags jsonb := jsonb_build_array(jsonb_build_object('tag_color','#6B7280','tag_label','Guest','tag_value','Guest'));
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
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id AND is_live=v_live AND occurrence_date=current_date AND status IN ('scheduled','held') LIMIT 1;
    IF v_soid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
    INSERT INTO public.t_session_attendance
      (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate, v_cid, p_name, p_phone, v_status, p_responses, p_form_template_id, p_form_template_version)
    ON CONFLICT (schedule_occurrence_id, member_contact_id) WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
      DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                    form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version;
    UPDATE public.t_group_session_schedule SET status='held', updated_at=now() WHERE id=v_soid AND status='scheduled';
    PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, v_tok.source_block_id, v_live, p_device_token, 'guest', v_cid, NULL);
    RETURN jsonb_build_object('ok', true, 'kind', 'guest', 'contact_id', v_cid);
  END IF;
  SELECT * INTO v_occ FROM public.t_contract_events WHERE contract_id=v_tok.contract_id AND event_type='service' AND scheduled_date::date=current_date ORDER BY scheduled_date LIMIT 1;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
  INSERT INTO public.t_session_attendance
    (tenant_id, session_contract_id, occurrence_event_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
  VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date, v_cid, p_name, p_phone, v_status, p_responses, p_form_template_id, p_form_template_version)
  ON CONFLICT (occurrence_event_id, member_contact_id)
    DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                  form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version;
  PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, NULL, v_live, p_device_token, 'guest', v_cid, NULL);
  RETURN jsonb_build_object('ok', true, 'kind', 'guest', 'contact_id', v_cid);
END $function$;

-- ── gs_checkin_substitute: + p_device_token (defaults NULL, backward compatible) ──
CREATE OR REPLACE FUNCTION public.gs_checkin_substitute(p_token text, p_member uuid, p_sub_name text, p_sub_phone text, p_status text DEFAULT 'present'::text, p_responses jsonb DEFAULT NULL::jsonb, p_form_template_id uuid DEFAULT NULL::uuid, p_form_template_version integer DEFAULT NULL::integer, p_device_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens; v_live boolean; v_soid uuid; v_odate date; v_occ public.t_contract_events;
  v_member public.t_contacts; v_sub uuid;
  v_status text := CASE WHEN p_status='apologies' THEN 'apologies' ELSE 'present' END;
  v_tags jsonb := jsonb_build_array(jsonb_build_object('tag_color','#8B5CF6','tag_label','Substitute','tag_value','Substitute'));
  v_resp jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF coalesce(btrim(p_sub_name),'') = '' THEN RETURN jsonb_build_object('ok', false, 'reason', 'substitute_name_required'); END IF;
  SELECT * INTO v_member FROM public.t_contacts WHERE id = p_member AND tenant_id = v_tok.tenant_id;
  IF v_member.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'member_not_found'); END IF;
  v_live := coalesce(v_tok.is_live, true);
  IF coalesce(btrim(p_sub_phone),'') <> '' THEN
    SELECT c.id INTO v_sub FROM public.t_contacts c
    JOIN public.t_contact_channels ch ON ch.contact_id = c.id AND ch.channel_type='mobile' AND ch.value = p_sub_phone
    WHERE c.parent_contact_id = p_member AND c.tenant_id = v_tok.tenant_id ORDER BY c.created_at DESC LIMIT 1;
  END IF;
  IF v_sub IS NULL THEN
    INSERT INTO public.t_contacts
      (tenant_id, parent_contact_id, type, status, name, tags, industries, is_seed, is_live, is_primary_contact, source, notes, created_at, updated_at)
    VALUES (v_tok.tenant_id, p_member, 'contact_person', 'active', p_sub_name, v_tags, '[]'::jsonb, false, v_live, false, 'session_checkin',
       'Substitute for ' || coalesce(v_member.name,'member') || ' (added at session check-in)', now(), now())
    RETURNING id INTO v_sub;
    IF coalesce(btrim(p_sub_phone),'') <> '' THEN
      INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary, created_at, updated_at) VALUES (v_sub, 'mobile', p_sub_phone, false, now(), now());
    END IF;
  END IF;
  v_resp := coalesce(p_responses, '{}'::jsonb) || jsonb_build_object('is_substitute', true, 'substitute_contact_id', v_sub, 'substitute_name', p_sub_name, 'substitute_phone', p_sub_phone);
  IF v_tok.source_block_id IS NOT NULL THEN
    SELECT id, occurrence_date INTO v_soid, v_odate FROM public.t_group_session_schedule
     WHERE tenant_id=v_tok.tenant_id AND source_block_id=v_tok.source_block_id AND is_live=v_live AND occurrence_date=current_date AND status IN ('scheduled','held') LIMIT 1;
    IF v_soid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
    INSERT INTO public.t_session_attendance
      (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_odate, p_member,
            coalesce(v_member.name,'Member') || ' (substitute: ' || p_sub_name || ')', p_sub_phone, v_status, v_resp, p_form_template_id, p_form_template_version)
    ON CONFLICT (schedule_occurrence_id, member_contact_id) WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
      DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                    form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version;
    UPDATE public.t_group_session_schedule SET status='held', updated_at=now() WHERE id=v_soid AND status='scheduled';
    PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, v_tok.source_block_id, v_live, p_device_token, 'substitute', v_sub, p_member);
    RETURN public.gs_member_history(p_token, p_member);
  END IF;
  SELECT * INTO v_occ FROM public.t_contract_events WHERE contract_id=v_tok.contract_id AND event_type='service' AND scheduled_date::date=current_date ORDER BY scheduled_date LIMIT 1;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
  INSERT INTO public.t_session_attendance
    (tenant_id, session_contract_id, occurrence_event_id, occurrence_date, member_contact_id, member_name, member_phone, status, form_responses, form_template_id, form_template_version)
  VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date, p_member,
          coalesce(v_member.name,'Member') || ' (substitute: ' || p_sub_name || ')', p_sub_phone, v_status, v_resp, p_form_template_id, p_form_template_version)
  ON CONFLICT (occurrence_event_id, member_contact_id)
    DO UPDATE SET status=excluded.status, member_name=excluded.member_name, member_phone=excluded.member_phone, checked_in_at=now(),
                  form_responses=excluded.form_responses, form_template_id=excluded.form_template_id, form_template_version=excluded.form_template_version;
  PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, NULL, v_live, p_device_token, 'substitute', v_sub, p_member);
  RETURN public.gs_member_history(p_token, p_member);
END $function$;

-- ── gs_submit_checkin: + p_device_token (defaults NULL, backward compatible) ──
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
       AND is_live=v_live AND occurrence_date=current_date AND status IN ('scheduled','held') LIMIT 1;
    IF v_soid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;
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
      VALUES (v_tok.tenant_id, v_mc, v_soid, p_member, v_mc, (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
    END IF;
    IF p_member IS NOT NULL THEN
      PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, v_tok.source_block_id, v_live, p_device_token, 'member', p_member, NULL);
    END IF;
    RETURN public.gs_member_history(p_token, p_member);
  END IF;
  SELECT * INTO v_occ FROM public.t_contract_events WHERE contract_id=v_tok.contract_id AND event_type='service' AND scheduled_date::date=current_date ORDER BY scheduled_date LIMIT 1;
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
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, p_member, v_mc, (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
  END IF;
  IF p_member IS NOT NULL THEN
    PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, NULL, coalesce(v_tok.is_live, true), p_device_token, 'member', p_member, NULL);
  END IF;
  RETURN public.gs_member_history(p_token, p_member);
END $function$;
