-- 076_guest_checkin_contact_dedupe.sql
-- ⚠ SOURCE-OF-RECORD COPY — ALREADY APPLIED LIVE (2026-09-16). DO NOT RE-RUN.
--
-- WHY: gs_checkin_guest duplicated contacts on every repeat guest visit.
-- Live proof: "Tejaswinni Bappudi Sundar" exists twice on BBB (8 Aug + 5 Sep),
-- identical phone (+919059951359) and email, both created_by NULL at ~07:35
-- IST on meeting Saturdays — i.e. both rows came from the guest check-in RPC,
-- not the contacts UI (whose create paths already run checkDuplicates).
--
-- The old reuse-lookup required BOTH of:
--   1. ch.value = p_phone           — EXACT string match; stored values carry
--      '+91' while guests type bare 10 digits, so it never matched;
--   2. c.tags @> '[{"tag_value":"Guest"}]' — the 8 Aug original was untagged,
--      so even a normalized match would have been skipped.
--
-- FIX (this migration), in the 12-arg overload only:
--   - match on the LAST 10 DIGITS of the digits-only channel value vs the
--     digits-only p_phone (country-code and formatting insensitive);
--   - only attempt the lookup when p_phone carries >= 10 digits;
--   - drop the Guest-tag prerequisite: ANY non-archived contact of the tenant
--     + environment with that mobile is reused (a member checking in as a
--     guest reuses their member record instead of spawning a Guest twin);
--     tags on a matched contact are deliberately left untouched;
--   - prefer the OLDEST match (created_at ASC) so pre-existing duplicates
--     converge on the original record.
--
-- Also drops the stale 10-argument overload (no payment support) that has
-- been flagged since 2026-08-06 — the API always sends 12 args, and the old
-- overload only needed to disappear before it resolved by accident.
--
-- Post-checks RAISE if the rewrite did not land (migration 059 lesson:
-- a silent no-op is the failure mode of function rewrites).

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
  -- Dedupe: reuse ANY non-archived contact in this tenant+environment whose
  -- mobile matches on the last 10 digits (format/country-code insensitive).
  -- Oldest first so historical duplicates converge on the original record.
  IF length(regexp_replace(coalesce(p_phone,''),'\D','','g')) >= 10 THEN
    SELECT c.id INTO v_cid FROM public.t_contacts c
    JOIN public.t_contact_channels ch ON ch.contact_id = c.id AND ch.channel_type='mobile'
      AND right(regexp_replace(ch.value,'\D','','g'),10) = right(regexp_replace(p_phone,'\D','','g'),10)
    WHERE c.tenant_id = v_tok.tenant_id AND coalesce(c.is_live, v_live) = v_live
      AND coalesce(c.status,'active') <> 'archived'
    ORDER BY c.created_at ASC LIMIT 1;
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

-- Retire the stale 10-argument overload (no payment support; flagged 2026-08-06)
DROP FUNCTION IF EXISTS public.gs_checkin_guest(text, text, text, text, text, text, jsonb, uuid, integer, text);

-- Post-checks: the rewrite must have landed, exactly one overload must remain
DO $$
DECLARE v_n int; v_src text;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname='gs_checkin_guest';
  IF v_n <> 1 THEN RAISE EXCEPTION 'expected exactly 1 gs_checkin_guest overload, found %', v_n; END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='gs_checkin_guest';
  IF v_src NOT LIKE '%right(regexp_replace(ch.value%' THEN RAISE EXCEPTION 'normalized phone match not present'; END IF;
  IF v_src LIKE '%tag_value":"Guest"}]''%' AND v_src LIKE '%c.tags @>%' THEN RAISE EXCEPTION 'old Guest-tag prerequisite still present'; END IF;
END $$;
