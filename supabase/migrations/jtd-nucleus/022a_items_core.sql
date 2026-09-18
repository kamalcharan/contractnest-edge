-- ═══════════════════════════════════════════════════════════════════
-- 022a — follow-ups and appointments live ON the commitment (n_jtd row)
--        as JSON items: one skeleton, one set of tools, one history
--
-- Owner (2026-09-17): "appointments and followups should share the same
-- infra — type, status, assigned to, what time, reschedule, assigned by,
-- service to (buyer)"; "t_appointments will not be needed — n_jtd events
-- like billing, services might have followups json records, they might
-- have appointment jsons against them".
--
-- Two jsonb columns on n_jtd (not buried in payload, so they index):
--   followups    [ {id, kind: follow_up|escalation|call, status: open|done|
--                   cancelled, scheduled_at, original_at, assigned_to,
--                   assigned_to_name, set_by{type,id,name,at}, note, rung,
--                   origin, rescheduled[], outcome{code,note,by,at},
--                   closed_at, created_at, updated_at} ]
--   appointments [ {id, kind: site_visit|call, status: proposed|asked|
--                   confirmed|customer_proposed|no_response|declined|
--                   completed|no_show|cancelled, scheduled_at, original_at,
--                   proposed_by: us|customer, proposed_slots, assigned_to,
--                   assigned_to_name, set_by, note, token, asked_at,
--                   ask_count, customer_response, is_active, rescheduled[],
--                   outcome, closed_at, created_at, updated_at} ]
-- "Service to" is the parent row (recipient_*, contract_id, block_name).
-- Rules: one OPEN appointment per commitment (the slot); any number of
-- follow-ups. Every change is a tool call on (job, item) with the actor
-- triple, under FOR UPDATE on the parent, version bump, one
-- n_jtd_history row carrying details.item_id. Item-level writes: the tool
-- never writes the array back from what a screen had — it patches the one
-- item inside the locked row, so two people editing different items on the
-- same commitment both land. Optional p_expected_version for screens.
--
-- 022a = columns · indexes · helpers · the four generic tools.
-- 022b = every existing entry point rewired onto them.
-- 022c = backfill · t_appointments becomes a compatibility VIEW · cleanup.
-- Applied live 2026-09-17 (batch ops-items-on-jtd) — source of record; do
-- not re-run.
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE public.n_jtd
  ADD COLUMN IF NOT EXISTS followups    jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS appointments jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE INDEX IF NOT EXISTS idx_n_jtd_followups_gin
  ON public.n_jtd USING gin (followups jsonb_path_ops) WHERE followups <> '[]'::jsonb;
CREATE INDEX IF NOT EXISTS idx_n_jtd_appointments_gin
  ON public.n_jtd USING gin (appointments jsonb_path_ops) WHERE appointments <> '[]'::jsonb;

COMMENT ON COLUMN public.n_jtd.followups IS
  '022: follow-ups / escalations on this commitment — items {id, kind, status open|done|cancelled, scheduled_at, original_at, assigned_to(_name), set_by, note, rung, outcome, closed_at}. Written only by jtd_item_* tools.';
COMMENT ON COLUMN public.n_jtd.appointments IS
  '022: the customer-facing slot(s) for this commitment — items {id, kind, status proposed|asked|confirmed|customer_proposed|no_response|declined|completed|no_show|cancelled, scheduled_at, original_at, proposed_by, assigned_to(_name), set_by, note, token, asked_at, ask_count, customer_response, is_active, outcome}. One OPEN item at a time. Written only by jtd_item_* tools; t_appointments is a compatibility view over this.';

-- ─── helpers ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_item_is_open(p_type text, p_item jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'followup'    THEN COALESCE(p_item->>'status', 'open') = 'open'
    WHEN 'appointment' THEN COALESCE((p_item->>'is_active')::boolean, true)
                            AND COALESCE(p_item->>'status', 'proposed') IN ('proposed','asked','confirmed','customer_proposed')
    ELSE false END;
$$;

-- legacy (t_appointments) status ⇄ item status
CREATE OR REPLACE FUNCTION public.jtd__appt_legacy_status(p_item_status text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_item_status
    WHEN 'proposed' THEN 'requested' WHEN 'asked' THEN 'requested'
    WHEN 'confirmed' THEN 'accepted' WHEN 'customer_proposed' THEN 'rescheduled'
    ELSE COALESCE(p_item_status, 'requested') END;
$$;
CREATE OR REPLACE FUNCTION public.jtd__appt_item_status(p_legacy text, p_asked boolean)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_legacy
    WHEN 'requested' THEN CASE WHEN COALESCE(p_asked, false) THEN 'asked' ELSE 'proposed' END
    WHEN 'accepted' THEN 'confirmed' WHEN 'rescheduled' THEN 'customer_proposed'
    ELSE COALESCE(p_legacy, 'proposed') END;
$$;

-- the item (no lock) — callers lock the parent first when they intend to write
CREATE OR REPLACE FUNCTION public.jtd_item_find(p_job_id uuid, p_type text, p_item_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT e FROM public.n_jtd j
  CROSS JOIN LATERAL jsonb_array_elements(CASE p_type WHEN 'followup' THEN j.followups ELSE j.appointments END) e
  WHERE j.id = p_job_id AND e->>'id' = p_item_id::text LIMIT 1;
$$;

-- the open item: appointments have at most one; follow-ups → the earliest due
CREATE OR REPLACE FUNCTION public.jtd_item_open(p_job_id uuid, p_type text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT e FROM public.n_jtd j
  CROSS JOIN LATERAL jsonb_array_elements(CASE p_type WHEN 'followup' THEN j.followups ELSE j.appointments END) WITH ORDINALITY t(e, ord)
  WHERE j.id = p_job_id AND public.jtd_item_is_open(p_type, e)
  ORDER BY (e->>'scheduled_at')::timestamptz ASC NULLS LAST, ord DESC LIMIT 1;
$$;

-- the mirror row for a contract event when it is missing (018's insert, one event) — returns the job id
CREATE OR REPLACE FUNCTION public.jtd_ensure_visit_job(p_event_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.n_jtd WHERE id = p_event_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO public.n_jtd (id, tenant_id, contract_id, block_id, block_name, category_id,
      event_type_code, source_type_code, source_id, source_ref,
      scheduled_at, original_date, sequence_number, total_occurrences,
      billing_sub_type, billing_cycle_label, amount, amount_settled, currency,
      invoice_id, status_code, status_changed_at, completed_at,
      task_id, reminder_jtd_id, reminder_dispatched_at,
      assigned_to, assigned_to_name, notes, version, is_active, is_live, audience,
      performed_by_type, priority, business_context,
      created_at, updated_at, created_by, updated_by)
  SELECT e.id, e.tenant_id, e.contract_id, e.block_id, e.block_name, e.category_id,
      CASE e.event_type WHEN 'service' THEN 'service_visit' ELSE 'payment' END,
      CASE e.event_type WHEN 'service' THEN 'service_scheduled' ELSE 'payment_scheduled' END,
      e.contract_id, c.contract_number,
      e.scheduled_date, e.original_date, e.sequence_number, e.total_occurrences,
      e.billing_sub_type, e.billing_cycle_label, e.amount, e.amount_settled, e.currency,
      e.invoice_id, e.status, COALESCE(e.updated_at, e.created_at, now()),
      CASE WHEN e.status IN ('paid','completed') THEN COALESCE(e.updated_at, e.created_at, now()) ELSE NULL END,
      e.task_id, e.reminder_jtd_id, e.reminder_dispatched_at,
      e.assigned_to, e.assigned_to_name, e.notes, e.version, e.is_active, e.is_live, e.audience,
      'system', 5,
      jsonb_build_object('migrated_from', 't_contract_events', 'migration', 'jtd-nucleus/022', 'migrated_at', now()),
      COALESCE(e.created_at, now()), COALESCE(e.updated_at, e.created_at, now()), e.created_by, e.updated_by
    FROM public.t_contract_events e JOIN public.t_contracts c ON c.id = e.contract_id
   WHERE e.id = p_event_id
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ─── the one writer: lock · version · patch one item · history ─────
CREATE OR REPLACE FUNCTION public.jtd_item_write(
  p_tenant uuid, p_job_id uuid, p_type text, p_item_id uuid, p_patch jsonb, p_action text,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL, p_expected_version integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job public.n_jtd%ROWTYPE; v_arr jsonb; v_item jsonb; v_idx integer; v_id uuid; v_open jsonb;
  v_patch jsonb := COALESCE(p_patch, '{}'::jsonb); v_now timestamptz := now();
BEGIN
  IF p_type NOT IN ('followup','appointment') THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_type'); END IF;
  IF p_actor_type NOT IN ('user','vani','system','customer','webhook') OR (p_actor_type = 'user' AND p_actor_id IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
  END IF;
  SELECT * INTO v_job FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'job_not_found'); END IF;
  IF p_expected_version IS NOT NULL AND COALESCE(v_job.version, 1) <> p_expected_version THEN
    RETURN jsonb_build_object('success', false, 'reason', 'version_conflict', 'current_version', COALESCE(v_job.version, 1));
  END IF;
  v_arr := COALESCE(CASE p_type WHEN 'followup' THEN v_job.followups ELSE v_job.appointments END, '[]'::jsonb);

  IF p_item_id IS NULL THEN
    -- ADD (idempotent on a caller-supplied id)
    v_id := COALESCE(NULLIF(v_patch->>'id', '')::uuid, gen_random_uuid());
    SELECT t.ord - 1, t.e INTO v_idx, v_item FROM jsonb_array_elements(v_arr) WITH ORDINALITY t(e, ord) WHERE t.e->>'id' = v_id::text;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'already', true, 'job_id', p_job_id, 'type', p_type, 'item', v_item, 'version', COALESCE(v_job.version, 1));
    END IF;
    IF p_type = 'appointment' THEN
      SELECT t.e INTO v_open FROM jsonb_array_elements(v_arr) t(e) WHERE public.jtd_item_is_open('appointment', t.e) LIMIT 1;
      IF v_open IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'slot_already_open', 'item', v_open, 'version', COALESCE(v_job.version, 1));
      END IF;
    END IF;
    v_item := CASE p_type
      WHEN 'followup' THEN jsonb_build_object('kind', 'follow_up', 'status', 'open')
      ELSE jsonb_build_object('kind', 'site_visit', 'status', 'proposed', 'proposed_by', 'us', 'ask_count', 0, 'is_active', true) END
      || jsonb_strip_nulls(v_patch - 'id')
      || jsonb_build_object('id', v_id,
           'set_by', jsonb_strip_nulls(jsonb_build_object('type', p_actor_type, 'id', p_actor_id, 'name', p_actor_name, 'at', v_now)),
           'created_at', v_now, 'updated_at', v_now);
    IF v_item->>'original_at' IS NULL AND v_item->>'scheduled_at' IS NOT NULL THEN
      v_item := v_item || jsonb_build_object('original_at', v_item->'scheduled_at');
    END IF;
    v_arr := v_arr || jsonb_build_array(v_item);
  ELSE
    -- PATCH one item in place
    SELECT t.ord - 1, t.e INTO v_idx, v_item FROM jsonb_array_elements(v_arr) WITH ORDINALITY t(e, ord) WHERE t.e->>'id' = p_item_id::text;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'reason', 'item_not_found'); END IF;
    v_item := v_item || (v_patch - 'id') || jsonb_build_object('updated_at', v_now);
    v_arr := jsonb_set(v_arr, ARRAY[v_idx::text], v_item, false);
  END IF;

  IF p_type = 'followup' THEN
    UPDATE public.n_jtd SET followups = v_arr, version = COALESCE(version, 0) + 1, updated_at = v_now WHERE id = p_job_id;
  ELSE
    UPDATE public.n_jtd SET appointments = v_arr, version = COALESCE(version, 0) + 1, updated_at = v_now WHERE id = p_job_id;
  END IF;

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, left(COALESCE(p_action, p_type || '_updated'), 30), p_actor_type, p_actor_id, p_actor_name,
          jsonb_strip_nulls(jsonb_build_object('type', p_type, 'item_id', v_item->>'id', 'kind', v_item->>'kind', 'status', v_item->>'status',
            'scheduled_at', v_item->'scheduled_at', 'assigned_to', v_item->'assigned_to', 'assigned_to_name', v_item->'assigned_to_name',
            'patch', CASE WHEN p_item_id IS NULL THEN NULL ELSE v_patch - 'id' END)),
          p_note, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'job_id', p_job_id, 'type', p_type, 'item', v_item, 'version', COALESCE(v_job.version, 0) + 1);
END;
$$;

-- ─── the four tools ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_item_add(
  p_tenant uuid, p_job_id uuid, p_type text, p_item jsonb,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL, p_expected_version integer DEFAULT NULL,
  p_action text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_item ? 'scheduled_at' AND (p_item->>'scheduled_at')::timestamptz < now() - interval '1 day' THEN
    RETURN jsonb_build_object('success', false, 'reason', CASE p_type WHEN 'appointment' THEN 'slot_in_past' ELSE 'due_in_past' END);
  END IF;
  RETURN public.jtd_item_write(p_tenant, p_job_id, p_type, NULL, p_item, COALESCE(p_action, p_type || '_added'),
                               p_actor_type, p_actor_id, p_actor_name, p_note, p_expected_version);
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_item_assign(
  p_tenant uuid, p_job_id uuid, p_type text, p_item_id uuid, p_assign_to uuid,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL, p_expected_version integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text; v_item jsonb;
BEGIN
  PERFORM 1 FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant FOR UPDATE;
  v_item := public.jtd_item_find(p_job_id, p_type, p_item_id);
  IF v_item IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'item_not_found'); END IF;
  IF NOT public.jtd_item_is_open(p_type, v_item) THEN RETURN jsonb_build_object('success', false, 'reason', 'item_closed', 'status', v_item->>'status'); END IF;
  IF p_assign_to IS NOT NULL THEN
    SELECT COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email) INTO v_name
      FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
     WHERE ut.tenant_id = p_tenant AND ut.user_id = p_assign_to LIMIT 1;
    IF v_name IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'assignee_not_in_tenant'); END IF;
  END IF;
  RETURN public.jtd_item_write(p_tenant, p_job_id, p_type, p_item_id,
           jsonb_build_object('assigned_to', p_assign_to, 'assigned_to_name', v_name),
           p_type || '_assigned', p_actor_type, p_actor_id, p_actor_name, p_note, p_expected_version);
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_item_reschedule(
  p_tenant uuid, p_job_id uuid, p_type text, p_item_id uuid, p_scheduled_at timestamptz, p_reason text,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_status text DEFAULT NULL, p_expected_version integer DEFAULT NULL,
  p_action text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item jsonb; v_from timestamptz; v_patch jsonb;
BEGIN
  IF p_scheduled_at IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'scheduled_at_required'); END IF;
  IF p_scheduled_at < now() - interval '1 day' THEN RETURN jsonb_build_object('success', false, 'reason', CASE p_type WHEN 'appointment' THEN 'slot_in_past' ELSE 'due_in_past' END); END IF;
  PERFORM 1 FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant FOR UPDATE;
  v_item := public.jtd_item_find(p_job_id, p_type, p_item_id);
  IF v_item IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'item_not_found'); END IF;
  IF NOT public.jtd_item_is_open(p_type, v_item) THEN RETURN jsonb_build_object('success', false, 'reason', 'item_closed', 'status', v_item->>'status'); END IF;
  v_from := (v_item->>'scheduled_at')::timestamptz;
  v_patch := jsonb_build_object('scheduled_at', p_scheduled_at,
               'original_at', COALESCE(v_item->'original_at', v_item->'scheduled_at', to_jsonb(p_scheduled_at)),
               'rescheduled', COALESCE(v_item->'rescheduled', '[]'::jsonb) || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                                'from', v_from, 'to', p_scheduled_at, 'reason', p_reason, 'at', now(),
                                'by', jsonb_strip_nulls(jsonb_build_object('type', p_actor_type, 'id', p_actor_id, 'name', p_actor_name))))));
  IF p_status IS NOT NULL THEN v_patch := v_patch || jsonb_build_object('status', p_status); END IF;
  RETURN public.jtd_item_write(p_tenant, p_job_id, p_type, p_item_id, v_patch, COALESCE(p_action, p_type || '_rescheduled'),
                               p_actor_type, p_actor_id, p_actor_name, p_reason, p_expected_version);
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_item_close(
  p_tenant uuid, p_job_id uuid, p_type text, p_item_id uuid, p_outcome text,
  p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL, p_expected_version integer DEFAULT NULL,
  p_action text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item jsonb; v_status text;
BEGIN
  v_status := CASE p_type
    WHEN 'followup' THEN CASE WHEN p_outcome IN ('done','reached','no_answer','promised','disputed','other') THEN 'done'
                              WHEN p_outcome = 'cancelled' THEN 'cancelled' END
    ELSE CASE p_outcome WHEN 'completed' THEN 'completed' WHEN 'cancelled' THEN 'cancelled' WHEN 'declined' THEN 'declined'
                        WHEN 'not_needed' THEN 'declined' WHEN 'no_show' THEN 'no_show' WHEN 'no_response' THEN 'no_response' END END;
  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_outcome'); END IF;
  PERFORM 1 FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant FOR UPDATE;
  v_item := public.jtd_item_find(p_job_id, p_type, p_item_id);
  IF v_item IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'item_not_found'); END IF;
  IF NOT public.jtd_item_is_open(p_type, v_item) THEN RETURN jsonb_build_object('success', false, 'reason', 'item_closed', 'status', v_item->>'status'); END IF;
  RETURN public.jtd_item_write(p_tenant, p_job_id, p_type, p_item_id,
           jsonb_build_object('status', v_status, 'closed_at', now(),
             'outcome', jsonb_strip_nulls(jsonb_build_object('code', p_outcome, 'note', p_note, 'at', now(),
               'by', jsonb_strip_nulls(jsonb_build_object('type', p_actor_type, 'id', p_actor_id, 'name', p_actor_name))))),
           COALESCE(p_action, p_type || '_closed'), p_actor_type, p_actor_id, p_actor_name, p_note, p_expected_version);
END;
$$;

-- close every open appointment item on a job (visit done / cancelled)
CREATE OR REPLACE FUNCTION public.jtd__close_open_appointments(
  p_tenant uuid, p_job_id uuid, p_outcome text, p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item jsonb; v_n integer := 0; v_r jsonb;
BEGIN
  LOOP
    v_item := public.jtd_item_open(p_job_id, 'appointment');
    EXIT WHEN v_item IS NULL;
    v_r := public.jtd_item_close(p_tenant, p_job_id, 'appointment', (v_item->>'id')::uuid, p_outcome, p_actor_type, p_actor_id, p_actor_name, p_note);
    EXIT WHEN NOT COALESCE((v_r->>'success')::boolean, false);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;

COMMENT ON FUNCTION public.jtd_item_write(uuid, uuid, text, uuid, jsonb, text, text, uuid, text, text, integer) IS
  '022: the one writer for followups/appointments items — FOR UPDATE on the parent job, optional version check (version_conflict), ADD (idempotent on a supplied id; slot_already_open for a second open appointment) or PATCH one item by id, version bump, one n_jtd_history row with details.item_id. Refusals: bad_type · actor_required · job_not_found · version_conflict · slot_already_open · item_not_found.';
COMMENT ON FUNCTION public.jtd_item_add(uuid, uuid, text, jsonb, text, uuid, text, text, integer, text) IS '022 tool: add a follow-up or an appointment item to a commitment.';
COMMENT ON FUNCTION public.jtd_item_assign(uuid, uuid, text, uuid, uuid, text, uuid, text, text, integer) IS '022 tool: (re)assign an item to a tenant user (NULL = unassign). Refuses assignee_not_in_tenant · item_closed.';
COMMENT ON FUNCTION public.jtd_item_reschedule(uuid, uuid, text, uuid, timestamptz, text, text, uuid, text, text, integer, text) IS '022 tool: move an item''s time; keeps original_at and appends to rescheduled[] with who/why. Optional p_status.';
COMMENT ON FUNCTION public.jtd_item_close(uuid, uuid, text, uuid, text, text, uuid, text, text, integer, text) IS '022 tool: close an item with an outcome — followup: done|cancelled|reached|no_answer|promised|disputed|other; appointment: completed|cancelled|declined|not_needed|no_show|no_response.';
