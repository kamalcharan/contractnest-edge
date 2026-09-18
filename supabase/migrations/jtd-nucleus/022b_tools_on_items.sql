-- ═══════════════════════════════════════════════════════════════════
-- 022b — every existing entry point rewired onto the item tools (022a)
--
-- Rewritten in full (they locked t_appointments rows, which a view cannot
-- do): create_appointment · update_appointment (legacy API wrappers, same
-- signatures and result shapes) · jtd_schedule_visit · jtd_confirm_visit_slot
-- · jtd_ask_visit_slot · visit_slot_resolve · visit_slot_respond ·
-- jtd_buyer_respond_slot · jtd_escalate_payment_call (a follow-up is now an
-- item on the payment job, not a task row) · jtd_log_payment_call (closes
-- the open follow-up items) · jtd_tasks (reads the items, same output) ·
-- gs_schedule_assign (the chair lives on the occurrence; no appointment row).
-- Anchor-edited (post-checked): jtd_complete_visit · jtd_ops_board (open
-- follow-up + feed) · jtd_activity · jtd_contract_activity ·
-- get_appointments_list (+asked_at) · run_contract_event_scanner (STEP 2b,
-- the silent auto-request, removed) · reset_tenant_session_and_forms.
-- Untouched and still correct through the compatibility view (022c):
-- jtd_assign_visit · jtd_ops_board(_expense) slot columns ·
-- get_contract_events_list · get_vani_briefing · fn_enqueue_service_visit_scheduled.
-- Applied live 2026-09-17 (batch ops-items-on-jtd) — source of record.
-- ═══════════════════════════════════════════════════════════════════

-- ─── helper: the event follows an agreed slot (what update_appointment did on 'accepted') ──
CREATE OR REPLACE FUNCTION public.jtd__move_event(p_tenant uuid, p_event_id uuid, p_at timestamptz, p_by uuid, p_by_name text, p_reason text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_evt record;
BEGIN
  IF p_at IS NULL THEN RETURN false; END IF;
  SELECT id, status, scheduled_date INTO v_evt FROM public.t_contract_events WHERE id = p_event_id AND is_active = true FOR UPDATE;
  IF v_evt.id IS NULL OR v_evt.scheduled_date IS NOT DISTINCT FROM p_at THEN RETURN false; END IF;
  UPDATE public.t_contract_events SET scheduled_date = p_at, version = version + 1, updated_by = p_by, updated_at = now() WHERE id = v_evt.id;
  INSERT INTO public.t_contract_event_audit (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
  VALUES (v_evt.id, p_tenant, 'scheduled_date', v_evt.scheduled_date::text, p_at::text, p_by, COALESCE(p_by_name, 'Appointments'), p_reason);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd__rewrite_fn(p_name text, p_old text, p_new text, p_tag text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_oid oid; v_def text; v_n integer;
BEGIN
  SELECT p.oid INTO STRICT v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = p_name;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_n <> 1 THEN RAISE EXCEPTION '022 %: anchor found % times, expected 1', p_tag, v_n; END IF;
  EXECUTE replace(v_def, p_old, p_new);
  v_def := pg_get_functiondef(v_oid);
  IF position(p_new IN v_def) = 0 THEN RAISE EXCEPTION '022 %: rewrite did not land', p_tag; END IF;
END;
$$;

-- ─── legacy API wrappers (edge `appointments`, EventCard "Book appointment", jtd_assign_visit) ──
CREATE OR REPLACE FUNCTION public.create_appointment(p_tenant_id uuid, p_event_id uuid, p_notes text DEFAULT NULL, p_created_by uuid DEFAULT NULL, p_created_by_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_evt record; v_r jsonb; v_id uuid; v_at timestamptz;
BEGIN
  IF p_tenant_id IS NULL OR p_event_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'tenant_id and event_id are required'); END IF;
  SELECT e.id, e.tenant_id, e.contract_id, e.event_type, e.scheduled_date, e.is_live, e.status INTO v_evt
    FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant_id AND e.is_active = true;
  IF v_evt.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Event not found', 'code', 'NOT_FOUND'); END IF;
  IF v_evt.event_type <> 'service' THEN RETURN jsonb_build_object('success', false, 'error', 'Appointments apply to service events only', 'code', 'INVALID_EVENT_TYPE'); END IF;
  IF v_evt.status IN ('completed', 'cancelled') THEN RETURN jsonb_build_object('success', false, 'error', 'Event is already closed', 'code', 'INVALID_STATUS'); END IF;
  PERFORM public.jtd_ensure_visit_job(p_event_id);
  -- the planned date is the first proposal; a date already gone proposes nothing (Ask/Schedule set a real slot)
  v_at := CASE WHEN v_evt.scheduled_date >= now() - interval '1 day' THEN v_evt.scheduled_date END;
  v_r := public.jtd_item_add(p_tenant_id, p_event_id, 'appointment',
           jsonb_strip_nulls(jsonb_build_object('scheduled_at', v_at, 'proposed_by', 'us',
             'proposed_slots', jsonb_build_array(jsonb_build_object('slot', v_evt.scheduled_date, 'note', 'event date')), 'note', p_notes)),
           CASE WHEN p_created_by IS NOT NULL THEN 'user' ELSE 'system' END, p_created_by, p_created_by_name, p_notes, NULL, 'appointment_added');
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    IF v_r->>'reason' = 'slot_already_open' THEN
      RETURN jsonb_build_object('success', false, 'error', 'An active appointment already exists for this event', 'code', 'APPOINTMENT_EXISTS');
    END IF;
    RETURN jsonb_build_object('success', false, 'error', 'Failed to create appointment', 'details', v_r->>'reason', 'code', 'RPC_ERROR');
  END IF;
  v_id := (v_r->'item'->>'id')::uuid;
  INSERT INTO public.t_audit_log (tenant_id, entity_type, entity_id, contract_id, category, action, description, new_value, performed_by, performed_by_name)
  VALUES (p_tenant_id, 'appointment', v_id, v_evt.contract_id, 'status', 'appointment_requested', 'Appointment requested for service event',
          jsonb_build_object('event_id', p_event_id, 'status', 'requested'), p_created_by, p_created_by_name);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('id', v_id, 'status', 'requested'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to create appointment', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;

CREATE OR REPLACE FUNCTION public.update_appointment(p_appointment_id uuid, p_tenant_id uuid, p_payload jsonb, p_expected_version integer DEFAULT NULL, p_changed_by uuid DEFAULT NULL, p_changed_by_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job public.n_jtd%ROWTYPE; v_item jsonb; v_cur text; v_new text; v_at timestamptz; v_prev_at timestamptz;
  v_status_changed boolean; v_time_changed boolean; v_valid boolean; v_patch jsonb; v_r jsonb; v_action text;
BEGIN
  SELECT * INTO v_job FROM public.n_jtd j
   WHERE j.tenant_id = p_tenant_id AND j.appointments @> jsonb_build_array(jsonb_build_object('id', p_appointment_id::text)) FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Appointment not found', 'code', 'NOT_FOUND'); END IF;
  IF p_expected_version IS NOT NULL AND COALESCE(v_job.version, 1) <> p_expected_version THEN
    RETURN jsonb_build_object('success', false, 'error', 'Version conflict — appointment was modified by another user', 'code', 'VERSION_CONFLICT', 'current_version', COALESCE(v_job.version, 1));
  END IF;
  v_item := public.jtd_item_find(v_job.id, 'appointment', p_appointment_id);
  v_cur := public.jtd__appt_legacy_status(v_item->>'status');
  v_prev_at := (v_item->>'scheduled_at')::timestamptz;
  v_new := COALESCE(p_payload->>'status', v_cur);
  v_at := COALESCE((p_payload->>'scheduled_at')::timestamptz, v_prev_at);
  v_status_changed := v_new IS DISTINCT FROM v_cur;
  v_time_changed := v_at IS DISTINCT FROM v_prev_at;

  IF v_status_changed THEN
    v_valid := CASE
      WHEN v_cur = 'requested'   AND v_new IN ('accepted', 'declined', 'rescheduled', 'no_response') THEN true
      WHEN v_cur = 'accepted'    AND v_new IN ('completed', 'rescheduled', 'no_response', 'declined') THEN true
      WHEN v_cur = 'rescheduled' AND v_new IN ('accepted', 'declined', 'no_response')                THEN true
      WHEN v_cur = 'no_response' AND v_new IN ('requested', 'accepted', 'declined')                  THEN true
      WHEN v_cur IN ('completed', 'declined')                                                        THEN false
      ELSE false END;
    IF NOT v_valid THEN RETURN jsonb_build_object('success', false, 'error', format('Invalid transition: %s → %s', v_cur, v_new), 'code', 'INVALID_TRANSITION'); END IF;
    IF v_new = 'accepted' AND v_at IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'scheduled_at is required to accept an appointment', 'code', 'MISSING_SCHEDULED_AT'); END IF;
  END IF;
  IF NOT v_status_changed AND v_time_changed AND v_new = 'accepted' AND v_at IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'scheduled_at is required to accept an appointment', 'code', 'MISSING_SCHEDULED_AT');
  END IF;

  v_patch := jsonb_strip_nulls(jsonb_build_object('scheduled_at', v_at, 'proposed_slots', p_payload->'proposed_slots',
               'assigned_to', NULLIF(p_payload->>'assigned_to', '')::uuid, 'assigned_to_name', p_payload->>'assigned_to_name', 'note', p_payload->>'notes'));
  IF v_time_changed AND v_item->>'original_at' IS NULL AND v_prev_at IS NOT NULL THEN v_patch := v_patch || jsonb_build_object('original_at', v_prev_at); END IF;
  IF v_status_changed THEN
    v_patch := v_patch || jsonb_build_object('status', public.jtd__appt_item_status(v_new, (v_item->>'asked_at') IS NOT NULL));
    IF v_new IN ('completed', 'declined', 'cancelled', 'no_response') THEN
      v_patch := v_patch || jsonb_build_object('closed_at', now(), 'outcome', jsonb_strip_nulls(jsonb_build_object('code', v_new, 'at', now(), 'note', p_payload->>'notes',
                   'by', jsonb_strip_nulls(jsonb_build_object('type', CASE WHEN p_changed_by IS NOT NULL THEN 'user' ELSE 'system' END, 'id', p_changed_by, 'name', p_changed_by_name)))));
    END IF;
  END IF;
  v_action := CASE WHEN v_status_changed THEN 'appointment_status_changed' WHEN v_time_changed THEN 'appointment_rescheduled' ELSE 'appointment_updated' END;
  v_r := public.jtd_item_write(p_tenant_id, v_job.id, 'appointment', p_appointment_id, v_patch, v_action,
           CASE WHEN p_changed_by IS NOT NULL THEN 'user' ELSE 'system' END, p_changed_by, p_changed_by_name, p_payload->>'notes', NULL);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to update appointment', 'details', v_r->>'reason', 'code', 'RPC_ERROR');
  END IF;

  IF v_new = 'accepted' AND v_time_changed THEN
    PERFORM public.jtd__move_event(p_tenant_id, v_job.id, v_at, p_changed_by, p_changed_by_name,
      CASE WHEN v_status_changed THEN 'Auto: appointment accepted for this slot' ELSE 'Auto: appointment rescheduled to a new slot' END);
  END IF;
  IF v_status_changed AND v_new = 'accepted' THEN
    -- what trg_fn_notif_appointment_confirmed did on the table
    BEGIN PERFORM public.fn_enqueue_service_visit_scheduled(p_appointment_id);
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'notif visit_scheduled failed: %', SQLERRM; END;
  END IF;
  IF v_status_changed OR v_time_changed THEN
    INSERT INTO public.t_audit_log (tenant_id, entity_type, entity_id, contract_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
    VALUES (p_tenant_id, 'appointment', p_appointment_id, v_job.contract_id,
            CASE WHEN v_status_changed THEN 'status' ELSE 'schedule' END,
            CASE WHEN v_status_changed THEN 'appointment_status_changed' ELSE 'appointment_rescheduled' END,
            CASE WHEN v_status_changed THEN format('Appointment %s → %s', v_cur, v_new) ELSE format('Appointment rescheduled to %s', v_at) END,
            jsonb_build_object('status', v_cur, 'scheduled_at', v_prev_at), jsonb_build_object('status', v_new, 'scheduled_at', v_at),
            p_changed_by, p_changed_by_name);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('id', p_appointment_id, 'status', v_new, 'scheduled_at', v_at, 'version', (v_r->>'version')::integer));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to update appointment', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;

-- ─── Ops tools: schedule · confirm · ask ───────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_schedule_visit(
  p_tenant uuid, p_event_id uuid, p_scheduled_at timestamptz, p_confirmed boolean,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e public.t_contract_events; v_ref jsonb; v_r jsonb; v_open jsonb; v_appt uuid; v_prev text; v_new text; v_event_moved boolean := false;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  IF p_scheduled_at IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'scheduled_at_required'); END IF;
  IF p_scheduled_at < now() - interval '1 day' THEN RETURN jsonb_build_object('success', false, 'reason', 'slot_in_past'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  IF v_e.status = 'in_progress' THEN RETURN jsonb_build_object('success', false, 'reason', 'visit_in_progress'); END IF;
  PERFORM public.jtd_ensure_visit_job(p_event_id);
  PERFORM 1 FROM public.n_jtd WHERE id = p_event_id FOR UPDATE;

  v_open := public.jtd_item_open(p_event_id, 'appointment');
  IF v_open IS NULL THEN
    v_new := CASE WHEN p_confirmed THEN 'confirmed' ELSE 'proposed' END;
    v_r := public.jtd_item_add(p_tenant, p_event_id, 'appointment',
             jsonb_strip_nulls(jsonb_build_object('scheduled_at', p_scheduled_at, 'status', v_new, 'proposed_by', 'us',
               'proposed_slots', jsonb_build_array(jsonb_build_object('slot', p_scheduled_at, 'note', 'proposed from Ops')),
               'assigned_to', v_e.assigned_to, 'assigned_to_name', v_e.assigned_to_name, 'note', p_note)),
             p_actor_type, p_actor_id, p_actor_name, p_note, NULL, CASE WHEN p_confirmed THEN 'appointment_confirmed' ELSE 'appointment_added' END);
  ELSE
    v_prev := v_open->>'status';
    v_new := CASE WHEN p_confirmed THEN 'confirmed'            -- any open state → confirmed
                  WHEN v_prev = 'confirmed' THEN 'proposed'     -- a confirmed slot is being moved: back to unconfirmed
                  ELSE v_prev END;                              -- proposed / asked / customer_proposed keep their state, the time changes
    IF (v_open->>'scheduled_at')::timestamptz IS DISTINCT FROM p_scheduled_at THEN
      v_r := public.jtd_item_reschedule(p_tenant, p_event_id, 'appointment', (v_open->>'id')::uuid, p_scheduled_at, p_note,
               p_actor_type, p_actor_id, p_actor_name, CASE WHEN v_new <> v_prev THEN v_new END, NULL,
               CASE WHEN p_confirmed THEN 'appointment_confirmed' ELSE 'appointment_rescheduled' END);
    ELSIF v_new <> v_prev THEN
      v_r := public.jtd_item_write(p_tenant, p_event_id, 'appointment', (v_open->>'id')::uuid,
               jsonb_strip_nulls(jsonb_build_object('status', v_new, 'proposed_by', 'us', 'note', p_note)),
               CASE WHEN p_confirmed THEN 'appointment_confirmed' ELSE 'appointment_updated' END, p_actor_type, p_actor_id, p_actor_name, p_note, NULL);
    ELSE
      v_r := jsonb_build_object('success', true, 'item', v_open);
    END IF;
  END IF;
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason', 'code', v_r->>'reason');
  END IF;
  v_appt := (v_r->'item'->>'id')::uuid;

  -- the event follows the slot, proposed or agreed, so the card sits in the right column
  IF v_e.scheduled_date IS DISTINCT FROM p_scheduled_at THEN
    v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('scheduled_date', p_scheduled_at), v_e.version, p_actor_id, p_actor_name,
             COALESCE(p_note, CASE WHEN p_confirmed THEN 'Slot confirmed from Ops' ELSE 'Slot proposed from Ops — awaiting customer confirmation' END));
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_event_moved := true;
  END IF;
  IF p_confirmed AND v_prev IS DISTINCT FROM 'confirmed' THEN
    BEGIN PERFORM public.fn_enqueue_service_visit_scheduled(v_appt);
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'notif visit_scheduled failed: %', SQLERRM; END;
  END IF;

  PERFORM public.jtd__visit_note(p_tenant, p_event_id, CASE WHEN p_confirmed THEN 'visit_slot_confirmed' ELSE 'visit_scheduled' END,
                                 p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('appointment_id', v_appt, 'scheduled_at', p_scheduled_at, 'confirmed', p_confirmed, 'previous', v_e.scheduled_date, 'appointment_status', public.jtd__appt_legacy_status(v_new)),
                                 p_note, p_scheduled_at, NULL, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'appointment_status', public.jtd__appt_legacy_status(v_new),
                            'item_status', v_new, 'scheduled_at', p_scheduled_at, 'confirmed', p_confirmed, 'event_moved', v_event_moved OR p_confirmed);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', COALESCE((substr(SQLERRM, 6)::jsonb)->>'code', (substr(SQLERRM, 6)::jsonb)->>'error_code'));
  END IF;
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_confirm_visit_slot(
  p_tenant uuid, p_event_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_open jsonb; v_r jsonb; v_at timestamptz; v_appt uuid;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  PERFORM 1 FROM public.n_jtd WHERE id = p_event_id FOR UPDATE;
  v_open := public.jtd_item_open(p_event_id, 'appointment');
  IF v_open IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_slot_to_confirm'); END IF;
  v_at := (v_open->>'scheduled_at')::timestamptz; v_appt := (v_open->>'id')::uuid;
  IF v_open->>'status' = 'confirmed' THEN RETURN jsonb_build_object('success', false, 'reason', 'already_confirmed', 'scheduled_at', v_at); END IF;
  IF v_at IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_slot_to_confirm'); END IF;
  v_r := public.jtd_item_write(p_tenant, p_event_id, 'appointment', v_appt, jsonb_strip_nulls(jsonb_build_object('status', 'confirmed', 'note', p_note)),
           'appointment_confirmed', p_actor_type, p_actor_id, p_actor_name, p_note, NULL);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason', 'code', v_r->>'reason'); END IF;
  PERFORM public.jtd__move_event(p_tenant, p_event_id, v_at, p_actor_id, p_actor_name, 'Auto: appointment accepted for this slot');
  BEGIN PERFORM public.fn_enqueue_service_visit_scheduled(v_appt);
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'notif visit_scheduled failed: %', SQLERRM; END;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_slot_confirmed', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('appointment_id', v_appt, 'scheduled_at', v_at, 'confirmed', true), p_note, v_at, NULL, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'scheduled_at', v_at, 'appointment_status', 'accepted', 'item_status', 'confirmed');
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_ask_visit_slot(
  p_tenant uuid, p_event_id uuid, p_channel text,
  p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_note text DEFAULT NULL, p_link_base text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e public.t_contract_events; v_ref jsonb; v_r record; v_res jsonb; v_open jsonb;
  v_appt uuid; v_appt_at timestamptz; v_token uuid;
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

  SELECT * INTO v_r FROM public.svc_notif_recipient(p_tenant, v_e.contract_id);
  IF v_r.contact_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_customer'); END IF;
  IF v_r.is_group THEN RETURN jsonb_build_object('success', false, 'reason', 'group_contract'); END IF;
  SELECT NULLIF(TRIM(cc.value), '') INTO v_email FROM public.t_contact_channels cc
   WHERE cc.contact_id = v_r.contact_id AND cc.channel_type = 'email' AND NULLIF(TRIM(cc.value), '') IS NOT NULL
   ORDER BY cc.is_primary DESC NULLS LAST, cc.is_verified DESC NULLS LAST, cc.created_at LIMIT 1;
  SELECT c.contract_number INTO v_contract_number FROM public.t_contracts c WHERE c.id = v_e.contract_id;

  PERFORM public.jtd_ensure_visit_job(p_event_id);
  PERFORM 1 FROM public.n_jtd WHERE id = p_event_id FOR UPDATE;
  v_open := public.jtd_item_open(p_event_id, 'appointment');
  IF v_open IS NOT NULL AND v_open->>'status' = 'confirmed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'already_confirmed', 'scheduled_at', v_open->'scheduled_at');
  END IF;
  v_appt_at := (v_open->>'scheduled_at')::timestamptz;
  IF v_appt_at IS NULL THEN
    -- nothing proposed yet: propose 10:00 IST on the planned day (event rows carry their creation clock time); the day must still be ahead
    IF v_e.scheduled_date IS NULL OR v_e.scheduled_date < now() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'slot_in_past', 'message', 'The planned date has passed — schedule a slot first');
    END IF;
    v_appt_at := (((v_e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date)::timestamp + time '10:00') AT TIME ZONE 'Asia/Kolkata';
    IF v_appt_at < now() THEN v_appt_at := v_e.scheduled_date; END IF;
  END IF;
  v_token := COALESCE((v_open->>'token')::uuid, gen_random_uuid());
  IF v_open IS NULL THEN
    v_res := public.jtd_item_add(p_tenant, p_event_id, 'appointment',
               jsonb_strip_nulls(jsonb_build_object('scheduled_at', v_appt_at, 'status', 'proposed', 'proposed_by', 'us', 'token', v_token,
                 'proposed_slots', jsonb_build_array(jsonb_build_object('slot', v_appt_at, 'note', 'proposed to the customer')),
                 'assigned_to', v_e.assigned_to, 'assigned_to_name', v_e.assigned_to_name, 'note', COALESCE(p_note, 'Slot proposed to the customer from Ops'))),
               p_actor_type, p_actor_id, p_actor_name, p_note, NULL, 'appointment_added');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_res->>'reason', 'code', v_res->>'reason'); END IF;
    v_open := v_res->'item';
  END IF;
  v_appt := (v_open->>'id')::uuid;

  v_service   := COALESCE(NULLIF(TRIM(v_e.block_name), ''), 'your equipment');
  v_slot_text := to_char(v_appt_at AT TIME ZONE 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM');
  v_link      := rtrim(COALESCE(NULLIF(TRIM(p_link_base), ''), 'https://app.contractnest.com'), '/') || '/slot/' || v_token::text;
  v_vars      := jsonb_build_object('customer_name', v_r.contact_name, 'tenant_name', v_r.tenant_name, 'service_name', v_service,
                                    'slot_text', v_slot_text, 'link', v_link);
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

  v_res := public.jtd_item_write(p_tenant, p_event_id, 'appointment', v_appt,
             jsonb_strip_nulls(jsonb_build_object('asked_at', now(), 'ask_count', COALESCE((v_open->>'ask_count')::integer, 0) + 1, 'token', v_token,
               'scheduled_at', v_appt_at, 'status', CASE WHEN v_open->>'status' = 'proposed' THEN 'asked' ELSE v_open->>'status' END,
               'note', CASE WHEN p_note IS NULL THEN NULL ELSE COALESCE((v_open->>'note') || ' · ', '') || p_note END)),
             'appointment_asked', p_actor_type, p_actor_id, p_actor_name, p_note, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_res->>'reason'); END IF;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_slot_asked', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('appointment_id', v_appt, 'channel', p_channel, 'scheduled_at', v_appt_at, 'link', v_link, 'communication_id', v_comm),
                                 p_note, v_appt_at, NULL, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'channel', p_channel,
                            'scheduled_at', v_appt_at, 'slot_text', v_slot_text, 'link', v_link,
                            'message', v_msg, 'recipient_name', v_r.contact_name, 'phone', v_r.phone, 'email', v_email,
                            'communication_id', v_comm);
END;
$$;

-- ─── the customer''s page (PUBLIC, token = the grant) ───────────────
CREATE OR REPLACE FUNCTION public.visit_slot_resolve(p_token uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v record; v_state text; v_first text; v_it jsonb; v_status text;
BEGIN
  IF p_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  SELECT j.id, j.tenant_id, x.it,
         e.status AS event_status, e.scheduled_date, e.block_name, e.sequence_number, e.total_occurrences, e.assigned_to_name AS tech,
         c.contract_number, c.buyer_id, ct.name AS contact_name,
         tp.business_name, tp.logo_url, tp.business_phone, t.name AS tenant_name
    INTO v
    FROM public.n_jtd j
    CROSS JOIN LATERAL (SELECT e AS it FROM jsonb_array_elements(j.appointments) e WHERE e->>'token' = p_token::text LIMIT 1) x
    JOIN public.t_contract_events e ON e.id = j.id
    JOIN public.t_contracts c ON c.id = j.contract_id
    LEFT JOIN public.t_contacts ct ON ct.id = c.buyer_id
    JOIN public.t_tenants t ON t.id = j.tenant_id
    LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = j.tenant_id
   WHERE j.appointments @> jsonb_build_array(jsonb_build_object('token', p_token::text))
   LIMIT 1;
  IF v.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  v_it := v.it; v_status := v_it->>'status';

  v_state := CASE
    WHEN v.event_status IN ('completed','cancelled') OR v_status IN ('completed','cancelled','no_show','no_response') THEN 'closed'
    WHEN v.event_status = 'in_progress' THEN 'in_progress'
    WHEN v_status = 'confirmed' THEN 'confirmed'
    WHEN v_status = 'declined' THEN 'declined'
    WHEN v_status = 'customer_proposed' THEN 'proposed_by_you'
    ELSE 'proposed' END;
  v_first := NULLIF(split_part(TRIM(COALESCE(v.contact_name, '')), ' ', 1), '');

  RETURN jsonb_build_object(
    'ok', true, 'state', v_state,
    'can_respond', v_state IN ('proposed','proposed_by_you','confirmed','declined'),
    'business', jsonb_strip_nulls(jsonb_build_object('name', COALESCE(NULLIF(TRIM(v.business_name), ''), v.tenant_name), 'logo_url', v.logo_url, 'phone', v.business_phone)),
    'customer_first_name', v_first,
    'service_name', COALESCE(NULLIF(TRIM(v.block_name), ''), 'your equipment'),
    'visit', jsonb_strip_nulls(jsonb_build_object('sequence', v.sequence_number, 'of', v.total_occurrences)),
    'proposed_at', (v_it->>'scheduled_at')::timestamptz, 'technician_name', COALESCE(v.tech, v_it->>'assigned_to_name'),
    'customer_response', v_it->'customer_response', 'contract_number', v.contract_number);
END;
$$;

CREATE OR REPLACE FUNCTION public.visit_slot_respond(p_token uuid, p_action text, p_proposed_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job public.n_jtd%ROWTYPE; v_it jsonb; v_e record; v_r jsonb; v_resp jsonb; v_who text; v_appt uuid; v_at timestamptz; v_status text; v_action text; v_new text; v_contact text;
BEGIN
  IF p_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF p_action NOT IN ('accept','propose','decline') THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_action'); END IF;
  SELECT * INTO v_job FROM public.n_jtd j WHERE j.appointments @> jsonb_build_array(jsonb_build_object('token', p_token::text)) FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  SELECT e INTO v_it FROM jsonb_array_elements(v_job.appointments) e WHERE e->>'token' = p_token::text LIMIT 1;
  SELECT e.status AS event_status, e.scheduled_date, e.version INTO v_e FROM public.t_contract_events e WHERE e.id = v_job.id;
  SELECT ct.name INTO v_contact FROM public.t_contracts c LEFT JOIN public.t_contacts ct ON ct.id = c.buyer_id WHERE c.id = v_job.contract_id;
  v_status := v_it->>'status'; v_appt := (v_it->>'id')::uuid; v_at := (v_it->>'scheduled_at')::timestamptz;

  IF v_e.event_status IN ('completed','cancelled') OR v_status IN ('completed','cancelled','no_show','no_response') THEN RETURN jsonb_build_object('ok', false, 'reason', 'visit_closed'); END IF;
  IF v_e.event_status = 'in_progress' THEN RETURN jsonb_build_object('ok', false, 'reason', 'visit_in_progress'); END IF;
  IF p_action = 'propose' AND (p_proposed_at IS NULL OR p_proposed_at < now()) THEN RETURN jsonb_build_object('ok', false, 'reason', 'slot_in_past'); END IF;
  IF p_action = 'accept' AND v_at IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_slot'); END IF;

  v_who := 'Customer' || COALESCE(' · ' || NULLIF(TRIM(v_contact), ''), '') || ' (via link)';

  -- declined is terminal: a change of mind gets a fresh item carrying the same slot and the same link
  IF v_status = 'declined' AND p_action IN ('accept','propose') THEN
    v_r := public.jtd_item_write(v_job.tenant_id, v_job.id, 'appointment', v_appt, jsonb_build_object('token', gen_random_uuid()), 'appointment_updated', 'customer', NULL, v_who, 'link re-used by a new slot', NULL);
    v_r := public.jtd_item_add(v_job.tenant_id, v_job.id, 'appointment',
             jsonb_strip_nulls(jsonb_build_object('scheduled_at', v_at, 'status', 'proposed', 'proposed_by', 'us', 'token', p_token,
               'assigned_to', v_it->'assigned_to', 'assigned_to_name', v_it->'assigned_to_name', 'note', 'Re-opened by the customer via link')),
             'customer', NULL, v_who, NULL, NULL, 'appointment_added');
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN jsonb_build_object('ok', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason'); END IF;
    v_it := v_r->'item'; v_appt := (v_it->>'id')::uuid; v_status := 'proposed';
  END IF;

  IF p_action = 'accept' THEN
    IF v_status = 'confirmed' THEN RETURN jsonb_build_object('ok', true, 'state', 'confirmed', 'scheduled_at', v_at, 'already', true); END IF;
    v_resp := jsonb_build_object('action', 'accept', 'at', now(), 'note', p_note);
    v_r := public.jtd_item_write(v_job.tenant_id, v_job.id, 'appointment', v_appt, jsonb_build_object('status', 'confirmed', 'customer_response', v_resp),
             'appointment_confirmed', 'customer', NULL, v_who, p_note, NULL);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN jsonb_build_object('ok', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason'); END IF;
    PERFORM public.jtd__move_event(v_job.tenant_id, v_job.id, v_at, NULL, v_who, 'Auto: appointment accepted for this slot');
    BEGIN PERFORM public.fn_enqueue_service_visit_scheduled(v_appt);
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'notif visit_scheduled failed: %', SQLERRM; END;
    v_new := 'confirmed'; v_action := 'visit_slot_accepted';
  ELSIF p_action = 'propose' THEN
    v_resp := jsonb_build_object('action', 'propose', 'at', now(), 'proposed_at', p_proposed_at, 'note', p_note);
    v_r := public.jtd_item_reschedule(v_job.tenant_id, v_job.id, 'appointment', v_appt, p_proposed_at, p_note, 'customer', NULL, v_who, 'customer_proposed', NULL, 'appointment_rescheduled');
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN jsonb_build_object('ok', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason'); END IF;
    v_r := public.jtd_item_write(v_job.tenant_id, v_job.id, 'appointment', v_appt, jsonb_build_object('proposed_by', 'customer', 'customer_response', v_resp), 'appointment_updated', 'customer', NULL, v_who, NULL, NULL);
    v_at := p_proposed_at; v_new := 'customer_proposed'; v_action := 'visit_slot_proposed';
  ELSE
    v_resp := jsonb_build_object('action', 'decline', 'at', now(), 'note', p_note);
    IF v_status <> 'declined' THEN
      v_r := public.jtd_item_write(v_job.tenant_id, v_job.id, 'appointment', v_appt,
               jsonb_build_object('status', 'declined', 'customer_response', v_resp, 'closed_at', now(),
                 'outcome', jsonb_strip_nulls(jsonb_build_object('code', 'declined', 'note', p_note, 'at', now(), 'by', jsonb_build_object('type', 'customer', 'name', v_who)))),
               'appointment_closed', 'customer', NULL, v_who, p_note, NULL);
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN jsonb_build_object('ok', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason'); END IF;
    END IF;
    v_new := 'declined'; v_action := 'visit_slot_declined';
  END IF;

  PERFORM public.jtd__visit_note(v_job.tenant_id, v_job.id, v_action, 'customer', NULL, COALESCE(NULLIF(TRIM(v_contact), ''), 'Customer'),
                                 jsonb_build_object('appointment_id', v_appt, 'scheduled_at', v_at, 'note', p_note, 'via', 'slot_link'),
                                 p_note, CASE WHEN p_action = 'accept' THEN v_at ELSE NULL END, NULL, NULL, NULL);
  RETURN jsonb_build_object('ok', true,
    'state', CASE v_new WHEN 'confirmed' THEN 'confirmed' WHEN 'declined' THEN 'declined' ELSE 'proposed_by_you' END,
    'scheduled_at', v_at, 'customer_response', v_resp);
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_buyer_respond_slot(p_tenant uuid, p_appointment_id uuid, p_action text, p_proposed_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_job public.n_jtd%ROWTYPE; v_it jsonb; v_tok uuid; v_r jsonb;
BEGIN
  IF p_tenant IS NULL OR p_appointment_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_request'); END IF;
  IF p_action NOT IN ('accept','propose','decline') THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_action'); END IF;
  -- the appointment belongs to a contract this tenant claimed (never the seller of its own contract)
  SELECT j.* INTO v_job
    FROM public.n_jtd j JOIN public.t_contracts c ON c.id = j.contract_id
   WHERE j.appointments @> jsonb_build_array(jsonb_build_object('id', p_appointment_id::text)) AND c.tenant_id <> p_tenant
     AND (c.buyer_tenant_id = p_tenant
          OR EXISTS (SELECT 1 FROM public.t_contract_access g WHERE g.contract_id = c.id AND g.accessor_tenant_id = p_tenant AND g.is_active))
   FOR UPDATE OF j;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'reason', 'not_your_contract'); END IF;
  v_it := public.jtd_item_find(v_job.id, 'appointment', p_appointment_id);
  v_tok := (v_it->>'token')::uuid;
  IF v_tok IS NULL THEN
    v_tok := gen_random_uuid();
    v_r := public.jtd_item_write(v_job.tenant_id, v_job.id, 'appointment', p_appointment_id, jsonb_build_object('token', v_tok), 'appointment_updated', 'system', NULL, 'Buyer workspace', 'slot link minted for the buyer', NULL);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_r->>'reason'); END IF;
  END IF;
  v_r := public.visit_slot_respond(v_tok, p_action, p_proposed_at, p_note);
  RETURN jsonb_build_object('success', COALESCE((v_r->>'ok')::boolean, false)) || (v_r - 'ok');
END;
$$;

-- ─── follow-ups: escalate (a follow-up IS an item on the payment job) · log a call closes them ──
CREATE OR REPLACE FUNCTION public.jtd_escalate_payment_call(
  p_tenant uuid, p_job_id uuid, p_assign_to uuid, p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_note text DEFAULT NULL, p_due_at timestamptz DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job public.n_jtd%ROWTYPE; v_assignee text; v_rung record; v_rung_no integer := 0; v_next timestamptz; v_r jsonb;
  v_due timestamptz := COALESCE(p_due_at, now());
  v_kind text := CASE WHEN p_actor_type = 'user' AND p_assign_to = p_actor_id THEN 'follow_up' ELSE 'escalation' END;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  IF p_due_at IS NOT NULL AND p_due_at < now() - interval '1 day' THEN RETURN jsonb_build_object('success', false, 'reason', 'due_in_past'); END IF;
  SELECT * INTO v_job FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment' FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'job_not_found'); END IF;
  IF v_job.status_code NOT IN ('scheduled','due','overdue','partial_payment') THEN RETURN jsonb_build_object('success', false, 'reason', 'job_not_open', 'status', v_job.status_code); END IF;
  SELECT COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email) INTO v_assignee
    FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND ut.user_id = p_assign_to LIMIT 1;
  IF v_assignee IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'assignee_not_in_tenant'); END IF;

  SELECT r.step INTO v_rung FROM public.jtd_ladder_rungs(p_tenant) r
   WHERE r.step = v_job.dunning_step + 1 AND r.channel = 'call' AND public.jtd_rung_due_at(v_job.scheduled_at, r.after_days) <= now();
  v_rung_no := COALESCE(v_rung.step, 0);

  v_r := public.jtd_item_add(p_tenant, p_job_id, 'followup',
           jsonb_strip_nulls(jsonb_build_object('kind', v_kind, 'scheduled_at', v_due, 'assigned_to', p_assign_to, 'assigned_to_name', v_assignee,
             'note', p_note, 'rung', v_rung_no, 'origin', 'collections_tool')),
           p_actor_type, p_actor_id, p_actor_name, p_note, NULL, CASE WHEN v_kind = 'follow_up' THEN 'follow_up_set' ELSE 'escalated' END);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RETURN v_r; END IF;

  UPDATE public.n_jtd SET dunning_step = GREATEST(dunning_step, v_rung_no), version = COALESCE(version, 0) + 1, updated_at = now() WHERE id = p_job_id;
  v_next := public.jtd_recompute_dunning(p_job_id);

  RETURN jsonb_build_object('success', true, 'task_jtd_id', (v_r->'item'->>'id')::uuid, 'item_id', (v_r->'item'->>'id')::uuid, 'item', v_r->'item',
                            'assigned_to', p_assign_to, 'assigned_to_name', v_assignee, 'rung', v_rung_no, 'next_dunning_at', v_next,
                            'task_kind', v_kind, 'due_at', v_due, 'version', v_r->'version');
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_log_payment_call(
  p_tenant uuid, p_job_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_called_at timestamptz, p_outcome text, p_notes text DEFAULT NULL, p_promise_date date DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job public.n_jtd%ROWTYPE; v_contract record; v_rung record; v_rung_no integer := 0; v_row uuid; v_closed integer := 0; v_next timestamptz; v_open jsonb; v_r jsonb;
BEGIN
  IF p_outcome NOT IN ('reached','no_answer','promised','disputed','other') THEN RETURN jsonb_build_object('success', false, 'reason', 'invalid_outcome'); END IF;
  IF p_outcome = 'promised' AND p_promise_date IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'promise_date_required'); END IF;
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_job FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment' FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'job_not_found'); END IF;
  SELECT c.contract_number, c.buyer_id, c.buyer_name INTO v_contract FROM public.t_contracts c WHERE c.id = v_job.contract_id;

  SELECT r.step INTO v_rung FROM public.jtd_ladder_rungs(p_tenant) r
   WHERE r.step = v_job.dunning_step + 1 AND r.channel = 'call' AND public.jtd_rung_due_at(v_job.scheduled_at, r.after_days) <= now();
  v_rung_no := COALESCE(v_rung.step, 0);

  -- the call itself stays a record row (the feed / activity show it under calls)
  INSERT INTO public.n_jtd (
    tenant_id, event_type_code, channel_code, source_type_code, source_id, source_ref,
    recipient_type, recipient_id, recipient_name,
    status_code, completed_at, executed_at, scheduled_at,
    assigned_to, assigned_to_name, notes, business_context, metadata,
    performed_by_type, performed_by_id, performed_by_name, is_live,
    contract_id, block_id, block_name, invoice_id, amount, currency, dunning_step
  ) VALUES (
    p_tenant, 'task', NULL, 'payment_call_logged', p_job_id, v_contract.contract_number,
    'contact', v_contract.buyer_id, v_contract.buyer_name,
    'completed', COALESCE(p_called_at, now()), COALESCE(p_called_at, now()), COALESCE(p_called_at, now()),
    CASE WHEN p_actor_type = 'user' THEN p_actor_id END, CASE WHEN p_actor_type = 'user' THEN p_actor_name END,
    p_notes,
    jsonb_build_object('job_id', p_job_id, 'contract_id', v_job.contract_id, 'invoice_id', v_job.invoice_id,
                       'outcome', p_outcome, 'promise_date', p_promise_date, 'rung', v_rung_no, 'origin', 'collections_tool'),
    jsonb_build_object('outcome', p_outcome),
    p_actor_type, p_actor_id, p_actor_name, COALESCE(v_job.is_live, true),
    v_job.contract_id, v_job.block_id, v_job.block_name, v_job.invoice_id,
    GREATEST(COALESCE(v_job.amount,0) - COALESCE(v_job.amount_settled,0), 0), v_job.currency, 0
  ) RETURNING id INTO v_row;

  -- a logged call closes every open follow-up / escalation on this payment
  LOOP
    v_open := public.jtd_item_open(p_job_id, 'followup');
    EXIT WHEN v_open IS NULL;
    v_r := public.jtd_item_close(p_tenant, p_job_id, 'followup', (v_open->>'id')::uuid, p_outcome, p_actor_type, p_actor_id, p_actor_name,
             COALESCE(p_notes, 'Closed by call log'), NULL, 'followup_closed');
    EXIT WHEN NOT COALESCE((v_r->>'success')::boolean, false);
    v_closed := v_closed + 1;
  END LOOP;

  UPDATE public.n_jtd
     SET nudge_count = nudge_count + 1, last_nudge_at = COALESCE(p_called_at, now()), dunning_step = GREATEST(dunning_step, v_rung_no),
         dunning_paused_reason = CASE p_outcome WHEN 'promised' THEN 'promise' WHEN 'disputed' THEN 'dispute' ELSE dunning_paused_reason END,
         promise_date = CASE p_outcome WHEN 'promised' THEN p_promise_date ELSE promise_date END,
         notes = COALESCE(p_notes, notes), version = COALESCE(version, 0) + 1, updated_at = now()
   WHERE id = p_job_id;
  v_next := public.jtd_recompute_dunning(p_job_id);

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, 'call_logged', p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('outcome', p_outcome, 'promise_date', p_promise_date, 'rung', v_rung_no, 'call_jtd_id', v_row, 'closed_call_tasks', v_closed),
          p_notes, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'call_jtd_id', v_row, 'outcome', p_outcome, 'rung', v_rung_no, 'closed_call_tasks', v_closed,
                            'paused_reason', CASE p_outcome WHEN 'promised' THEN 'promise' WHEN 'disputed' THEN 'dispute' ELSE v_job.dunning_paused_reason END,
                            'next_dunning_at', v_next);
END;
$$;

-- ─── the register''s Follow-ups reader, on the items (same output shape as 017) ──
CREATE OR REPLACE FUNCTION public.jtd_tasks(p_tenant uuid, p_is_live boolean DEFAULT true, p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_from date; v_to date; v_tmp date; v_who uuid; v_kind text; v_state text; v_q text; v_limit integer; v_offset integer;
  v_out jsonb; v_team jsonb;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'tenant_required'); END IF;
  p_filters := COALESCE(p_filters, '{}'::jsonb);
  BEGIN v_from := NULLIF(p_filters->>'from','')::date; EXCEPTION WHEN others THEN v_from := NULL; END;
  BEGIN v_to   := NULLIF(p_filters->>'to','')::date;   EXCEPTION WHEN others THEN v_to := NULL; END;
  IF v_from IS NOT NULL AND v_to IS NOT NULL AND v_to < v_from THEN v_tmp := v_from; v_from := v_to; v_to := v_tmp; END IF;
  BEGIN v_who := NULLIF(p_filters->>'who','')::uuid; EXCEPTION WHEN others THEN v_who := NULL; END;
  v_kind  := CASE WHEN p_filters->>'kind' IN ('follow_up','escalation') THEN p_filters->>'kind' END;
  v_state := CASE WHEN p_filters->>'state' IN ('open','closed','all') THEN p_filters->>'state' ELSE 'all' END;
  v_q := NULLIF(TRIM(COALESCE(p_filters->>'q', '')), '');
  BEGIN v_limit := NULLIF(p_filters->>'limit','')::numeric::integer; EXCEPTION WHEN others THEN v_limit := NULL; END;
  BEGIN v_offset := NULLIF(p_filters->>'offset','')::numeric::integer; EXCEPTION WHEN others THEN v_offset := NULL; END;
  v_limit := LEAST(GREATEST(COALESCE(v_limit, 100), 1), 500);
  v_offset := GREATEST(COALESCE(v_offset, 0), 0);

  WITH t AS (
    SELECT (f->>'id')::uuid AS id, f->>'status' AS status_code, (f->>'scheduled_at')::timestamptz AS scheduled_at,
           (f->>'created_at')::timestamptz AS created_at, (f->>'closed_at')::timestamptz AS completed_at,
           (f->>'assigned_to')::uuid AS assigned_to, f->>'assigned_to_name' AS assigned_to_name,
           f->'set_by'->>'type' AS performed_by_type, f->'set_by'->>'name' AS performed_by_name, f->>'note' AS notes,
           CASE WHEN COALESCE(f->>'kind', 'escalation') = 'follow_up' THEN 'follow_up' ELSE 'escalation' END AS kind,
           j.id AS job_id, j.contract_id, c.contract_number, c.buyer_id, c.buyer_name, j.invoice_id, i.invoice_number,
           GREATEST(COALESCE(j.amount, 0) - COALESCE(j.amount_settled, 0), 0) AS owed, COALESCE(j.currency, 'INR') AS currency,
           j.billing_cycle_label, j.status_code AS payment_status, (j.scheduled_at AT TIME ZONE 'Asia/Kolkata')::date AS payment_due,
           COALESCE(f->>'status', 'open') = 'open' AS is_open,
           (COALESCE((f->>'scheduled_at')::timestamptz, (f->>'created_at')::timestamptz) AT TIME ZONE 'Asia/Kolkata')::date AS due_on,
           f->'outcome'->>'code' AS outcome, f->'outcome'->>'note' AS outcome_notes, (f->'outcome'->>'at')::timestamptz AS logged_at, f->'outcome'->'by'->>'name' AS logged_by
      FROM public.n_jtd j
      CROSS JOIN LATERAL jsonb_array_elements(j.followups) f
      LEFT JOIN public.t_contracts c ON c.id = j.contract_id
      LEFT JOIN public.t_invoices i ON i.id = j.invoice_id
     WHERE j.tenant_id = p_tenant AND j.followups <> '[]'::jsonb AND COALESCE(j.is_live, true) = p_is_live
  ),
  f AS (
    SELECT * FROM t
     WHERE (v_from IS NULL OR due_on >= v_from) AND (v_to IS NULL OR due_on <= v_to)
       AND (v_who IS NULL OR assigned_to = v_who)
       AND (v_kind IS NULL OR kind = v_kind)
       AND (v_q IS NULL OR buyer_name ILIKE '%' || v_q || '%' OR contract_number ILIKE '%' || v_q || '%' OR invoice_number ILIKE '%' || v_q || '%'
                        OR notes ILIKE '%' || v_q || '%' OR assigned_to_name ILIKE '%' || v_q || '%')
  ),
  s AS (SELECT * FROM f WHERE v_state = 'all' OR (v_state = 'open' AND is_open) OR (v_state = 'closed' AND NOT is_open)),
  page AS (
    SELECT * FROM s
     ORDER BY CASE WHEN is_open THEN 0 ELSE 1 END, CASE WHEN is_open THEN due_on END ASC NULLS LAST, CASE WHEN NOT is_open THEN due_on END DESC NULLS LAST, created_at DESC
     LIMIT v_limit OFFSET v_offset
  )
  SELECT jsonb_build_object(
    'rows', COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', p.id, 'kind', p.kind, 'state', CASE WHEN p.is_open THEN 'open' ELSE 'closed' END, 'status', p.status_code,
              'due_on', p.due_on, 'due_at', p.scheduled_at, 'overdue', (p.is_open AND p.due_on < v_today), 'days', (p.due_on - v_today),
              'assigned_to', p.assigned_to, 'assigned_to_name', p.assigned_to_name,
              'set_by_type', p.performed_by_type, 'set_by_name', p.performed_by_name, 'set_at', p.created_at, 'notes', p.notes,
              'job_id', p.job_id, 'contract_id', p.contract_id, 'contract_number', p.contract_number, 'buyer_id', p.buyer_id, 'buyer_name', p.buyer_name,
              'invoice_id', p.invoice_id, 'invoice_number', p.invoice_number,
              'amount', p.owed, 'currency', p.currency, 'cycle_label', p.billing_cycle_label, 'payment_status', p.payment_status, 'payment_due', p.payment_due,
              'closed_at', COALESCE(p.completed_at, CASE WHEN NOT p.is_open THEN p.logged_at END),
              'outcome', CASE WHEN NOT p.is_open THEN p.outcome END, 'outcome_notes', CASE WHEN NOT p.is_open THEN p.outcome_notes END,
              'closed_by', CASE WHEN NOT p.is_open THEN p.logged_by END))
              ORDER BY CASE WHEN p.is_open THEN 0 ELSE 1 END, CASE WHEN p.is_open THEN p.due_on END ASC NULLS LAST, CASE WHEN NOT p.is_open THEN p.due_on END DESC NULLS LAST, p.created_at DESC)
             FROM page p), '[]'::jsonb),
    'total', (SELECT count(*) FROM s),
    'counts', (SELECT jsonb_build_object(
                 'all', count(*), 'open', count(*) FILTER (WHERE is_open), 'closed', count(*) FILTER (WHERE NOT is_open),
                 'overdue', count(*) FILTER (WHERE is_open AND due_on < v_today),
                 'follow_up', count(*) FILTER (WHERE kind = 'follow_up'), 'escalation', count(*) FILTER (WHERE kind <> 'follow_up'))
               FROM f)
  ) INTO v_out;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', ut.user_id, 'name', COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email)) ORDER BY up.first_name), '[]'::jsonb)
    INTO v_team FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND COALESCE(ut.status, 'active') IN ('active','accepted');

  RETURN jsonb_build_object(
    'success', true, 'today', v_today, 'is_live', p_is_live,
    'window', jsonb_build_object('from', v_from, 'to', v_to),
    'filters', jsonb_strip_nulls(jsonb_build_object('who', v_who, 'kind', v_kind, 'state', v_state, 'q', v_q, 'limit', v_limit, 'offset', v_offset)),
    'rows', v_out->'rows', 'total', v_out->'total', 'counts', v_out->'counts', 'team', v_team,
    'generated_at', now());
END;
$$;

-- ─── group sessions: the chair lives on the occurrence row; no appointment row ──
CREATE OR REPLACE FUNCTION public.gs_schedule_assign(p_tenant uuid, p_id uuid, p_assigned_to uuid, p_assigned_to_name text DEFAULT NULL, p_changed_by uuid DEFAULT NULL, p_changed_by_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_block uuid; v_live boolean; v_date date; v_status text; v_old_name text;
BEGIN
  SELECT source_block_id, is_live, occurrence_date, status, assigned_to_name INTO v_block, v_live, v_date, v_status, v_old_name
  FROM t_group_session_schedule WHERE id=p_id AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status = 'held' THEN RETURN jsonb_build_object('ok', false, 'reason', 'occurrence_completed'); END IF;

  IF p_assigned_to IS NULL THEN
    UPDATE t_group_session_schedule SET assigned_to=NULL, assigned_to_name=NULL, updated_at=now() WHERE id=p_id AND tenant_id=p_tenant;
    INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
    VALUES (p_tenant, 'group_session_occurrence', p_id, 'group_session', 'chair_unassigned',
      format('Chair removed (was %s)', coalesce(v_old_name, 'unassigned')),
      jsonb_build_object('assigned_to_name', v_old_name), jsonb_build_object('assigned_to_name', NULL), p_changed_by, p_changed_by_name);
    RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
  END IF;

  UPDATE t_group_session_schedule SET assigned_to=p_assigned_to, assigned_to_name=p_assigned_to_name, updated_at=now() WHERE id=p_id AND tenant_id=p_tenant;
  INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
  VALUES (p_tenant, 'group_session_occurrence', p_id, 'group_session', 'chair_assigned',
    format('Chair %s → %s', coalesce(v_old_name, 'unassigned'), p_assigned_to_name),
    jsonb_build_object('assigned_to_name', v_old_name), jsonb_build_object('assigned_to_name', p_assigned_to_name), p_changed_by, p_changed_by_name);
  RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
END $$;

-- ─── anchor edits (each post-checked; the helper RAISEs when an anchor is not found exactly once) ──
DO $do$
BEGIN
  -- jtd_complete_visit: close the open slot through the tool
  PERFORM public.jtd__rewrite_fn('jtd_complete_visit',
    $a$UPDATE public.t_appointments SET status = 'completed', last_activity_at = now(), version = version + 1, updated_by = p_actor_id, updated_at = now()
   WHERE event_id = p_event_id AND tenant_id = p_tenant AND is_active AND status = 'accepted';$a$,
    $b$PERFORM public.jtd__close_open_appointments(p_tenant, p_event_id, 'completed', p_actor_type, p_actor_id, p_actor_name, 'Visit done');  -- 022$b$,
    'jtd_complete_visit');

  -- jtd_ops_board: the open follow-up anchors the card (earliest due); the feed carries item actions
  PERFORM public.jtd__rewrite_fn('jtd_ops_board',
    $a$  open_call AS (
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.id AS task_id, n.assigned_to, n.assigned_to_name, n.created_at, n.scheduled_at, n.business_context->>'task_kind' AS task_kind
      FROM public.n_jtd n WHERE n.tenant_id = p_tenant AND n.source_type_code = 'payment_call_due' AND n.status_code IN ('assigned','in_progress','pending','created')
     ORDER BY n.source_id, n.created_at DESC
  )$a$,
    $b$  open_call AS (  -- 022: follow-ups are items on the payment job
    SELECT DISTINCT ON (j.id) j.id AS job_id, (f->>'id')::uuid AS task_id, (f->>'assigned_to')::uuid AS assigned_to, f->>'assigned_to_name' AS assigned_to_name,
           (f->>'created_at')::timestamptz AS created_at, (f->>'scheduled_at')::timestamptz AS scheduled_at, f->>'kind' AS task_kind
      FROM public.n_jtd j CROSS JOIN LATERAL jsonb_array_elements(j.followups) f
     WHERE j.tenant_id = p_tenant AND j.followups <> '[]'::jsonb AND COALESCE(f->>'status', 'open') = 'open'
     ORDER BY j.id, (f->>'scheduled_at')::timestamptz ASC NULLS LAST
  )$b$,
    'jtd_ops_board open_call');
  PERFORM public.jtd__rewrite_fn('jtd_ops_board',
    $a$x.action LIKE 'visit_%' ORDER BY x.created_at DESC LIMIT 200$a$,
    $b$(x.action LIKE 'visit_%' OR x.action LIKE 'followup_%' OR x.action LIKE 'appointment_%' OR x.action IN ('follow_up_set','escalated')) ORDER BY x.created_at DESC LIMIT 200$b$,
    'jtd_ops_board feed');

  -- jtd_activity: item history rows get titles, groups, and pass the filter
  PERFORM public.jtd__rewrite_fn('jtd_activity',
    $a$WHEN 'visit_completed'      THEN 'Visit marked done'$a$,
    $b$WHEN 'visit_completed'      THEN 'Visit marked done'
              WHEN 'follow_up_set'        THEN 'Follow-up set' || COALESCE(' · due ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'DD Mon'), '')
              WHEN 'escalated'            THEN 'Call assigned to ' || COALESCE(h.details->>'assigned_to_name', 'a teammate') || COALESCE(' · due ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'DD Mon'), '')
              WHEN 'followup_assigned'    THEN 'Follow-up reassigned to ' || COALESCE(h.details->>'assigned_to_name', 'nobody')
              WHEN 'followup_rescheduled' THEN 'Follow-up moved' || COALESCE(' to ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'DD Mon'), '')
              WHEN 'followup_closed'      THEN 'Follow-up closed' || COALESCE(' · ' || replace(h.details->'patch'->'outcome'->>'code', '_', ' '), '')
              WHEN 'appointment_added'    THEN 'Slot proposed' || COALESCE(' for ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM'), '')
              WHEN 'appointment_asked'    THEN 'Customer asked to confirm the slot'
              WHEN 'appointment_confirmed' THEN 'Slot confirmed' || COALESCE(' for ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM'), '')
              WHEN 'appointment_rescheduled' THEN 'Slot moved' || COALESCE(' to ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM'), '')
              WHEN 'appointment_assigned' THEN 'Slot assigned to ' || COALESCE(h.details->>'assigned_to_name', 'nobody')
              WHEN 'appointment_closed'   THEN 'Slot closed' || COALESCE(' · ' || replace(h.details->>'status', '_', ' '), '')
              WHEN 'appointment_status_changed' THEN 'Slot ' || COALESCE(replace(h.details->>'status', '_', ' '), 'updated')
              WHEN 'appointment_updated'  THEN 'Slot updated'$b$,
    'jtd_activity titles');
  PERFORM public.jtd__rewrite_fn('jtd_activity',
    $a$WHEN h.action LIKE 'visit_slot%' OR h.action IN ('visit_scheduled') THEN 'appointments'$a$,
    $b$WHEN h.action = 'escalated' THEN 'calls'
                WHEN h.action = 'follow_up_set' OR h.action LIKE 'followup_%' THEN 'followups'
                WHEN h.action LIKE 'appointment_%' THEN 'appointments'
                WHEN h.action LIKE 'visit_slot%' OR h.action IN ('visit_scheduled') THEN 'appointments'$b$,
    'jtd_activity groups');
  PERFORM public.jtd__rewrite_fn('jtd_activity',
    $a$WHERE (h.action IN ('paused', 'resumed') OR h.action LIKE 'visit_%')$a$,
    $b$WHERE (h.action IN ('paused', 'resumed', 'follow_up_set', 'escalated') OR h.action LIKE 'visit_%' OR h.action LIKE 'followup_%' OR h.action LIKE 'appointment_%')$b$,
    'jtd_activity filter');

  -- jtd_contract_activity (the contract page Audit tab / History drawer): follow-up items on the contract's payment jobs
  PERFORM public.jtd__rewrite_fn('jtd_contract_activity',
    $a$WHERE h.action IN ('paused', 'resumed')$a$,
    $b$WHERE (h.action IN ('paused', 'resumed', 'follow_up_set', 'escalated') OR h.action LIKE 'followup_%')$b$,
    'jtd_contract_activity filter');
  PERFORM public.jtd__rewrite_fn('jtd_contract_activity',
    $a$WHEN 'resumed' THEN 'Reminders resumed'
              ELSE initcap(replace(h.action, '_', ' ')) END)::text,$a$,
    $b$WHEN 'resumed' THEN 'Reminders resumed'
              WHEN 'follow_up_set'        THEN 'Follow-up set' || COALESCE(' · due ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'DD Mon'), '')
              WHEN 'escalated'            THEN 'Call assigned to ' || COALESCE(h.details->>'assigned_to_name', 'a teammate') || COALESCE(' · due ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'DD Mon'), '')
              WHEN 'followup_assigned'    THEN 'Follow-up reassigned to ' || COALESCE(h.details->>'assigned_to_name', 'nobody')
              WHEN 'followup_rescheduled' THEN 'Follow-up moved' || COALESCE(' to ' || to_char((h.details->>'scheduled_at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'DD Mon'), '')
              WHEN 'followup_closed'      THEN 'Follow-up closed' || COALESCE(' · ' || replace(h.details->'patch'->'outcome'->>'code', '_', ' '), '')
              ELSE initcap(replace(h.action, '_', ' ')) END)::text,$b$,
    'jtd_contract_activity titles');

  -- get_appointments_list: asked_at / ask_count / customer_response so the register can say "Asked" only when the customer was
  PERFORM public.jtd__rewrite_fn('get_appointments_list',
    $a$a.version, a.created_at, a.updated_at,
               a.event_id, e.block_name,$a$,
    $b$a.version, a.created_at, a.updated_at,
               a.asked_at, a.ask_count, a.customer_response,
               a.event_id, e.block_name,$b$,
    'get_appointments_list cols');
  PERFORM public.jtd__rewrite_fn('get_appointments_list',
    $a$a.version, a.created_at, a.updated_at,
               NULL::uuid AS event_id,$a$,
    $b$a.version, a.created_at, a.updated_at,
               NULL::timestamptz AS asked_at, 0 AS ask_count, NULL::jsonb AS customer_response,
               NULL::uuid AS event_id,$b$,
    'get_appointments_list cols (gs branch)');

  -- reset_tenant_session_and_forms: the test reset clears the slots on the tenant's jobs
  PERFORM public.jtd__rewrite_fn('reset_tenant_session_and_forms',
    $a$BEGIN DELETE FROM t_appointments WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live); EXCEPTION WHEN OTHERS THEN NULL; END;$a$,
    $b$BEGIN UPDATE n_jtd SET appointments = '[]'::jsonb, version = COALESCE(version, 0) + 1, updated_at = now() WHERE tenant_id = p_tenant_id AND (p_is_live IS NULL OR is_live = p_is_live) AND appointments <> '[]'::jsonb; EXCEPTION WHEN OTHERS THEN NULL; END;  -- 022$b$,
    'reset_tenant_session_and_forms');
END $do$;

-- run_contract_event_scanner: STEP 2b (the silent auto-request) removed — cut between its header and STEP 3
DO $do$
DECLARE v_oid oid; v_def text; s1 integer; s2 integer;
BEGIN
  SELECT p.oid INTO STRICT v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'run_contract_event_scanner';
  v_def := pg_get_functiondef(v_oid);
  s1 := position('-- STEP 2b' IN v_def); s2 := position('-- STEP 3' IN v_def);
  IF s1 = 0 OR s2 = 0 OR s2 < s1 THEN RAISE EXCEPTION '022 scanner: STEP 2b / STEP 3 markers not found (% / %)', s1, s2; END IF;
  v_def := left(v_def, s1 - 1)
        || E'-- STEP 2b: appointment auto-request REMOVED (jtd-nucleus/022) — a slot is proposed or asked by a person\n'
        || E'    -- (or, later, by the visit-slot ladder), never a silent row nobody acts on.\n\n    '
        || substr(v_def, s2);
  EXECUTE v_def;
  v_def := pg_get_functiondef(v_oid);
  IF position('INSERT INTO t_appointments' IN v_def) > 0 THEN RAISE EXCEPTION '022 scanner: STEP 2b still present'; END IF;
END $do$;
