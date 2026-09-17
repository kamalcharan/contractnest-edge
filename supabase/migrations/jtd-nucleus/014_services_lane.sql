-- ============================================================================
-- NOTE 2026-09-17: text updated to match the live body after migration 017
-- (invoice_rows union, invoice_overdue/invoice_ahead kind ranks, needs_by_lane,
-- payment_request in the feed). 017 applied them as an anchor rewrite.
-- jtd-nucleus/014 — Ops SERVICES lane: visit tools + the board reader that
-- serves both lanes. Spec: OPS-JTD-TOOLS-SPEC.md §4, §5, §11 (extension
-- pattern). Owner decisions 2026-09-17: lanes are chips on the same board;
-- an appointment is the visit's agreed slot, not a separate object; v1
-- actions Assign · Schedule/Reschedule · Confirm slot · Start visit ·
-- Mark done reuse the existing ticket + appointment flows; test on signia.
--
-- FACTS that shaped this (verified live):
--   · t_contract_events (event_type='service') is the truth for visits. The
--     JTD mirror is incomplete: 185 of 339 visit jobs share the event id and
--     299 open live service events have no job at all. So the lane READS
--     events and WRITES through the existing event/appointment/ticket RPCs;
--     the n_jtd mirror is updated when it exists and never relied upon.
--   · update_contract_event(event, tenant, payload, expected_version, actor,
--     name, reason) validates transitions (scheduled/due → in_progress;
--     in_progress/overdue → completed; NOT scheduled → completed directly)
--     and writes t_contract_event_audit — which the History drawer and the
--     Audit tab already read.
--   · t_appointments: ONE active row per event (uq_appointments_event);
--     create_appointment → 'requested'; update_appointment moves
--     requested/rescheduled/no_response → accepted (needs scheduled_at),
--     accepted → rescheduled, and on 'accepted' it also moves the event's
--     scheduled_date and fires the customer notification
--     (trg_fn_notif_appointment_confirmed). Rows left in cancelled /
--     declined / completed are still is_active=true and block a new one, so
--     the schedule tool retires them first.
--   · create_service_ticket(..., p_event_ids, p_start_now) links the event
--     via t_service_ticket_events and notifies "visit started";
--     update_service_ticket({status:'completed'}) notifies "completed" but
--     does NOT close the event — the complete tool does that.
--
-- Tools (all SECURITY DEFINER, tenant-scoped, actor-stamped, one
-- transaction, machine-readable refusals; downstream RPC refusals are
-- surfaced as reason='downstream_refused' with the RPC's own error):
--   jtd_assign_visit       (event, assign_to)             → event + appointment + mirror
--   jtd_schedule_visit     (event, scheduled_at, confirmed) → appointment (create/reschedule/accept) + event date
--   jtd_confirm_visit_slot (event)                        → appointment accepted (customer notified)
--   jtd_start_visit        (event)                        → ticket in_progress + event in_progress
--   jtd_complete_visit     (event, notes)                 → ticket completed (created first if none) + event completed
-- Reader: jtd_ops_board(tenant, is_live, filters, user) — the board with a
-- `lane` on every row (collections | services), `owner_id` for Who, and a
-- `visit` block on service rows. jtd_collections_board stays, unused.
-- ============================================================================

-- ─── shared: refusal for a loaded visit row (each tool loads + locks it itself;
--     a row-typed variable cannot be part of a multi-item INTO, so no OUT pair) ───
CREATE OR REPLACE FUNCTION public.jtd__visit_refusal(p_e public.t_contract_events)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_e.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'visit_not_found'); END IF;
  IF p_e.status IN ('completed', 'cancelled') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'visit_closed', 'status', p_e.status);
  END IF;
  RETURN NULL;
END;
$$;

-- ─── shared: mirror + history on the JTD job when it exists ────────────────
CREATE OR REPLACE FUNCTION public.jtd__visit_note(
  p_tenant uuid, p_event_id uuid, p_action text, p_actor_type text, p_actor_id uuid, p_actor_name text, p_details jsonb, p_note text,
  p_scheduled_at timestamptz DEFAULT NULL, p_assigned_to uuid DEFAULT NULL, p_assigned_to_name text DEFAULT NULL, p_status text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_job_exists boolean; v_status_id uuid;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.id = p_event_id AND j.tenant_id = p_tenant AND j.event_type_code = 'service_visit') INTO v_job_exists;
  IF NOT v_job_exists THEN RETURN; END IF;
  IF p_status IS NOT NULL THEN
    SELECT s.id INTO v_status_id FROM public.n_jtd_statuses s WHERE s.event_type_code = 'service_visit' AND s.code = p_status AND s.is_active LIMIT 1;
  END IF;
  UPDATE public.n_jtd
     SET scheduled_at     = COALESCE(p_scheduled_at, scheduled_at),
         assigned_to      = COALESCE(p_assigned_to, assigned_to),
         assigned_to_name = COALESCE(p_assigned_to_name, assigned_to_name),
         status_code      = CASE WHEN p_status IS NOT NULL AND v_status_id IS NOT NULL THEN p_status ELSE status_code END,
         status_id        = COALESCE(v_status_id, status_id),
         completed_at     = CASE WHEN p_status = 'completed' THEN now() ELSE completed_at END,
         version = COALESCE(version, 0) + 1, updated_at = now()
   WHERE id = p_event_id AND tenant_id = p_tenant;
  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  SELECT p_event_id, p_action, p_actor_type, p_actor_id, p_actor_name, p_details, p_note, COALESCE(j.is_live, true)
    FROM public.n_jtd j WHERE j.id = p_event_id;
END;
$$;

-- ─── 1. Assign ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_assign_visit(
  p_tenant uuid, p_event_id uuid, p_assign_to uuid,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_name text; v_r jsonb; v_appt uuid;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;

  SELECT COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email) INTO v_name
    FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND ut.user_id = p_assign_to LIMIT 1;
  IF v_name IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'assignee_not_in_tenant'); END IF;
  IF v_e.assigned_to = p_assign_to THEN RETURN jsonb_build_object('success', false, 'reason', 'already_assigned', 'assigned_to_name', v_e.assigned_to_name); END IF;

  v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('assigned_to', p_assign_to, 'assigned_to_name', v_name),
                                      v_e.version, p_actor_id, p_actor_name, COALESCE(p_note, 'Assigned from Ops'));
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_r->>'error', 'code', v_r->>'error_code');
  END IF;
  -- keep the open appointment's assignee in step (no status/time change → no audit noise)
  SELECT a.id INTO v_appt FROM public.t_appointments a WHERE a.event_id = p_event_id AND a.is_active AND a.status NOT IN ('cancelled','declined','completed') LIMIT 1;
  IF v_appt IS NOT NULL THEN
    PERFORM public.update_appointment(v_appt, p_tenant, jsonb_build_object('assigned_to', p_assign_to, 'assigned_to_name', v_name), NULL, p_actor_id, p_actor_name);
  END IF;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_assigned', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('assigned_to', p_assign_to, 'assigned_to_name', v_name, 'previous', v_e.assigned_to_name), p_note,
                                 NULL, p_assign_to, v_name, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'assigned_to', p_assign_to, 'assigned_to_name', v_name, 'version', v_e.version + 1);
END;
$$;

-- ─── 2. Schedule / reschedule (optionally confirmed with the customer) ──────
CREATE OR REPLACE FUNCTION public.jtd_schedule_visit(
  p_tenant uuid, p_event_id uuid, p_scheduled_at timestamptz, p_confirmed boolean,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e public.t_contract_events; v_ref jsonb; v_r jsonb;
  v_appt uuid; v_appt_status text; v_appt_at timestamptz; v_appt_version integer;
  v_payload jsonb; v_new_status text; v_event_moved boolean := false;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  IF p_scheduled_at IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'scheduled_at_required'); END IF;
  IF p_scheduled_at < now() - interval '1 day' THEN RETURN jsonb_build_object('success', false, 'reason', 'slot_in_past'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  IF v_e.status = 'in_progress' THEN RETURN jsonb_build_object('success', false, 'reason', 'visit_in_progress'); END IF;

  -- the event's one active appointment: reuse if open, retire if closed, create if none
  SELECT a.id, a.status, a.scheduled_at, a.version INTO v_appt, v_appt_status, v_appt_at, v_appt_version FROM public.t_appointments a
   WHERE a.event_id = p_event_id AND a.tenant_id = p_tenant AND a.is_active ORDER BY a.updated_at DESC LIMIT 1 FOR UPDATE;
  IF v_appt IS NOT NULL AND v_appt_status IN ('cancelled','declined','completed') THEN
    UPDATE public.t_appointments SET is_active = false, updated_by = p_actor_id, updated_at = now() WHERE id = v_appt;
    v_appt := NULL; v_appt_status := NULL; v_appt_at := NULL; v_appt_version := NULL;
  END IF;
  IF v_appt IS NULL THEN
    v_r := public.create_appointment(p_tenant, p_event_id, p_note, p_actor_id, p_actor_name);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_r->>'error', 'code', v_r->>'code');
    END IF;
    v_appt := (v_r->'data'->>'id')::uuid;
    SELECT a.status, a.scheduled_at, a.version INTO v_appt_status, v_appt_at, v_appt_version FROM public.t_appointments a WHERE a.id = v_appt;
  END IF;

  -- target status per the appointment state machine
  v_new_status := CASE
    WHEN p_confirmed THEN 'accepted'                                  -- requested/rescheduled/no_response/accepted → accepted
    WHEN v_appt_status = 'accepted' THEN 'rescheduled'                -- a confirmed slot is being moved: back to unconfirmed
    WHEN v_appt_status = 'no_response' THEN 'requested'
    ELSE v_appt_status END;                                           -- requested / rescheduled stay, time changes
  v_payload := jsonb_build_object('scheduled_at', p_scheduled_at, 'status', v_new_status);
  IF p_note IS NOT NULL THEN v_payload := v_payload || jsonb_build_object('notes', p_note); END IF;
  IF v_e.assigned_to IS NOT NULL THEN v_payload := v_payload || jsonb_build_object('assigned_to', v_e.assigned_to, 'assigned_to_name', v_e.assigned_to_name); END IF;
  v_r := public.update_appointment(v_appt, p_tenant, v_payload, v_appt_version, p_actor_id, p_actor_name);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001';   -- roll back the create_appointment above
  END IF;
  -- update_appointment moves the event only on 'accepted'; for a proposed slot we move it ourselves so the board follows
  IF v_new_status <> 'accepted' AND v_e.scheduled_date IS DISTINCT FROM p_scheduled_at THEN
    v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('scheduled_date', p_scheduled_at), v_e.version, p_actor_id, p_actor_name,
                                        COALESCE(p_note, 'Slot proposed from Ops — awaiting customer confirmation'));
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_event_moved := true;
  END IF;

  PERFORM public.jtd__visit_note(p_tenant, p_event_id, CASE WHEN p_confirmed THEN 'visit_slot_confirmed' ELSE 'visit_scheduled' END,
                                 p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('appointment_id', v_appt, 'scheduled_at', p_scheduled_at, 'confirmed', p_confirmed, 'previous', v_e.scheduled_date, 'appointment_status', v_new_status),
                                 p_note, p_scheduled_at, NULL, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'appointment_status', v_new_status,
                            'scheduled_at', p_scheduled_at, 'confirmed', p_confirmed, 'event_moved', v_event_moved OR p_confirmed);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', COALESCE((substr(SQLERRM, 6)::jsonb)->>'code', (substr(SQLERRM, 6)::jsonb)->>'error_code'));
  END IF;
  RAISE;
END;
$$;

-- ─── 3. Confirm the slot (customer agreed) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_confirm_visit_slot(
  p_tenant uuid, p_event_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_a record; v_r jsonb;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  SELECT a.id, a.status, a.scheduled_at, a.version INTO v_a FROM public.t_appointments a
   WHERE a.event_id = p_event_id AND a.tenant_id = p_tenant AND a.is_active AND a.status NOT IN ('cancelled','declined','completed') LIMIT 1 FOR UPDATE;
  IF v_a.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_slot_to_confirm'); END IF;
  IF v_a.status = 'accepted' THEN RETURN jsonb_build_object('success', false, 'reason', 'already_confirmed', 'scheduled_at', v_a.scheduled_at); END IF;
  IF v_a.scheduled_at IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'no_slot_to_confirm'); END IF;
  v_r := public.update_appointment(v_a.id, p_tenant, jsonb_build_object('status', 'accepted') || CASE WHEN p_note IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('notes', p_note) END,
                                   v_a.version, p_actor_id, p_actor_name);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', v_r->>'error', 'code', v_r->>'code');
  END IF;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_slot_confirmed', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('appointment_id', v_a.id, 'scheduled_at', v_a.scheduled_at, 'confirmed', true), p_note, v_a.scheduled_at, NULL, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_a.id, 'scheduled_at', v_a.scheduled_at, 'appointment_status', 'accepted');
END;
$$;

-- ─── 4. Start the visit (ticket in progress + event in progress) ────────────
CREATE OR REPLACE FUNCTION public.jtd_start_visit(
  p_tenant uuid, p_event_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_t record; v_r jsonb; v_ticket uuid; v_ticket_no text; v_assignee uuid; v_assignee_name text;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  SELECT t.id, t.ticket_number, t.status INTO v_t FROM public.t_service_ticket_events te JOIN public.t_service_tickets t ON t.id = te.ticket_id
   WHERE te.event_id = p_event_id AND t.tenant_id = p_tenant AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1;
  IF v_t.id IS NOT NULL AND v_t.status = 'in_progress' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'visit_already_started', 'ticket_id', v_t.id, 'ticket_number', v_t.ticket_number);
  END IF;
  -- the technician on the event, else the actor (a human starting it is doing it)
  v_assignee := COALESCE(v_e.assigned_to, CASE WHEN p_actor_type = 'user' THEN p_actor_id END);
  v_assignee_name := COALESCE(v_e.assigned_to_name, CASE WHEN p_actor_type = 'user' THEN p_actor_name END);

  IF v_t.id IS NOT NULL THEN
    v_r := public.update_service_ticket(v_t.id, p_tenant, jsonb_build_object('status', 'in_progress') || CASE WHEN p_note IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('notes', p_note) END, NULL, p_actor_id, p_actor_name);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_ticket := v_t.id; v_ticket_no := v_t.ticket_number;
  ELSE
    v_r := public.create_service_ticket(p_tenant, v_e.contract_id, now(), v_assignee, v_assignee_name, p_note, ARRAY[p_event_id], p_actor_id, p_actor_name, COALESCE(v_e.is_live, true), NULL, true);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_ticket := (v_r->'data'->>'id')::uuid; v_ticket_no := v_r->'data'->>'ticket_number';
  END IF;
  IF v_e.status <> 'in_progress' THEN
    v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('status', 'in_progress') || CASE WHEN v_e.assigned_to IS NULL AND v_assignee IS NOT NULL THEN jsonb_build_object('assigned_to', v_assignee, 'assigned_to_name', v_assignee_name) ELSE '{}'::jsonb END,
                                        v_e.version, p_actor_id, p_actor_name, COALESCE(p_note, 'Visit started from Ops · ' || v_ticket_no));
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
  END IF;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_started', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('ticket_id', v_ticket, 'ticket_number', v_ticket_no), p_note, NULL, v_assignee, v_assignee_name, 'in_progress');
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'ticket_id', v_ticket, 'ticket_number', v_ticket_no, 'assigned_to_name', v_assignee_name);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', COALESCE((substr(SQLERRM, 6)::jsonb)->>'code', (substr(SQLERRM, 6)::jsonb)->>'error_code'));
  END IF;
  RAISE;
END;
$$;

-- ─── 5. Mark done (ticket completed + event completed) ──────────────────────
CREATE OR REPLACE FUNCTION public.jtd_complete_visit(
  p_tenant uuid, p_event_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text, p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_t record; v_r jsonb; v_ticket uuid; v_ticket_no text; v_version integer; v_assignee uuid; v_assignee_name text;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  v_version := v_e.version;
  v_assignee := COALESCE(v_e.assigned_to, CASE WHEN p_actor_type = 'user' THEN p_actor_id END);
  v_assignee_name := COALESCE(v_e.assigned_to_name, CASE WHEN p_actor_type = 'user' THEN p_actor_name END);

  SELECT t.id, t.ticket_number, t.status INTO v_t FROM public.t_service_ticket_events te JOIN public.t_service_tickets t ON t.id = te.ticket_id
   WHERE te.event_id = p_event_id AND t.tenant_id = p_tenant AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1;
  IF v_t.id IS NULL THEN
    -- no ticket yet: create one already started, so the trail (started → completed) exists
    v_r := public.create_service_ticket(p_tenant, v_e.contract_id, now(), v_assignee, v_assignee_name, p_notes, ARRAY[p_event_id], p_actor_id, p_actor_name, COALESCE(v_e.is_live, true), NULL, true);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_ticket := (v_r->'data'->>'id')::uuid; v_ticket_no := v_r->'data'->>'ticket_number';
  ELSE
    v_ticket := v_t.id; v_ticket_no := v_t.ticket_number;
  END IF;
  v_r := public.update_service_ticket(v_ticket, p_tenant, jsonb_build_object('status', 'completed') || CASE WHEN p_notes IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('completion_notes', p_notes) END, NULL, p_actor_id, p_actor_name);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;

  -- event: scheduled/due must pass through in_progress; overdue/in_progress may complete directly
  IF v_e.status IN ('scheduled', 'due') THEN
    v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('status', 'in_progress'), v_version, p_actor_id, p_actor_name, 'Visit done from Ops · ' || v_ticket_no);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_version := v_version + 1;
  END IF;
  v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('status', 'completed') || CASE WHEN p_notes IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('notes', p_notes) END,
                                      v_version, p_actor_id, p_actor_name, COALESCE(p_notes, 'Visit done from Ops · ' || v_ticket_no));
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
  -- close the appointment if one was open
  UPDATE public.t_appointments SET status = 'completed', last_activity_at = now(), version = version + 1, updated_by = p_actor_id, updated_at = now()
   WHERE event_id = p_event_id AND tenant_id = p_tenant AND is_active AND status = 'accepted';

  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_completed', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('ticket_id', v_ticket, 'ticket_number', v_ticket_no), p_notes, NULL, v_assignee, v_assignee_name, 'completed');
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'ticket_id', v_ticket, 'ticket_number', v_ticket_no);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', COALESCE((substr(SQLERRM, 6)::jsonb)->>'code', (substr(SQLERRM, 6)::jsonb)->>'error_code'));
  END IF;
  RAISE;
END;
$$;

-- ─── 6. The board, both lanes ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_ops_board(
  p_tenant   uuid,
  p_is_live  boolean DEFAULT true,
  p_filters  jsonb   DEFAULT '{}'::jsonb,
  p_user     uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today    date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_horizon  integer; v_from date; v_to date; v_b1 integer := 3; v_b2 integer := 14;
  v_kinds text[]; v_lanes text[]; v_channel text; v_age text; v_cycle text; v_who text; v_q text; v_slot text;
  v_limits jsonb; v_limit integer; v_board jsonb; v_happened jsonb; v_team jsonb; v_ladder jsonb; v_tmp date;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'tenant_required'); END IF;
  p_filters := COALESCE(p_filters, '{}'::jsonb);

  BEGIN v_horizon := NULLIF(p_filters->>'horizon_days','')::numeric::integer; EXCEPTION WHEN others THEN v_horizon := NULL; END;
  v_horizon := LEAST(GREATEST(COALESCE(v_horizon, 30), 1), 120);
  BEGIN v_from := NULLIF(p_filters->>'from','')::date; EXCEPTION WHEN others THEN v_from := NULL; END;
  BEGIN v_to   := NULLIF(p_filters->>'to','')::date;   EXCEPTION WHEN others THEN v_to := NULL; END;
  IF v_from IS NOT NULL AND v_to IS NOT NULL AND v_to < v_from THEN v_tmp := v_from; v_from := v_to; v_to := v_tmp; END IF;
  IF v_to IS NULL THEN v_to := v_today + v_horizon; END IF;
  IF jsonb_typeof(p_filters->'bands') = 'array' AND jsonb_array_length(p_filters->'bands') = 2 THEN
    BEGIN v_b1 := (p_filters->'bands'->>0)::numeric::integer; v_b2 := (p_filters->'bands'->>1)::numeric::integer;
    EXCEPTION WHEN others THEN v_b1 := 3; v_b2 := 14; END;
    IF v_b1 IS NULL OR v_b2 IS NULL OR v_b1 < 1 OR v_b2 <= v_b1 THEN v_b1 := 3; v_b2 := 14; END IF;
  END IF;
  IF jsonb_typeof(p_filters->'kinds') = 'array' AND jsonb_array_length(p_filters->'kinds') > 0 THEN v_kinds := ARRAY(SELECT jsonb_array_elements_text(p_filters->'kinds')); END IF;
  IF jsonb_typeof(p_filters->'lanes') = 'array' AND jsonb_array_length(p_filters->'lanes') > 0 THEN v_lanes := ARRAY(SELECT jsonb_array_elements_text(p_filters->'lanes')); END IF;
  v_channel := NULLIF(p_filters->>'channel', ''); v_age := NULLIF(p_filters->>'age', ''); v_cycle := NULLIF(p_filters->>'cycle', '');
  v_slot := NULLIF(p_filters->>'slot', ''); v_who := COALESCE(NULLIF(p_filters->>'who', ''), 'team'); v_q := NULLIF(TRIM(COALESCE(p_filters->>'q', '')), '');
  BEGIN v_limit := NULLIF(p_filters->>'limit','')::numeric::integer; EXCEPTION WHEN others THEN v_limit := NULL; END;
  v_limit := LEAST(GREATEST(COALESCE(v_limit, 20), 1), 200);
  v_limits := '{}'::jsonb;
  IF jsonb_typeof(p_filters->'limits') = 'object' THEN
    SELECT COALESCE(jsonb_object_agg(e.key, LEAST(GREATEST(e.value::numeric::integer, 1), 500)), '{}'::jsonb) INTO v_limits
      FROM jsonb_each_text(p_filters->'limits') e WHERE jsonb_typeof(p_filters->'limits'->e.key) = 'number';
  END IF;

  WITH jobs AS (
    SELECT j.id, j.contract_id, j.invoice_id, j.scheduled_at, j.status_code, j.amount, j.amount_settled, j.currency,
           j.dunning_step, j.nudge_count, j.last_nudge_at, j.dunning_paused_reason, j.promise_date, j.block_name,
           j.billing_cycle_label, j.sequence_number, j.total_occurrences,
           (j.scheduled_at AT TIME ZONE 'Asia/Kolkata')::date AS due_date,
           c.contract_number, c.buyer_id, c.buyer_name, i.invoice_number,
           GREATEST(COALESCE(j.amount,0) - COALESCE(j.amount_settled,0), 0) AS owed
      FROM public.n_jtd j JOIN public.t_contracts c ON c.id = j.contract_id LEFT JOIN public.t_invoices i ON i.id = j.invoice_id
     WHERE j.tenant_id = p_tenant AND j.event_type_code = 'payment' AND COALESCE(j.is_live, true) = p_is_live
       AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true)
  ),
  rung AS (
    SELECT jb.id AS job_id, r.step, r.after_days, r.channel, public.jtd_rung_due_at(jb.scheduled_at, r.after_days) AS due_at
      FROM jobs jb JOIN LATERAL (SELECT * FROM public.jtd_ladder_rungs(p_tenant) x WHERE x.step = jb.dunning_step + 1) r ON true
  ),
  last_nudge AS (
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.id AS reminder_id, n.channel_code, n.status_code, n.created_at, n.source_type_code, n.error_message
      FROM public.n_jtd n WHERE n.tenant_id = p_tenant AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_logged')
     ORDER BY n.source_id, n.created_at DESC
  ),
  open_call AS (
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.id AS task_id, n.assigned_to, n.assigned_to_name, n.created_at, n.scheduled_at, n.business_context->>'task_kind' AS task_kind
      FROM public.n_jtd n WHERE n.tenant_id = p_tenant AND n.source_type_code = 'payment_call_due' AND n.status_code IN ('assigned','in_progress','pending','created')
     ORDER BY n.source_id, n.created_at DESC
  ),
  sess_decl AS (
    SELECT d.billing_event_id AS job_id, d.id AS declaration_id, d.amount, d.upi_reference AS reference, d.created_at, 'session'::text AS kind
      FROM public.t_session_payment_declarations d WHERE d.tenant_id = p_tenant AND d.status = 'pending' AND d.billing_event_id IS NOT NULL
  ),
  pub_decl AS (
    SELECT (SELECT jb.id FROM jobs jb WHERE jb.invoice_id = d.invoice_id ORDER BY jb.scheduled_at LIMIT 1) AS job_id,
           d.id AS declaration_id, d.amount, d.reference, d.created_at, 'public'::text AS kind
      FROM public.t_public_payment_declarations d WHERE d.tenant_id = p_tenant AND d.status = 'pending' AND COALESCE(d.is_live, true) = p_is_live
  ),
  decl AS (SELECT * FROM sess_decl UNION ALL SELECT * FROM pub_decl WHERE job_id IS NOT NULL),
  enriched AS (
    SELECT jb.*, (jb.due_date < v_today) AS is_overdue, GREATEST(v_today - jb.due_date, 0) AS days_overdue, (jb.due_date - v_today) AS days_until,
           r.step AS rung_step, r.after_days AS rung_after_days, r.channel AS rung_channel, r.due_at AS rung_due_at,
           ln.reminder_id AS last_reminder_id, ln.channel_code AS last_channel, ln.source_type_code AS last_kind, ln.status_code AS last_status, ln.created_at AS last_at, ln.error_message AS last_error,
           oc.task_id AS call_task_id, oc.assigned_to AS call_assigned_to, oc.assigned_to_name AS call_assigned_to_name, oc.created_at AS call_created_at, oc.scheduled_at AS call_due_at, oc.task_kind AS call_task_kind,
           d.declaration_id, d.amount AS declared_amount, d.reference AS declared_reference, d.created_at AS declared_at, d.kind AS declaration_kind,
           CASE WHEN d.declaration_id IS NOT NULL THEN NULL
                WHEN jb.dunning_paused_reason = 'promise' AND jb.promise_date IS NOT NULL AND jb.promise_date < v_today THEN NULL
                ELSE jb.dunning_paused_reason END AS effective_pause
      FROM jobs jb LEFT JOIN rung r ON r.job_id = jb.id LEFT JOIN last_nudge ln ON ln.job_id = jb.id LEFT JOIN open_call oc ON oc.job_id = jb.id
      LEFT JOIN LATERAL (SELECT * FROM decl x WHERE x.job_id = jb.id ORDER BY x.created_at DESC LIMIT 1) d ON true
  ),
  kinded AS (
    SELECT e.*, CASE WHEN e.declaration_id IS NOT NULL THEN 'declaration_pending'
                     WHEN e.last_status = 'failed' AND e.last_kind IN ('payment_nudge_email','payment_nudge_whatsapp') AND e.last_at > now() - interval '7 days' THEN 'send_failed'
                     WHEN e.call_task_id IS NOT NULL THEN 'call_open'
                     WHEN e.effective_pause IS NOT NULL THEN 'paused'
                     WHEN e.rung_step IS NOT NULL AND e.rung_due_at <= now() THEN 'rung_due'
                     WHEN NOT e.is_overdue THEN 'payment_ahead'
                     WHEN e.rung_step IS NOT NULL THEN 'rung_ahead'
                     WHEN e.dunning_step > 0 THEN 'ladder_exhausted'
                     ELSE 'overdue_no_ladder' END AS kind
      FROM enriched e
  ),
  job_rows AS (
    SELECT k.id::text AS row_id, 'collections'::text AS lane, k.kind, k.id AS job_id, k.contract_id, k.contract_number::text AS contract_number, k.buyer_id, k.buyer_name::text AS buyer_name,
           k.invoice_id, k.invoice_number, k.block_name, k.billing_cycle_label AS cycle_label, k.sequence_number, k.total_occurrences,
           k.owed AS amount, COALESCE(k.currency,'INR')::text AS currency, k.due_date, k.status_code::text AS status,
           k.days_overdue, k.days_until, k.dunning_step, k.nudge_count, k.last_nudge_at,
           k.last_channel, k.last_kind, k.last_status, k.last_error, k.last_reminder_id, k.last_at,
           k.rung_step, k.rung_after_days, k.rung_channel, k.rung_due_at,
           k.effective_pause AS paused_reason, k.promise_date,
           k.declaration_id, k.declaration_kind, k.declared_amount, k.declared_reference, k.declared_at,
           k.call_task_id, k.call_assigned_to, k.call_assigned_to_name, k.call_due_at, k.call_task_kind,
           NULL::text AS awaiting_status, NULL::timestamptz AS awaiting_since, NULL::date AS awaiting_start,
           k.call_assigned_to AS owner_id, k.call_assigned_to_name AS owner_name, NULL::text AS slot_state, NULL::jsonb AS visit,
           CASE k.kind WHEN 'declaration_pending' THEN k.declared_at WHEN 'send_failed' THEN k.last_at
                       WHEN 'call_open' THEN COALESCE(k.call_due_at, k.call_created_at)
                       WHEN 'paused' THEN CASE WHEN k.effective_pause = 'promise' AND k.promise_date IS NOT NULL THEN (k.promise_date::timestamp AT TIME ZONE 'Asia/Kolkata') ELSE NULL END
                       WHEN 'rung_due' THEN k.rung_due_at WHEN 'rung_ahead' THEN k.rung_due_at ELSE k.scheduled_at END AS anchor_at
      FROM kinded k
  ),
  awaiting_rows AS (
    SELECT c.id::text, 'collections', 'awaiting_activation'::text, NULL::uuid, c.id, c.contract_number::text, c.buyer_id, c.buyer_name::text,
           NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::integer, NULL::integer,
           c.grand_total, COALESCE(c.currency,'INR')::text, (c.start_date AT TIME ZONE 'Asia/Kolkata')::date, c.status::text,
           0, NULL::integer, 0, 0, NULL::timestamptz,
           NULL::text, NULL::text, NULL::text, NULL::text, NULL::uuid, NULL::timestamptz,
           NULL::integer, NULL::integer, NULL::text, NULL::timestamptz,
           NULL::text, NULL::date,
           NULL::uuid, NULL::text, NULL::numeric, NULL::text, NULL::timestamptz,
           NULL::uuid, NULL::uuid, NULL::text, NULL::timestamptz, NULL::text,
           c.status::text, c.created_at, (c.start_date AT TIME ZONE 'Asia/Kolkata')::date,
           NULL::uuid, NULL::text, NULL::text, NULL::jsonb,
           c.created_at
      FROM public.t_contracts c
     WHERE c.tenant_id = p_tenant AND c.record_type = 'contract' AND COALESCE(c.is_live, true) = p_is_live
       AND c.acceptance_method = 'payment' AND c.status IN ('pending_acceptance','sent') AND COALESCE(c.is_active, true)
  ),
  -- ── SERVICES: t_contract_events is the truth (JTD mirror incomplete) ──
  visits AS (
    SELECT e.id, e.contract_id, e.block_name, e.sequence_number, e.total_occurrences, e.scheduled_date, e.status, e.assigned_to, e.assigned_to_name, e.currency, e.notes,
           (e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date AS sd,
           c.contract_number, c.buyer_id, c.buyer_name,
           a.id AS appt_id, a.status AS appt_status, a.scheduled_at AS appt_at, a.asked_at AS appt_asked_at, a.ask_count AS appt_ask_count, a.customer_response AS appt_response, d.customer_response AS declined_response,
           st.id AS ticket_id, st.ticket_number, st.status AS ticket_status
      FROM public.t_contract_events e
      JOIN public.t_contracts c ON c.id = e.contract_id
      LEFT JOIN LATERAL (SELECT x.id, x.status, x.scheduled_at, x.asked_at, x.ask_count, x.customer_response FROM public.t_appointments x
                          WHERE x.event_id = e.id AND x.is_active AND x.status NOT IN ('cancelled','declined','completed') ORDER BY x.updated_at DESC LIMIT 1) a ON true
      LEFT JOIN LATERAL (SELECT x.customer_response FROM public.t_appointments x WHERE x.event_id = e.id AND x.status = 'declined' AND x.customer_response IS NOT NULL ORDER BY x.updated_at DESC LIMIT 1) d ON true
      LEFT JOIN LATERAL (SELECT t.id, t.ticket_number, t.status FROM public.t_service_ticket_events te JOIN public.t_service_tickets t ON t.id = te.ticket_id
                          WHERE te.event_id = e.id AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1) st ON true
     WHERE e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_live, true) = p_is_live AND COALESCE(e.is_active, true)
       AND e.status IN ('scheduled','due','overdue','in_progress')
  ),
  visit_rows AS (
    SELECT v.id::text, 'services',
           CASE WHEN v.status = 'in_progress' OR v.ticket_status = 'in_progress' THEN 'visit_in_progress'
                WHEN v.appt_status = 'rescheduled' AND v.appt_response->>'action' = 'propose' THEN 'slot_to_confirm'
                WHEN v.sd < v_today THEN 'visit_overdue' WHEN v.sd = v_today THEN 'visit_today' ELSE 'visit_scheduled' END,
           v.id, v.contract_id, v.contract_number::text, v.buyer_id, v.buyer_name::text,
           NULL::uuid, NULL::text, v.block_name, NULL::text, v.sequence_number, v.total_occurrences,
           NULL::numeric, COALESCE(v.currency,'INR')::text, v.sd, v.status::text,
           GREATEST(v_today - v.sd, 0), (v.sd - v_today), 0, 0, NULL::timestamptz,
           NULL::text, NULL::text, NULL::text, NULL::text, NULL::uuid, NULL::timestamptz,
           NULL::integer, NULL::integer, NULL::text, NULL::timestamptz,
           NULL::text, NULL::date,
           NULL::uuid, NULL::text, NULL::numeric, NULL::text, NULL::timestamptz,
           NULL::uuid, NULL::uuid, NULL::text, NULL::timestamptz, NULL::text,
           NULL::text, NULL::timestamptz, NULL::date,
           v.assigned_to, v.assigned_to_name::text,
           CASE WHEN v.appt_status = 'accepted' THEN 'confirmed' WHEN v.appt_id IS NOT NULL AND v.appt_at IS NOT NULL THEN 'proposed' ELSE 'none' END,
           jsonb_strip_nulls(jsonb_build_object(
             'block_name', v.block_name, 'sequence', v.sequence_number, 'of', v.total_occurrences, 'scheduled_at', v.scheduled_date, 'notes', v.notes,
             'assigned_to', v.assigned_to, 'assigned_to_name', v.assigned_to_name,
             'slot', CASE WHEN v.appt_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.appt_id, 'status', v.appt_status, 'at', v.appt_at, 'confirmed', v.appt_status = 'accepted') END,
             'ask', CASE WHEN v.appt_asked_at IS NULL AND v.appt_response IS NULL AND v.declined_response IS NULL THEN NULL
                          ELSE jsonb_strip_nulls(jsonb_build_object('asked_at', v.appt_asked_at, 'count', v.appt_ask_count, 'response', v.appt_response, 'declined', v.declined_response)) END,
             'ticket', CASE WHEN v.ticket_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.ticket_id, 'number', v.ticket_number, 'status', v.ticket_status) END)),
           v.scheduled_date
      FROM visits v
  ),
  invoice_rows AS (
    -- a WHOLE-INVOICE due (017): Money In's rule (get_tenant_receivables `ev` union) — open receivable invoice, balance > 0,
    -- contract with no live billing event; skipped when an open payment job already points at the invoice (that job is the row)
    SELECT i.id::text, 'collections',
           CASE WHEN x.due < v_today THEN 'invoice_overdue' ELSE 'invoice_ahead' END,
           NULL::uuid, c.id, c.contract_number::text, c.buyer_id, c.buyer_name::text,
           i.id, i.invoice_number::text, NULL::text, NULL::text, NULL::integer, NULL::integer,
           i.balance, COALESCE(i.currency,'INR')::text, x.due, i.status::text,
           GREATEST(v_today - x.due, 0), (x.due - v_today), 0, COALESCE(s.n, 0)::integer, s.last_at,
           s.last_channel, CASE WHEN s.n > 0 THEN 'payment_request' END, s.last_status, NULL::text, NULL::uuid, NULL::timestamptz,
           NULL::integer, NULL::integer, NULL::text, NULL::timestamptz,
           NULL::text, NULL::date,
           NULL::uuid, NULL::text, NULL::numeric, NULL::text, NULL::timestamptz,
           NULL::uuid, NULL::uuid, NULL::text, NULL::timestamptz, NULL::text,
           NULL::text, NULL::timestamptz, NULL::date,
           NULL::uuid, NULL::text, NULL::text, NULL::jsonb,
           (x.due::timestamp AT TIME ZONE 'Asia/Kolkata')
      FROM public.t_invoices i
      JOIN public.t_contracts c ON c.id = i.contract_id
      CROSS JOIN LATERAL (SELECT COALESCE(i.due_date, (i.issued_at AT TIME ZONE 'Asia/Kolkata')::date, (i.created_at AT TIME ZONE 'Asia/Kolkata')::date) AS due) x
      LEFT JOIN LATERAL (SELECT count(*) AS n, max(n.created_at) AS last_at,
                                (array_agg(n.channel_code ORDER BY n.created_at DESC))[1] AS last_channel,
                                (array_agg(n.status_code ORDER BY n.created_at DESC))[1] AS last_status
                           FROM public.n_jtd n WHERE n.tenant_id = p_tenant AND n.source_type_code = 'payment_request' AND n.source_id = i.id) s ON true
     WHERE i.tenant_id = p_tenant AND i.invoice_type = 'receivable' AND COALESCE(i.is_active, true) AND COALESCE(i.is_live, true) = p_is_live
       AND i.status IN ('unpaid','partially_paid') AND i.balance > 0
       AND NOT EXISTS (SELECT 1 FROM public.t_contract_events e WHERE e.contract_id = i.contract_id AND e.event_type = 'billing' AND COALESCE(e.is_active, true)
                          AND COALESCE(e.is_live, true) = p_is_live AND COALESCE(e.status, '') NOT IN ('cancelled','skipped','waived'))
       AND NOT EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.tenant_id = p_tenant AND j.event_type_code = 'payment' AND j.invoice_id = i.id
                          AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true))
  ),
  all_rows AS (SELECT * FROM job_rows UNION ALL SELECT * FROM awaiting_rows UNION ALL SELECT * FROM visit_rows UNION ALL SELECT * FROM invoice_rows),
  placed AS (
    SELECT r.*, (r.anchor_at AT TIME ZONE 'Asia/Kolkata')::date AS anchor_date, ((r.anchor_at AT TIME ZONE 'Asia/Kolkata')::date - v_today) AS days FROM all_rows r
  ),
  bucketed AS (
    SELECT p.*,
           CASE WHEN p.anchor_at IS NULL THEN 'parked' WHEN p.days < 0 THEN 'overdue' WHEN p.days = 0 THEN 'today'
                WHEN p.days <= v_b1 THEN 'b1' WHEN p.days <= v_b2 THEN 'b2' ELSE 'b3' END AS bucket,
           CASE p.kind WHEN 'declaration_pending' THEN 0 WHEN 'send_failed' THEN 1 WHEN 'visit_in_progress' THEN 2 WHEN 'slot_to_confirm' THEN 2 WHEN 'rung_due' THEN 3
                       WHEN 'visit_overdue' THEN 4 WHEN 'visit_today' THEN 5 WHEN 'call_open' THEN 6 WHEN 'overdue_no_ladder' THEN 7 WHEN 'invoice_overdue' THEN 7
                       WHEN 'ladder_exhausted' THEN 8 WHEN 'awaiting_activation' THEN 9 WHEN 'visit_scheduled' THEN 10
                       WHEN 'payment_ahead' THEN 11 WHEN 'invoice_ahead' THEN 11 WHEN 'rung_ahead' THEN 12 ELSE 13 END AS kind_rank,
           (CASE WHEN p.anchor_at IS NULL THEN v_from IS NULL
                 ELSE (v_from IS NULL OR (p.anchor_at AT TIME ZONE 'Asia/Kolkata')::date >= v_from) AND (p.anchor_at AT TIME ZONE 'Asia/Kolkata')::date <= v_to END) AS f_window,
           (v_kinds IS NULL OR p.kind = ANY (v_kinds)) AS f_kind,
           (v_lanes IS NULL OR p.lane = ANY (v_lanes)) AS f_lane,
           (v_channel IS NULL OR p.rung_channel = v_channel) AS f_channel,
           (v_age IS NULL OR (v_age = '0-7' AND p.days_overdue BETWEEN 1 AND 7) OR (v_age = '8-30' AND p.days_overdue BETWEEN 8 AND 30)
                          OR (v_age = '31-90' AND p.days_overdue BETWEEN 31 AND 90) OR (v_age = '90+' AND p.days_overdue > 90)) AS f_age,
           (v_cycle IS NULL OR p.cycle_label = v_cycle) AS f_cycle,
           (v_slot IS NULL OR p.slot_state = v_slot) AS f_slot,
           (v_who = 'team' OR (v_who = 'mine' AND p_user IS NOT NULL AND p.owner_id = p_user) OR (v_who = 'unassigned' AND p.owner_id IS NULL)) AS f_who,
           (v_q IS NULL OR p.buyer_name ILIKE '%' || v_q || '%' OR p.contract_number ILIKE '%' || v_q || '%' OR p.invoice_number ILIKE '%' || v_q || '%'
                        OR p.declared_reference ILIKE '%' || v_q || '%' OR p.block_name ILIKE '%' || v_q || '%' OR p.owner_name ILIKE '%' || v_q || '%') AS f_q
      FROM placed p
  ),
  matched AS (SELECT b.* FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_lane AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_slot AND b.f_who AND b.f_q),
  numbered AS (
    SELECT m.*, row_number() OVER (PARTITION BY m.bucket ORDER BY m.kind_rank, m.anchor_at NULLS LAST, m.contract_number) AS rn,
           count(*) OVER (PARTITION BY m.bucket) AS bucket_count
      FROM matched m
  ),
  card AS (
    SELECT n.bucket, n.rn, n.bucket_count,
           jsonb_strip_nulls(jsonb_build_object(
             'id', n.row_id, 'lane', n.lane, 'kind', n.kind, 'bucket', n.bucket, 'days', n.days, 'anchor_at', n.anchor_at,
             'job_id', n.job_id, 'contract_id', n.contract_id, 'contract_number', n.contract_number,
             'buyer_id', n.buyer_id, 'buyer_name', n.buyer_name, 'invoice_id', n.invoice_id, 'invoice_number', n.invoice_number,
             'block_name', n.block_name, 'cycle_label', n.cycle_label, 'sequence', n.sequence_number, 'of', n.total_occurrences,
             'amount', n.amount, 'currency', n.currency, 'due_date', n.due_date, 'status', n.status,
             'days_overdue', n.days_overdue, 'days_until', n.days_until,
             'dunning_step', n.dunning_step, 'nudge_count', n.nudge_count, 'last_nudge_at', n.last_nudge_at,
             'last_channel', n.last_channel, 'last_kind', n.last_kind, 'last_status', n.last_status,
             'rung', CASE WHEN n.rung_step IS NULL THEN NULL ELSE jsonb_build_object('step', n.rung_step, 'after_days', n.rung_after_days, 'channel', n.rung_channel, 'due_at', n.rung_due_at) END,
             'paused_reason', n.paused_reason, 'promise_date', n.promise_date,
             'declaration', CASE WHEN n.declaration_id IS NULL THEN NULL ELSE jsonb_build_object('id', n.declaration_id, 'kind', n.declaration_kind, 'amount', n.declared_amount, 'reference', n.declared_reference, 'at', n.declared_at) END,
             'call_task', CASE WHEN n.call_task_id IS NULL THEN NULL ELSE jsonb_build_object('id', n.call_task_id, 'assigned_to', n.call_assigned_to, 'assigned_to_name', n.call_assigned_to_name, 'due_at', n.call_due_at, 'kind', n.call_task_kind) END,
             'failed', CASE WHEN n.kind <> 'send_failed' THEN NULL ELSE jsonb_build_object('reminder_id', n.last_reminder_id, 'channel', n.last_channel, 'error', n.last_error, 'at', n.last_at) END,
             'awaiting', CASE WHEN n.kind <> 'awaiting_activation' THEN NULL ELSE jsonb_build_object('status', n.awaiting_status, 'since', n.awaiting_since, 'start_date', n.awaiting_start) END,
             'owner_id', n.owner_id, 'owner_name', n.owner_name, 'slot_state', n.slot_state, 'visit', n.visit)) AS card
      FROM numbered n
  ),
  bucket_defs AS (
    SELECT * FROM (VALUES ('overdue', 0, NULL::integer, -1), ('today', 1, 0, 0), ('b1', 2, 1, v_b1), ('b2', 3, v_b1 + 1, v_b2),
                          ('b3', 4, v_b2 + 1, GREATEST(v_to - v_today, v_b2 + 1)), ('parked', 5, NULL, NULL)) AS t(key, ord, from_days, to_days)
  ),
  buckets AS (
    SELECT bd.key, bd.ord, bd.from_days, bd.to_days,
           COALESCE((SELECT max(c.bucket_count) FROM card c WHERE c.bucket = bd.key), 0) AS total,
           COALESCE((SELECT jsonb_agg(c.card ORDER BY c.rn) FROM card c WHERE c.bucket = bd.key AND c.rn <= COALESCE((v_limits->>bd.key)::integer, v_limit)), '[]'::jsonb) AS cards
      FROM bucket_defs bd
  ),
  facets AS (
    SELECT
      (SELECT COALESCE(jsonb_object_agg(x.kind, x.n), '{}'::jsonb) FROM (SELECT b.kind, count(*) AS n FROM bucketed b WHERE b.f_window AND b.f_lane AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_slot AND b.f_who AND b.f_q GROUP BY b.kind) x) AS kinds,
      (SELECT COALESCE(jsonb_object_agg(x.lane, x.n), '{}'::jsonb) FROM (SELECT b.lane, count(*) AS n FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_slot AND b.f_who AND b.f_q GROUP BY b.lane) x) AS lanes,
      (SELECT COALESCE(jsonb_object_agg(x.ch, x.n), '{}'::jsonb) FROM (SELECT b.rung_channel AS ch, count(*) AS n FROM bucketed b WHERE b.rung_channel IS NOT NULL AND b.f_window AND b.f_kind AND b.f_lane AND b.f_age AND b.f_cycle AND b.f_slot AND b.f_who AND b.f_q GROUP BY b.rung_channel) x) AS channels,
      (SELECT jsonb_build_object('0-7', count(*) FILTER (WHERE b.days_overdue BETWEEN 1 AND 7), '8-30', count(*) FILTER (WHERE b.days_overdue BETWEEN 8 AND 30),
                                 '31-90', count(*) FILTER (WHERE b.days_overdue BETWEEN 31 AND 90), '90+', count(*) FILTER (WHERE b.days_overdue > 90))
         FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_lane AND b.f_channel AND b.f_cycle AND b.f_slot AND b.f_who AND b.f_q) AS ages,
      (SELECT COALESCE(jsonb_object_agg(x.cy, x.n), '{}'::jsonb) FROM (SELECT b.cycle_label AS cy, count(*) AS n FROM bucketed b WHERE b.cycle_label IS NOT NULL AND b.f_window AND b.f_kind AND b.f_lane AND b.f_channel AND b.f_age AND b.f_slot AND b.f_who AND b.f_q GROUP BY b.cycle_label) x) AS cycles,
      (SELECT COALESCE(jsonb_object_agg(x.s, x.n), '{}'::jsonb) FROM (SELECT b.slot_state AS s, count(*) AS n FROM bucketed b WHERE b.slot_state IS NOT NULL AND b.f_window AND b.f_kind AND b.f_lane AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_who AND b.f_q GROUP BY b.slot_state) x) AS slots,
      (SELECT jsonb_build_object('team', count(*), 'mine', count(*) FILTER (WHERE p_user IS NOT NULL AND b.owner_id = p_user), 'unassigned', count(*) FILTER (WHERE b.owner_id IS NULL))
         FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_lane AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_slot AND b.f_q)
       -- + unassigned_visits, which ignores the lane AND kind filters: the headline's "N visits have no technician yet" signal holds on the All view
       || jsonb_build_object('unassigned_visits', (SELECT count(*) FROM bucketed b WHERE b.f_window AND b.lane = 'services' AND b.owner_id IS NULL AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_slot AND b.f_q)) AS who,
      -- needs_by_lane: the focus strip's "N need you" per lane — window only, no other filter, so the strip is a stable map while the user drills
      (SELECT jsonb_build_object('collections', count(*) FILTER (WHERE b.lane = 'collections'), 'services', count(*) FILTER (WHERE b.lane = 'services'))
         FROM bucketed b WHERE b.f_window AND b.kind IN ('declaration_pending','send_failed','call_open','rung_due','overdue_no_ladder','ladder_exhausted','awaiting_activation','invoice_overdue','visit_overdue','visit_today','visit_in_progress','slot_to_confirm')) AS needs_by_lane,
      (SELECT count(*) FROM bucketed b WHERE b.f_window) AS in_window,
      (SELECT count(*) FROM matched) AS matched
  )
  SELECT jsonb_build_object(
    'buckets', (SELECT jsonb_agg(jsonb_build_object('key', b.key, 'from_days', b.from_days, 'to_days', b.to_days, 'count', b.total, 'cards', b.cards) ORDER BY b.ord) FROM buckets b),
    'facets', (SELECT jsonb_build_object('kinds', f.kinds, 'lanes', f.lanes, 'channels', f.channels, 'ages', f.ages, 'cycles', f.cycles, 'slots', f.slots, 'who', f.who, 'needs_by_lane', f.needs_by_lane) FROM facets f),
    'counts', (SELECT jsonb_build_object('in_window', f.in_window, 'matched', f.matched) FROM facets f)
  ) INTO v_board;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.source_type_code, 'job_id', n.source_id, 'contract_id', n.contract_id, 'contract_number', n.source_ref,
      'buyer_name', n.recipient_name, 'channel', n.channel_code, 'status', n.status_code, 'amount', n.amount, 'currency', COALESCE(n.currency,'INR'),
      'rung', n.dunning_step, 'outcome', n.metadata->>'outcome', 'notes', n.notes, 'assigned_to', n.assigned_to, 'assigned_to_name', n.assigned_to_name,
      'task_kind', n.business_context->>'task_kind', 'due_at', CASE WHEN n.source_type_code = 'payment_call_due' THEN n.scheduled_at ELSE NULL END,
      'actor_type', n.performed_by_type, 'actor_name', n.performed_by_name, 'at', n.created_at, 'error', n.error_message) ORDER BY n.created_at DESC), '[]'::jsonb)
    INTO v_happened
    FROM (SELECT * FROM public.n_jtd n WHERE n.tenant_id = p_tenant AND COALESCE(n.is_live, true) = p_is_live
           AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_due','payment_call_logged','payment_request') ORDER BY n.created_at DESC LIMIT 40) n;

  -- visit activity joins the feed from n_jtd_history (visit_* actions), newest first, merged client-side by 'at'
  SELECT COALESCE(v_happened, '[]'::jsonb) || COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', h.id, 'kind', h.action, 'job_id', h.jtd_id, 'contract_id', j.contract_id, 'contract_number', c.contract_number, 'buyer_name', c.buyer_name,
      'channel', NULL, 'status', 'completed', 'amount', NULL, 'currency', 'INR', 'rung', 0, 'outcome', NULL, 'notes', h.note,
      'assigned_to', (h.details->>'assigned_to'), 'assigned_to_name', h.details->>'assigned_to_name', 'task_kind', NULL,
      'due_at', (h.details->>'scheduled_at')::timestamptz, 'actor_type', h.performed_by_type, 'actor_name', h.performed_by_name, 'at', h.created_at, 'error', NULL) ORDER BY h.created_at DESC)
      FROM (SELECT * FROM public.n_jtd_history x WHERE x.action LIKE 'visit_%' ORDER BY x.created_at DESC LIMIT 200) h
      JOIN public.n_jtd j ON j.id = h.jtd_id AND j.tenant_id = p_tenant AND COALESCE(j.is_live, true) = p_is_live
      JOIN public.t_contracts c ON c.id = j.contract_id), '[]'::jsonb)
    INTO v_happened;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', ut.user_id, 'name', COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email)) ORDER BY up.first_name), '[]'::jsonb)
    INTO v_team FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND COALESCE(ut.status, 'active') IN ('active','accepted');

  SELECT jsonb_build_object('rule_enabled', public.vani_rule_enabled(p_tenant, 'payment_reminder'), 'vani_enabled', public.vani_is_enabled(p_tenant),
      'rungs', COALESCE((SELECT jsonb_agg(jsonb_build_object('step', r.step, 'after_days', r.after_days, 'channel', r.channel) ORDER BY r.step) FROM public.jtd_ladder_rungs(p_tenant) r), '[]'::jsonb))
    INTO v_ladder;

  RETURN jsonb_build_object(
    'success', true, 'today', v_today, 'is_live', p_is_live,
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'horizon_days', CASE WHEN p_filters->>'to' IS NULL OR p_filters->>'to' = '' THEN v_horizon ELSE NULL END, 'bands', jsonb_build_array(v_b1, v_b2)),
    'filters', jsonb_strip_nulls(jsonb_build_object('kinds', to_jsonb(v_kinds), 'lanes', to_jsonb(v_lanes), 'channel', v_channel, 'age', v_age, 'cycle', v_cycle, 'slot', v_slot, 'who', v_who, 'q', v_q, 'limit', v_limit)),
    'buckets', v_board->'buckets', 'facets', v_board->'facets', 'counts', v_board->'counts',
    'happened', v_happened, 'team', v_team, 'ladder', v_ladder,
    -- 015: channels with a REGISTERED provider template for slot requests (Share always works)
    'ask_channels', COALESCE((SELECT jsonb_agg(DISTINCT t.channel_code) FROM public.n_jtd_templates t
                               WHERE t.source_type_code = 'visit_slot_request' AND COALESCE(t.is_active, true) AND t.provider_template_id IS NOT NULL
                                 AND (t.tenant_id = p_tenant OR t.tenant_id IS NULL)), '[]'::jsonb),
    'generated_at', now());
END;
$$;

COMMENT ON FUNCTION public.jtd_ops_board(uuid, boolean, jsonb, uuid) IS
  'Ops cockpit board — collections (n_jtd payment jobs) + services (t_contract_events service visits) as ONE row model with lane, kind, anchor, bucket, owner; filters, facets, per-bucket paging server-side. Never returns totals. Spec: OPS-JTD-TOOLS-SPEC §5, §11.';

-- ─── 7. Activity timeline: event-audit rows of a SERVICE event read "Service visit", not "Billing event" ───
DO $$
DECLARE v_src text; v_n integer;
  v_old text := '(''Billing event '' || COALESCE(e.billing_cycle_label';
  v_new text := '((CASE WHEN e.event_type = ''service'' THEN ''Service visit '' ELSE ''Billing event '' END) || COALESCE(e.billing_cycle_label';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'jtd_contract_activity';
  IF v_src IS NULL THEN RAISE EXCEPTION '014: jtd_contract_activity not found'; END IF;
  IF position(v_new IN v_src) > 0 THEN RAISE NOTICE '014: activity title already lane-aware'; RETURN; END IF;
  v_n := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION '014: expected one title anchor in jtd_contract_activity, found %', v_n; END IF;
  EXECUTE replace(v_src, v_old, v_new);
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'jtd_contract_activity';
  IF position(v_new IN v_src) = 0 THEN RAISE EXCEPTION '014: activity title splice did not land'; END IF;
END $$;
