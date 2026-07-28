-- ============================================================================
-- 051_checkin_guest_payment_referrer.sql
-- ============================================================================
-- Supports the 3-step check-in redesign:
--   1) Guests have no contract, so they can't "pay a due" like a member —
--      they pick a standalone catalog service (tenant-flagged guestPayable)
--      and that gets recorded as a payment declaration with no billing_event
--      (chair confirms it like any other declaration, but it's tracked-only —
--      no invoice/ledger entry, since there's no real contract to settle).
--   2) Guests can be tagged with which member referred them.
-- ============================================================================

-- 1) Loosen the two columns that assumed every declaration ties to a real
--    membership contract + billing event. Guests have neither.
ALTER TABLE public.t_session_payment_declarations
  ALTER COLUMN membership_contract_id DROP NOT NULL,
  ALTER COLUMN billing_event_id DROP NOT NULL;

ALTER TABLE public.t_session_payment_declarations
  ADD COLUMN IF NOT EXISTS cat_block_id uuid NULL,
  ADD COLUMN IF NOT EXISTS description text NULL;

-- 2) Referrer tagging lives on the attendance row (contextual to this
--    check-in), not on the contact itself.
ALTER TABLE public.t_session_attendance
  ADD COLUMN IF NOT EXISTS referred_by_contact_id uuid NULL;

-- 3) Fix the tenant's existing "Guest Participation Fee" block: it was
--    created with complimentary:true (no billing events at all), which
--    contradicts the intent to actually charge guests. Also flag it
--    guestPayable so it shows up in the check-in service picker.
UPDATE public.m_cat_blocks
   SET config = config || jsonb_build_object('complimentary', false, 'guestPayable', true)
 WHERE id = '82c31a62-a705-45d3-ace9-10a747486155';

-- 4) List guest-payable services for the check-in page — tenant admins flag
--    any catalog service with config.guestPayable:true; nothing hardcoded.
CREATE OR REPLACE FUNCTION public.gs_checkin_guest_services(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens;
  v_out jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id,
      'name', coalesce(b.display_name, b.name),
      'price', b.base_price,
      'currency', coalesce(b.currency, 'INR')
    ) ORDER BY b.sequence_no NULLS LAST, b.name), '[]'::jsonb)
    INTO v_out
  FROM public.m_cat_blocks b
  WHERE b.tenant_id = v_tok.tenant_id
    AND b.category = 'service'
    AND b.is_active AND b.visible
    AND b.is_live = coalesce(v_tok.is_live, true)
    AND coalesce(b.config->>'guestPayable', 'false') = 'true';

  RETURN jsonb_build_object('ok', true, 'services', v_out);
END;
$function$;

-- 5) Search roster members by name, for the guest "Referred by" picker.
--    Mirrors gs_lookup_member's membership check, just by name instead of phone.
CREATE OR REPLACE FUNCTION public.gs_checkin_search_members(p_token text, p_query text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens; v_live boolean; v_out jsonb;
  v_q text := btrim(coalesce(p_query, ''));
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF length(v_q) < 2 THEN RETURN jsonb_build_object('ok', true, 'members', '[]'::jsonb); END IF;
  v_live := coalesce(v_tok.is_live, true);

  IF v_tok.source_block_id IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('contact_id', m.id, 'name', m.name)), '[]'::jsonb) INTO v_out
    FROM (
      SELECT DISTINCT ct.id, ct.name
      FROM public.t_contacts ct
      WHERE ct.tenant_id = v_tok.tenant_id
        AND ct.name ILIKE '%' || v_q || '%'
        AND public.gs_block_membership_contract(v_tok.tenant_id, v_tok.source_block_id, ct.id, v_live) IS NOT NULL
      ORDER BY ct.name LIMIT 8
    ) m;
    RETURN jsonb_build_object('ok', true, 'members', v_out);
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('contact_id', m.id, 'name', m.name)), '[]'::jsonb) INTO v_out
  FROM (
    SELECT DISTINCT ct.id, ct.name
    FROM public.t_contacts ct
    WHERE ct.tenant_id = v_tok.tenant_id
      AND ct.name ILIKE '%' || v_q || '%'
      AND public.gs_membership_contract(v_tok.tenant_id, ct.id) IS NOT NULL
    ORDER BY ct.name LIMIT 8
  ) m;
  RETURN jsonb_build_object('ok', true, 'members', v_out);
END;
$function$;

-- 6) gs_checkin_guest — add optional payment (standalone service, no
--    billing_event/membership_contract) and optional referrer tagging.
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
        VALUES (v_tok.tenant_id, v_tok.source_block_id, v_soid, v_cid, (p_payment->>'cat_block_id')::uuid, v_svc_name, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
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
      VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_cid, (p_payment->>'cat_block_id')::uuid, v_svc_name, p_payment->>'upi_reference', nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
    END IF;
  END IF;
  PERFORM public.gs_checkin_remember_device(v_tok.tenant_id, NULL, v_live, p_device_token, 'guest', v_cid, NULL);
  RETURN jsonb_build_object('ok', true, 'kind', 'guest', 'contact_id', v_cid);
END $function$;

-- 7) Chair's "Payments to confirm" list: surface a guest-fee's service name
--    and an explicit is_guest_fee flag (no billing_event_id => tracked-only,
--    no invoice/ledger entry gets created when it's confirmed).
CREATE OR REPLACE FUNCTION public.gs_pending_declarations(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_out jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'member_contact_id', d.member_contact_id, 'member_name', ct.name,
      'billing_event_id', d.billing_event_id, 'label', coalesce(e.billing_cycle_label, e.block_name, d.description, cb.name),
      'due_date', e.scheduled_date::date, 'amount', d.amount, 'currency', d.currency,
      'upi_reference', d.upi_reference, 'event_status', e.status, 'created_at', d.created_at,
      'block_id', b.id, 'block_name', coalesce(b.name, d.description, 'Group Session'),
      'is_guest_fee', (d.billing_event_id IS NULL))
      ORDER BY d.created_at ASC), '[]'::jsonb)
    INTO v_out
    FROM public.t_session_payment_declarations d
    LEFT JOIN public.t_contacts ct ON ct.id = d.member_contact_id
    LEFT JOIN public.t_contract_events e ON e.id = d.billing_event_id
    LEFT JOIN public.t_group_session_schedule s ON s.id = d.occurrence_event_id
    LEFT JOIN public.m_cat_blocks b ON b.id = s.source_block_id
    LEFT JOIN public.m_cat_blocks cb ON cb.id = d.cat_block_id
   WHERE d.tenant_id = p_tenant AND d.status = 'pending';
  RETURN jsonb_build_object('ok', true, 'declarations', v_out);
END;
$function$;
