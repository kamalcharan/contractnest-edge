-- 053_group_session_whatsapp_triggers.sql
-- Sprint 2: wire the two immediate Group Session WhatsApp triggers directly
-- into the RPCs that already own the underlying writes, so the n_jtd insert
-- happens in the SAME transaction as the attendance/payment-confirm write —
-- if either half fails, both roll back together. No new infrastructure:
-- reuses the existing JTD framework (n_jtd insert with status_code left at
-- its 'created' default fires the jtd_enqueue_on_insert trigger immediately).
--
-- Both inserts are defensive no-ops if there's no phone to send to, and both
-- will simply produce a job that fails to resolve a template (visible in
-- Event Explorer / DLQ as 'failed' — see jtd-worker's "No template found for
-- X/Y") for any tenant that hasn't been mapped in the Template Mapping admin
-- page yet. That's intentional — see 008_seed_group_session_source_types.sql.

-- ============================================================================
-- gs_submit_checkin — attendance acknowledgement (group_session_attendance_ack)
-- ============================================================================
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

    -- Sprint 2: attendance acknowledgement — same transaction as the write
    -- above. Only for a real member with a phone; a manual name-only entry
    -- (no p_member/p_member_phone) has nowhere to send an ack.
    IF p_member IS NOT NULL AND p_member_phone IS NOT NULL AND v_status = 'present' THEN
      INSERT INTO public.n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code, source_id,
        recipient_type, recipient_id, recipient_name, recipient_contact,
        template_key, template_variables, is_live, performed_by_type
      )
      SELECT
        v_tok.tenant_id, 'notification', 'whatsapp', 'group_session_attendance_ack', v_soid,
        'contact', p_member, p_member_name, p_member_phone,
        'group_session_attendance_ack',
        jsonb_build_object(
          'member_name', coalesce(p_member_name, ''),
          'session_name', coalesce(mcb.display_name, mcb.name, ''),
          'occurrence_date', to_char(v_odate, 'DD Mon YYYY')
        ),
        v_live, 'system'
      FROM public.m_cat_blocks mcb WHERE mcb.id = v_tok.source_block_id;
    END IF;

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

-- ============================================================================
-- gs_confirm_declaration — payment thank-you (group_session_payment_thankyou)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.gs_confirm_declaration(p_tenant uuid, p_declaration uuid, p_confirm boolean, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      'payment_date',    (now() at time zone 'Asia/Kolkata')::date,
      'reference_number', v_d.upi_reference,
      'notes',           'Group session dues — declaration confirmed by chair',
      'event_allocations', jsonb_build_array(
        jsonb_build_object('event_id', v_d.billing_event_id, 'amount', v_amount))
    ));
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'ledger_failed',
        'details', COALESCE(v_res->>'error', 'record_invoice_payment failed'));
    END IF;
  END IF;

  UPDATE public.t_session_payment_declarations
     SET status = 'confirmed', confirmed_by = p_user, confirmed_at = now()
   WHERE id = p_declaration;

  UPDATE public.t_contract_events
     SET status = 'paid', updated_at = now()
   WHERE id = v_d.billing_event_id
     AND event_type = 'billing'
     AND COALESCE(amount_settled, 0) >= COALESCE(amount, 0);

  -- Sprint 2: payment thank-you — same transaction as the confirm above.
  -- t_session_payment_declarations has no name/phone of its own; look the
  -- member up via t_contacts / t_contact_channels. Defensive no-op if the
  -- member has no phone on file.
  DECLARE
    v_member_name  text;
    v_member_phone text;
    v_session_name text;
  BEGIN
    SELECT c.name INTO v_member_name FROM public.t_contacts c WHERE c.id = v_d.member_contact_id;

    SELECT coalesce(ch.country_code, '') || ch.value INTO v_member_phone
      FROM public.t_contact_channels ch
     WHERE ch.contact_id = v_d.member_contact_id
       AND ch.channel_type IN ('whatsapp', 'mobile', 'phone')
     ORDER BY ch.is_primary DESC NULLS LAST,
              (ch.channel_type = 'whatsapp') DESC,
              (ch.channel_type = 'mobile') DESC
     LIMIT 1;

    SELECT coalesce(mcb.display_name, mcb.name) INTO v_session_name
      FROM public.m_cat_blocks mcb WHERE mcb.id = v_d.cat_block_id;

    IF v_member_phone IS NOT NULL THEN
      INSERT INTO public.n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code, source_id,
        recipient_type, recipient_id, recipient_name, recipient_contact,
        template_key, template_variables, is_live, performed_by_type
      ) VALUES (
        p_tenant, 'notification', 'whatsapp', 'group_session_payment_thankyou', p_declaration,
        'contact', v_d.member_contact_id, v_member_name, v_member_phone,
        'group_session_payment_thankyou',
        jsonb_build_object(
          'member_name', coalesce(v_member_name, ''),
          'amount', v_amount::text,
          'session_name', coalesce(v_session_name, '')
        ),
        COALESCE(v_ev.is_live, true), 'system'
      );
    END IF;
  END;

  RETURN jsonb_build_object('ok', true,
    'ledger_recorded', (v_inv.id IS NOT NULL AND v_amount > 0),
    'receipt_amount', v_amount);
END;
$function$;
