-- ============================================================================
-- 015_visit_slot_customer_loop.sql — Ops on JTD · Appointments = the visit's
-- slot, closed WITH THE CUSTOMER (batch ops-appointments-loop, 2026-09-17)
-- ============================================================================
-- Owner: "appointments?" → analysis: 164 appointments ever, 163 auto-expired
-- by the nightly cron, 0 accepted — the scanner asks, nobody chases, the
-- customer has no way to answer. This closes the loop:
--   1. t_appointments gains a public link grant (slot_token) + ask bookkeeping
--   2. source type visit_slot_request + global template rows. provider ids are
--      NULL until the owner registers the templates (MSG91 email template +
--      MSG91 WhatsApp positional template); until then "Ask customer" offers
--      SHARE (wa.me / copy) which needs no registration.
--   3. jtd_ask_visit_slot — one tap: proposes the planned date when no timed
--      slot exists, then asks via share | email | whatsapp. Actor-carrying.
--   4. visit_slot_resolve / visit_slot_respond — PUBLIC, token-gated (the
--      check-in pattern): Accept · Suggest another time · Not needed.
--      A counter-proposal always waits for the team (kind slot_to_confirm).
--   5. jtd_ops_board — slot_to_confirm kind, visit.ask, ask_channels; applied
--      as anchor rewrites (post-checked) so the 014 text stays the source.
-- APPLIED LIVE 2026-09-17 as 015a (1–3), 015b (4), 015c (5). Source of record.
-- Spec: specs/OPS-JTD-TOOLS-SPEC.md §4, §5, §11.
-- ============================================================================

-- ─── 1. The link grant + ask bookkeeping ────────────────────────────────────
ALTER TABLE public.t_appointments
  ADD COLUMN IF NOT EXISTS slot_token        uuid        NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS asked_at          timestamptz,
  ADD COLUMN IF NOT EXISTS ask_count         integer     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS customer_response jsonb;
CREATE UNIQUE INDEX IF NOT EXISTS ux_t_appointments_slot_token ON public.t_appointments (slot_token);
COMMENT ON COLUMN public.t_appointments.slot_token IS 'Unguessable grant for the public slot page /slot/:token (the check-in pattern). Rotated never; the appointment closing closes the page.';
COMMENT ON COLUMN public.t_appointments.customer_response IS '{action: accept|propose|decline, at, proposed_at?, note?} — the customer''s last answer on the public page. A propose waits for the team (board kind slot_to_confirm).';

-- ─── 2. Source type + template copy (provider ids registered by the owner) ──
INSERT INTO public.n_jtd_source_types
  (code, name, description, default_event_type, source_table, source_id_field, default_channels, is_active)
VALUES
  ('visit_slot_request', 'Visit slot request',
   'Ask the customer to confirm a proposed service-visit slot via the public page /slot/:token. source_id = the appointment.',
   'notification', 't_appointments', 'id', ARRAY['whatsapp','email']::varchar[], true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.n_jtd_templates
  (tenant_id, template_key, name, description, channel_code, source_type_code, subject, content, content_html, variables, provider_template_id, is_live, is_active)
SELECT NULL, 'visit_slot_request_whatsapp', 'Visit slot request (WhatsApp)',
       'Ask the customer to confirm a visit slot. POSITIONAL — register in MSG91 with {{1}}..{{5}} in this order, then set provider_template_id. Until then the tool offers Share only.',
       'whatsapp', 'visit_slot_request', NULL,
       'Hi {{customer_name}}, {{tenant_name}} would like to visit for {{service_name}} on {{slot_text}}. Tap to confirm or suggest another time: {{link}}',
       NULL, '["customer_name","tenant_name","service_name","slot_text","link"]'::jsonb, NULL, true, true
 WHERE NOT EXISTS (SELECT 1 FROM public.n_jtd_templates x WHERE x.template_key = 'visit_slot_request_whatsapp' AND x.tenant_id IS NULL);

INSERT INTO public.n_jtd_templates
  (tenant_id, template_key, name, description, channel_code, source_type_code, subject, content, content_html, variables, provider_template_id, is_live, is_active)
SELECT NULL, 'visit_slot_request_email', 'Visit slot request (email)',
       'Ask the customer to confirm a visit slot. MSG91 email needs a template id — register one with these variables, then set provider_template_id.',
       'email', 'visit_slot_request',
       'Confirm your service visit on {{slot_text}} — {{tenant_name}}',
       E'Hi {{customer_name}},\n\n{{tenant_name}} would like to visit for {{service_name}} on {{slot_text}}.\n\nPlease confirm, or suggest another time, here: {{link}}\n\nThank you,\n{{tenant_name}}',
       NULL, '[{"name":"customer_name","type":"string","required":true},{"name":"tenant_name","type":"string","required":true},{"name":"service_name","type":"string","required":true},{"name":"slot_text","type":"string","required":true},{"name":"link","type":"string","required":true}]'::jsonb,
       NULL, true, true
 WHERE NOT EXISTS (SELECT 1 FROM public.n_jtd_templates x WHERE x.template_key = 'visit_slot_request_email' AND x.tenant_id IS NULL);

-- ─── 3. Ask the customer ────────────────────────────────────────────────────
-- p_channel: share (no send — returns the message + link + phone/email for
-- wa.me / copy; still recorded), email, whatsapp (a communication row → the
-- existing trigger queues → the existing worker sends; needs a registered
-- provider template, else no_template). Proposes the planned visit date when
-- the open appointment has no time yet, so it is ONE tap from a scheduled visit.
CREATE OR REPLACE FUNCTION public.jtd_ask_visit_slot(
  p_tenant uuid, p_event_id uuid, p_channel text,
  p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_note text DEFAULT NULL, p_link_base text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e public.t_contract_events; v_ref jsonb; v_r record; v_res jsonb;
  v_appt uuid; v_appt_status text; v_appt_at timestamptz; v_appt_version integer; v_token uuid;
  v_email text; v_addr text; v_contract_number text; v_link text; v_slot_text text; v_service text;
  v_vars jsonb; v_msg jsonb; v_tpl_provider text; v_comm uuid;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR (p_actor_type = 'user' AND p_actor_id IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
  END IF;
  IF p_channel NOT IN ('share','email','whatsapp') THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_channel'); END IF;

  SELECT * INTO v_e FROM public.t_contract_events e
   WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  IF v_e.status = 'in_progress' THEN RETURN jsonb_build_object('success', false, 'reason', 'visit_in_progress'); END IF;

  -- the customer: the contract's buyer (never a group contract)
  SELECT * INTO v_r FROM public.svc_notif_recipient(p_tenant, v_e.contract_id);
  IF v_r.contact_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_customer'); END IF;
  IF v_r.is_group THEN RETURN jsonb_build_object('success', false, 'reason', 'group_contract'); END IF;
  SELECT NULLIF(TRIM(cc.value), '') INTO v_email FROM public.t_contact_channels cc
   WHERE cc.contact_id = v_r.contact_id AND cc.channel_type = 'email' AND NULLIF(TRIM(cc.value), '') IS NOT NULL
   ORDER BY cc.is_primary DESC NULLS LAST, cc.is_verified DESC NULLS LAST, cc.created_at LIMIT 1;
  SELECT c.contract_number INTO v_contract_number FROM public.t_contracts c WHERE c.id = v_e.contract_id;

  -- the slot: the event's open appointment, else a new one (closed ones retired first — one active per event)
  SELECT a.id, a.status, a.scheduled_at, a.version INTO v_appt, v_appt_status, v_appt_at, v_appt_version FROM public.t_appointments a
   WHERE a.event_id = p_event_id AND a.tenant_id = p_tenant AND a.is_active ORDER BY a.updated_at DESC LIMIT 1 FOR UPDATE;
  IF v_appt IS NOT NULL AND v_appt_status IN ('cancelled','declined','completed') THEN
    UPDATE public.t_appointments SET is_active = false, updated_by = p_actor_id, updated_at = now() WHERE id = v_appt;
    v_appt := NULL; v_appt_status := NULL; v_appt_at := NULL; v_appt_version := NULL;
  END IF;
  IF v_appt IS NULL THEN
    v_res := public.create_appointment(p_tenant, p_event_id, COALESCE(p_note, 'Slot proposed to the customer from Ops'), p_actor_id, p_actor_name);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_res->>'error', 'code', v_res->>'code');
    END IF;
    v_appt := (v_res->'data'->>'id')::uuid; v_appt_status := 'requested'; v_appt_at := NULL;
  END IF;
  IF v_appt_status = 'accepted' THEN RETURN jsonb_build_object('success', false, 'reason', 'already_confirmed', 'scheduled_at', v_appt_at); END IF;
  IF v_appt_at IS NULL THEN
    -- nothing proposed yet: propose the planned visit date (must still be ahead)
    IF v_e.scheduled_date IS NULL OR v_e.scheduled_date < now() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'slot_in_past', 'message', 'The planned date has passed — schedule a slot first');
    END IF;
    -- 10:00 IST on the planned day: event rows carry whatever clock time they were created with
    v_appt_at := (((v_e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date)::timestamp + time '10:00') AT TIME ZONE 'Asia/Kolkata';
    IF v_appt_at < now() THEN v_appt_at := v_e.scheduled_date; END IF;
    UPDATE public.t_appointments SET scheduled_at = v_appt_at, last_activity_at = now(), version = version + 1, updated_by = p_actor_id, updated_at = now() WHERE id = v_appt;
  END IF;
  SELECT a.slot_token INTO v_token FROM public.t_appointments a WHERE a.id = v_appt;

  v_service   := COALESCE(NULLIF(TRIM(v_e.block_name), ''), 'your equipment');
  v_slot_text := to_char(v_appt_at AT TIME ZONE 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM');
  v_link      := rtrim(COALESCE(NULLIF(TRIM(p_link_base), ''), 'https://app.contractnest.com'), '/') || '/slot/' || v_token::text;
  v_vars      := jsonb_build_object('customer_name', v_r.contact_name, 'tenant_name', v_r.tenant_name, 'service_name', v_service,
                                    'slot_text', v_slot_text, 'link', v_link);
  -- our copy, rendered (share uses the WhatsApp wording; the provider formats the real bytes on email/whatsapp)
  v_msg := public.jtd_render_message(p_tenant, 'visit_slot_request', CASE WHEN p_channel = 'email' THEN 'email' ELSE 'whatsapp' END, v_vars);

  IF p_channel IN ('email','whatsapp') THEN
    v_addr := CASE WHEN p_channel = 'email' THEN v_email ELSE v_r.phone END;
    IF v_addr IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_address', 'channel', p_channel); END IF;
    SELECT t.provider_template_id INTO v_tpl_provider FROM public.n_jtd_templates t
     WHERE t.source_type_code = 'visit_slot_request' AND t.channel_code = p_channel AND COALESCE(t.is_active, true)
       AND (t.tenant_id = p_tenant OR t.tenant_id IS NULL)
     ORDER BY (t.tenant_id IS NULL), t.version DESC NULLS LAST LIMIT 1;
    IF v_tpl_provider IS NULL THEN
      RETURN jsonb_build_object('success', false, 'reason', 'no_template', 'channel', p_channel,
                                'message', 'The ' || p_channel || ' template for slot requests is not registered yet — use Share');
    END IF;
    INSERT INTO public.n_jtd (
      tenant_id, event_type_code, channel_code, source_type_code, source_id, source_ref,
      recipient_type, recipient_id, recipient_name, recipient_contact,
      template_key, template_variables, payload, business_context, metadata,
      performed_by_type, performed_by_id, performed_by_name, is_live,
      contract_id, block_name, notes
    ) VALUES (
      p_tenant, 'notification', p_channel, 'visit_slot_request', v_appt, v_contract_number,
      'contact', v_r.contact_id, v_r.contact_name, v_addr,
      'visit_slot_request', v_vars,
      jsonb_build_object('recipient_data', jsonb_strip_nulls(jsonb_build_object('name', v_r.contact_name,
                           CASE WHEN p_channel = 'email' THEN 'email' ELSE 'phone' END, v_addr)),
                         'template_data', v_vars),
      jsonb_build_object('appointment_id', v_appt, 'event_id', p_event_id, 'contract_id', v_e.contract_id, 'scheduled_at', v_appt_at,
                         'note', p_note, 'origin', 'ops_tool'),
      '{}'::jsonb,
      p_actor_type, p_actor_id, p_actor_name, COALESCE(v_e.is_live, true),
      v_e.contract_id, v_e.block_name, p_note
    ) RETURNING id INTO v_comm;
  END IF;

  UPDATE public.t_appointments
     SET asked_at = now(), ask_count = ask_count + 1, last_activity_at = now(),
         notes = CASE WHEN p_note IS NULL THEN notes ELSE COALESCE(notes || ' · ', '') || p_note END,
         version = version + 1, updated_by = p_actor_id, updated_at = now()
   WHERE id = v_appt;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_slot_asked', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('appointment_id', v_appt, 'channel', p_channel, 'scheduled_at', v_appt_at, 'link', v_link, 'communication_id', v_comm),
                                 p_note, v_appt_at, NULL, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'channel', p_channel,
                            'scheduled_at', v_appt_at, 'slot_text', v_slot_text, 'link', v_link,
                            'message', v_msg, 'recipient_name', v_r.contact_name, 'phone', v_r.phone, 'email', v_email,
                            'communication_id', v_comm);
END;
$$;
COMMENT ON FUNCTION public.jtd_ask_visit_slot(uuid, uuid, text, text, uuid, text, text, text) IS
  'Ops tool: ask the customer to confirm the visit slot. share = message+link for wa.me/copy (recorded, nothing sent); email/whatsapp = communication row (needs a registered provider template). Proposes the planned date when no timed slot exists.';

-- ─── 4. The customer''s page: resolve + respond (PUBLIC, token-gated) ──────
CREATE OR REPLACE FUNCTION public.visit_slot_resolve(p_token uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v record; v_state text; v_first text;
BEGIN
  IF p_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  SELECT a.id, a.status, a.scheduled_at, a.customer_response, a.asked_at, a.assigned_to_name AS appt_tech,
         e.status AS event_status, e.scheduled_date, e.block_name, e.sequence_number, e.total_occurrences, e.assigned_to_name AS tech,
         c.contract_number, c.buyer_id, ct.name AS contact_name,
         tp.business_name, tp.logo_url, tp.business_phone, t.name AS tenant_name
    INTO v
    FROM public.t_appointments a
    JOIN public.t_contract_events e ON e.id = a.event_id
    JOIN public.t_contracts c ON c.id = a.contract_id
    LEFT JOIN public.t_contacts ct ON ct.id = c.buyer_id
    JOIN public.t_tenants t ON t.id = a.tenant_id
    LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = a.tenant_id
   WHERE a.slot_token = p_token;
  IF v.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  v_state := CASE
    WHEN v.event_status IN ('completed','cancelled') OR v.status IN ('completed','cancelled') THEN 'closed'
    WHEN v.event_status = 'in_progress' THEN 'in_progress'
    WHEN v.status = 'accepted' THEN 'confirmed'
    WHEN v.status = 'declined' THEN 'declined'
    WHEN v.status = 'rescheduled' AND v.customer_response->>'action' = 'propose' THEN 'proposed_by_you'
    ELSE 'proposed' END;
  v_first := NULLIF(split_part(TRIM(COALESCE(v.contact_name, '')), ' ', 1), '');

  RETURN jsonb_build_object(
    'ok', true, 'state', v_state,
    'can_respond', v_state IN ('proposed','proposed_by_you','confirmed','declined'),
    'business', jsonb_strip_nulls(jsonb_build_object('name', COALESCE(NULLIF(TRIM(v.business_name), ''), v.tenant_name), 'logo_url', v.logo_url, 'phone', v.business_phone)),
    'customer_first_name', v_first,
    'service_name', COALESCE(NULLIF(TRIM(v.block_name), ''), 'your equipment'),
    'visit', jsonb_strip_nulls(jsonb_build_object('sequence', v.sequence_number, 'of', v.total_occurrences)),
    'proposed_at', v.scheduled_at, 'technician_name', COALESCE(v.tech, v.appt_tech),
    'customer_response', v.customer_response, 'contract_number', v.contract_number);
END;
$$;

CREATE OR REPLACE FUNCTION public.visit_slot_respond(p_token uuid, p_action text, p_proposed_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v record; v_r jsonb; v_new_status text; v_resp jsonb; v_who text; v_appt uuid; v_version integer; v_at timestamptz; v_action text;
BEGIN
  IF p_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF p_action NOT IN ('accept','propose','decline') THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_action'); END IF;
  SELECT a.id, a.tenant_id, a.event_id, a.contract_id, a.status, a.scheduled_at, a.version, a.assigned_to, a.assigned_to_name,
         e.status AS event_status, e.scheduled_date, e.version AS event_version, c.buyer_id, ct.name AS contact_name
    INTO v
    FROM public.t_appointments a
    JOIN public.t_contract_events e ON e.id = a.event_id
    JOIN public.t_contracts c ON c.id = a.contract_id
    LEFT JOIN public.t_contacts ct ON ct.id = c.buyer_id
   WHERE a.slot_token = p_token FOR UPDATE OF a;
  IF v.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF v.event_status IN ('completed','cancelled') OR v.status IN ('completed','cancelled') THEN RETURN jsonb_build_object('ok', false, 'reason', 'visit_closed'); END IF;
  IF v.event_status = 'in_progress' THEN RETURN jsonb_build_object('ok', false, 'reason', 'visit_in_progress'); END IF;
  IF p_action = 'propose' AND (p_proposed_at IS NULL OR p_proposed_at < now()) THEN RETURN jsonb_build_object('ok', false, 'reason', 'slot_in_past'); END IF;
  IF p_action = 'accept' AND v.scheduled_at IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_slot'); END IF;

  v_who := 'Customer' || COALESCE(' · ' || NULLIF(TRIM(v.contact_name), ''), '') || ' (via link)';
  v_appt := v.id; v_version := v.version; v_at := v.scheduled_at;

  -- 'declined' is terminal in the appointment state machine: a change of mind gets a fresh appointment carrying the same slot
  IF v.status = 'declined' AND p_action IN ('accept','propose') THEN
    UPDATE public.t_appointments SET is_active = false, updated_at = now() WHERE id = v.id;
    v_r := public.create_appointment(v.tenant_id, v.event_id, 'Re-opened by the customer via link', NULL, v_who);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_appt := (v_r->'data'->>'id')::uuid;
    -- keep the link working: the new row inherits the token (old row is inactive)
    UPDATE public.t_appointments SET slot_token = gen_random_uuid() WHERE id = v.id;
    UPDATE public.t_appointments SET slot_token = p_token, scheduled_at = v.scheduled_at, assigned_to = v.assigned_to, assigned_to_name = v.assigned_to_name WHERE id = v_appt;
    SELECT a.version INTO v_version FROM public.t_appointments a WHERE a.id = v_appt;
    v.status := 'requested';
  END IF;

  IF p_action = 'accept' THEN
    IF v.status = 'accepted' THEN
      RETURN jsonb_build_object('ok', true, 'state', 'confirmed', 'scheduled_at', v.scheduled_at, 'already', true);
    END IF;
    v_resp := jsonb_build_object('action', 'accept', 'at', now(), 'note', p_note);
    v_r := public.update_appointment(v_appt, v.tenant_id, jsonb_build_object('status', 'accepted', 'scheduled_at', v_at), v_version, NULL, v_who);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_new_status := 'accepted'; v_action := 'visit_slot_accepted';
  ELSIF p_action = 'propose' THEN
    v_resp := jsonb_build_object('action', 'propose', 'at', now(), 'proposed_at', p_proposed_at, 'note', p_note);
    v_new_status := CASE WHEN v.status IN ('requested','accepted') THEN 'rescheduled' WHEN v.status = 'no_response' THEN 'requested' ELSE v.status END;
    v_r := public.update_appointment(v_appt, v.tenant_id, jsonb_build_object('status', v_new_status, 'scheduled_at', p_proposed_at), v_version, NULL, v_who);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_at := p_proposed_at; v_action := 'visit_slot_proposed';
  ELSE
    v_resp := jsonb_build_object('action', 'decline', 'at', now(), 'note', p_note);
    IF v.status <> 'declined' THEN
      v_r := public.update_appointment(v_appt, v.tenant_id, jsonb_build_object('status', 'declined'), v_version, NULL, v_who);
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    END IF;
    v_new_status := 'declined'; v_action := 'visit_slot_declined';
  END IF;

  UPDATE public.t_appointments SET customer_response = v_resp, last_activity_at = now(), updated_at = now() WHERE id = v_appt;
  PERFORM public.jtd__visit_note(v.tenant_id, v.event_id, v_action, 'customer', NULL, COALESCE(NULLIF(TRIM(v.contact_name), ''), 'Customer'),
                                 jsonb_build_object('appointment_id', v_appt, 'scheduled_at', v_at, 'note', p_note, 'via', 'slot_link'),
                                 p_note, CASE WHEN p_action = 'accept' THEN v_at ELSE NULL END, NULL, NULL, NULL);
  RETURN jsonb_build_object('ok', true,
    'state', CASE v_new_status WHEN 'accepted' THEN 'confirmed' WHEN 'declined' THEN 'declined' ELSE 'proposed_by_you' END,
    'scheduled_at', v_at, 'customer_response', v_resp);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', (substr(SQLERRM, 6)::jsonb)->>'code');
  END IF;
  RAISE;
END;
$$;
COMMENT ON FUNCTION public.visit_slot_resolve(uuid) IS 'PUBLIC (token = the grant): what the customer sees on /slot/:token. Never returns more than the visit, the slot and the business.';
COMMENT ON FUNCTION public.visit_slot_respond(uuid, text, timestamptz, text) IS 'PUBLIC (token = the grant): accept | propose | decline. accept → update_appointment accepted (moves the visit, existing confirmation notification); propose → rescheduled, waits for the team (board kind slot_to_confirm); decline → declined. Changing one''s mind after declining re-opens a fresh appointment on the same link.';

-- ─── 5. Board: slot_to_confirm · visit.ask · ask_channels (anchor rewrites) ──
-- The same edits are mirrored into 014's jtd_ops_board text so the file matches live.
DO $do$
DECLARE
  v_src text; v_n int; i int;
  v_old text[] := ARRAY[
    $a$SELECT x.id, x.status, x.scheduled_at FROM public.t_appointments x$a$,
    $a$a.id AS appt_id, a.status AS appt_status, a.scheduled_at AS appt_at,$a$,
    $a$ORDER BY x.updated_at DESC LIMIT 1) a ON true$a$,
    $a$CASE WHEN v.status = 'in_progress' OR v.ticket_status = 'in_progress' THEN 'visit_in_progress'$a$,
    $a$'ticket', CASE WHEN v.ticket_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.ticket_id, 'number', v.ticket_number, 'status', v.ticket_status) END)),$a$,
    $a$WHEN 'visit_in_progress' THEN 2 WHEN 'rung_due' THEN 3$a$,
    $a$'visit_overdue','visit_today','visit_in_progress')) AS needs_by_lane,$a$,
    $a$'happened', v_happened, 'team', v_team, 'ladder', v_ladder, 'generated_at', now());$a$];
  v_new text[] := ARRAY[
    $b$SELECT x.id, x.status, x.scheduled_at, x.asked_at, x.ask_count, x.customer_response FROM public.t_appointments x$b$,
    $b$a.id AS appt_id, a.status AS appt_status, a.scheduled_at AS appt_at, a.asked_at AS appt_asked_at, a.ask_count AS appt_ask_count, a.customer_response AS appt_response, d.customer_response AS declined_response,$b$,
    $b$ORDER BY x.updated_at DESC LIMIT 1) a ON true
      LEFT JOIN LATERAL (SELECT x.customer_response FROM public.t_appointments x WHERE x.event_id = e.id AND x.status = 'declined' AND x.customer_response IS NOT NULL ORDER BY x.updated_at DESC LIMIT 1) d ON true$b$,
    $b$CASE WHEN v.status = 'in_progress' OR v.ticket_status = 'in_progress' THEN 'visit_in_progress'
                WHEN v.appt_status = 'rescheduled' AND v.appt_response->>'action' = 'propose' THEN 'slot_to_confirm'$b$,
    $b$'ask', CASE WHEN v.appt_asked_at IS NULL AND v.appt_response IS NULL AND v.declined_response IS NULL THEN NULL
                          ELSE jsonb_strip_nulls(jsonb_build_object('asked_at', v.appt_asked_at, 'count', v.appt_ask_count, 'response', v.appt_response, 'declined', v.declined_response)) END,
             'ticket', CASE WHEN v.ticket_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.ticket_id, 'number', v.ticket_number, 'status', v.ticket_status) END)),$b$,
    $b$WHEN 'visit_in_progress' THEN 2 WHEN 'slot_to_confirm' THEN 2 WHEN 'rung_due' THEN 3$b$,
    $b$'visit_overdue','visit_today','visit_in_progress','slot_to_confirm')) AS needs_by_lane,$b$,
    $b$'happened', v_happened, 'team', v_team, 'ladder', v_ladder,
    'ask_channels', COALESCE((SELECT jsonb_agg(DISTINCT t.channel_code) FROM public.n_jtd_templates t
                               WHERE t.source_type_code = 'visit_slot_request' AND COALESCE(t.is_active, true) AND t.provider_template_id IS NOT NULL
                                 AND (t.tenant_id = p_tenant OR t.tenant_id IS NULL)), '[]'::jsonb),
    'generated_at', now());$b$];
BEGIN
  SELECT pg_get_functiondef('public.jtd_ops_board(uuid, boolean, jsonb, uuid)'::regprocedure) INTO v_src;
  IF position('slot_to_confirm' IN v_src) > 0 THEN RAISE EXCEPTION 'already applied'; END IF;
  FOR i IN 1..array_length(v_old, 1) LOOP
    v_n := (length(v_src) - length(replace(v_src, v_old[i], ''))) / length(v_old[i]);
    IF v_n <> 1 THEN RAISE EXCEPTION 'anchor % found % times, expected 1', i, v_n; END IF;
    v_src := replace(v_src, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_src;
  SELECT pg_get_functiondef('public.jtd_ops_board(uuid, boolean, jsonb, uuid)'::regprocedure) INTO v_src;
  IF position('ask_channels' IN v_src) = 0 OR position('declined_response' IN v_src) = 0 THEN RAISE EXCEPTION 'rewrite did not land'; END IF;
END $do$;
