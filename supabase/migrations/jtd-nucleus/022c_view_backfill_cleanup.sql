-- ═══════════════════════════════════════════════════════════════════
-- 022c — backfill · t_appointments becomes a compatibility VIEW · cleanup
--
-- 1. every payment_call_due task row → a followups item on its payment job
--    (kind, due, assignee, set-by, outcome from the first call logged after
--    it); the task rows are retired (is_active=false), never deleted.
-- 2. every t_appointments row → an appointments item on its service job
--    (id, token, asked/ask_count/customer_response, statuses mapped:
--    requested → asked when the customer got the link else proposed,
--    accepted → confirmed, rescheduled → customer_proposed; cancelled ones
--    carry their reason as the outcome). Post-checked row for row.
-- 3. the table is renamed t_appointments_legacy_022 (kept, read-only, for a
--    later drop) and `t_appointments` becomes a VIEW over
--    n_jtd.appointments with the old columns (id = item id, event_id = job
--    id, legacy status codes, version = the job's version, is_active = the
--    job's latest item), plus INSTEAD OF triggers so the last plain
--    INSERT/UPDATE/DELETE writers route through the item tools. Readers
--    (get_contract_events_list, get_vani_briefing, get_appointments_list,
--    fn_enqueue_service_visit_scheduled, both Ops boards, jtd_assign_visit)
--    need no change.
-- 4. the nightly expiry cron and its function go (no silent rows to expire);
--    the confirmation trigger's job moved into the tools (022b).
-- Applied live 2026-09-17 (batch ops-items-on-jtd) — source of record.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. follow-ups ──────────────────────────────────────────────────
DO $do$
DECLARE v_rows integer; v_jobs integer; v_items integer;
BEGIN
  WITH tasks AS (
    SELECT n.*, l.outcome AS l_outcome, l.notes AS l_notes, l.created_at AS l_at, l.performed_by_name AS l_by,
           n.status_code IN ('assigned','in_progress','pending','created') AS is_open
      FROM public.n_jtd n
      LEFT JOIN LATERAL (SELECT x.metadata->>'outcome' AS outcome, x.notes, x.created_at, x.performed_by_name
                           FROM public.n_jtd x WHERE x.source_type_code = 'payment_call_logged' AND x.source_id = n.source_id AND x.created_at >= n.created_at
                          ORDER BY x.created_at LIMIT 1) l ON true
     WHERE n.source_type_code = 'payment_call_due' AND n.source_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.id = n.source_id)
       AND COALESCE(n.business_context->>'migrated_to_item', '') = ''
  ),
  items AS (
    SELECT source_id AS job_id, count(*) AS n, jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', id, 'kind', COALESCE(business_context->>'task_kind', 'escalation'),
      'status', CASE WHEN is_open THEN 'open' WHEN status_code = 'cancelled' THEN 'cancelled' ELSE 'done' END,
      'scheduled_at', scheduled_at, 'original_at', scheduled_at, 'assigned_to', assigned_to, 'assigned_to_name', assigned_to_name,
      'set_by', jsonb_strip_nulls(jsonb_build_object('type', performed_by_type, 'id', performed_by_id, 'name', performed_by_name, 'at', created_at)),
      'note', notes, 'rung', dunning_step, 'origin', business_context->>'origin',
      'closed_at', CASE WHEN NOT is_open THEN COALESCE(completed_at, l_at) END,
      'outcome', CASE WHEN NOT is_open THEN jsonb_strip_nulls(jsonb_build_object('code', COALESCE(l_outcome, CASE WHEN status_code = 'cancelled' THEN 'cancelled' ELSE 'done' END),
                   'note', l_notes, 'at', COALESCE(completed_at, l_at), 'by', jsonb_strip_nulls(jsonb_build_object('name', l_by)))) END,
      'created_at', created_at, 'updated_at', COALESCE(updated_at, created_at), 'migrated', 'jtd-nucleus/022', 'legacy_task_id', id)) ORDER BY created_at) AS arr
    FROM tasks GROUP BY source_id
  ),
  upd AS (
    UPDATE public.n_jtd j SET followups = COALESCE(j.followups, '[]'::jsonb) || i.arr, version = COALESCE(j.version, 0) + 1, updated_at = now()
      FROM items i WHERE j.id = i.job_id RETURNING i.n
  )
  SELECT count(*), COALESCE(sum(n), 0) INTO v_jobs, v_items FROM upd;

  UPDATE public.n_jtd t SET is_active = false,
         business_context = COALESCE(t.business_context, '{}'::jsonb) || jsonb_build_object('migrated_to_item', t.id, 'migration', 'jtd-nucleus/022'),
         updated_at = now()
   WHERE t.source_type_code = 'payment_call_due' AND t.source_id IS NOT NULL
     AND COALESCE(t.business_context->>'migrated_to_item', '') = ''
     AND EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.id = t.source_id);  -- t.source_id: an unqualified name here binds to j
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> v_items THEN RAISE EXCEPTION '022c follow-ups: % task rows but % items written', v_rows, v_items; END IF;
  RAISE NOTICE '022c follow-ups: % task rows → % items on % payment jobs', v_rows, v_items, v_jobs;
END $do$;

-- ─── 2. appointments ────────────────────────────────────────────────
DO $do$
DECLARE v_rows integer; v_jobs integer; v_items integer; v_missing integer;
BEGIN
  -- every appointment's event has a job (018); the guard stays for safety
  PERFORM public.jtd_ensure_visit_job(a.event_id) FROM (SELECT DISTINCT event_id FROM public.t_appointments WHERE event_id IS NOT NULL) a;
  SELECT count(*) INTO v_missing FROM public.t_appointments a WHERE a.event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.id = a.event_id);
  IF v_missing <> 0 THEN RAISE EXCEPTION '022c appointments: % rows have no commitment to attach to', v_missing; END IF;

  WITH rows AS (
    SELECT a.*, e.scheduled_date
      FROM public.t_appointments a LEFT JOIN public.t_contract_events e ON e.id = a.event_id
     WHERE a.event_id IS NOT NULL
  ),
  items AS (
    SELECT event_id AS job_id, count(*) AS n, jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', id, 'kind', 'site_visit',
      'status', CASE status WHEN 'requested' THEN CASE WHEN asked_at IS NOT NULL THEN 'asked' ELSE 'proposed' END
                            WHEN 'accepted' THEN 'confirmed' WHEN 'rescheduled' THEN 'customer_proposed' ELSE status END,
      'scheduled_at', scheduled_at,
      'original_at', COALESCE(NULLIF(proposed_slots->0->>'slot', '')::timestamptz, scheduled_at),
      'proposed_by', CASE WHEN customer_response->>'action' = 'propose' THEN 'customer' ELSE 'us' END,
      'proposed_slots', proposed_slots, 'assigned_to', assigned_to, 'assigned_to_name', assigned_to_name,
      'set_by', jsonb_strip_nulls(jsonb_build_object('type', CASE WHEN created_by IS NOT NULL THEN 'user' ELSE 'system' END, 'id', created_by, 'at', created_at)),
      'note', notes, 'token', slot_token, 'asked_at', asked_at, 'ask_count', COALESCE(ask_count, 0), 'customer_response', customer_response,
      'is_active', COALESCE(is_active, true),
      'closed_at', CASE WHEN status IN ('cancelled','declined','completed','no_response') THEN updated_at END,
      'outcome', CASE WHEN status IN ('cancelled','declined','completed','no_response') THEN jsonb_strip_nulls(jsonb_build_object('code', status, 'at', updated_at,
                   'note', CASE WHEN notes ILIKE '%cancelled —%' OR notes ILIKE '%auto-expired%' THEN notes END)) END,
      'created_at', created_at, 'updated_at', COALESCE(updated_at, created_at), 'migrated', 'jtd-nucleus/022')) ORDER BY created_at) AS arr
    FROM rows GROUP BY event_id
  ),
  upd AS (
    UPDATE public.n_jtd j SET appointments = COALESCE(j.appointments, '[]'::jsonb) || i.arr, version = COALESCE(j.version, 0) + 1, updated_at = now()
      FROM items i WHERE j.id = i.job_id RETURNING i.n
  )
  SELECT count(*), COALESCE(sum(n), 0) INTO v_jobs, v_items FROM upd;
  SELECT count(*) INTO v_rows FROM public.t_appointments WHERE event_id IS NOT NULL;
  IF v_rows <> v_items THEN RAISE EXCEPTION '022c appointments: % rows but % items written', v_rows, v_items; END IF;
  -- row-for-row: every legacy id is findable on its job
  SELECT count(*) INTO v_missing FROM public.t_appointments a
   WHERE a.event_id IS NOT NULL AND public.jtd_item_find(a.event_id, 'appointment', a.id) IS NULL;
  IF v_missing <> 0 THEN RAISE EXCEPTION '022c appointments: % rows not found as items after backfill', v_missing; END IF;
  RAISE NOTICE '022c appointments: % rows → % items on % service jobs', v_rows, v_items, v_jobs;
END $do$;

-- ─── 3. the table steps aside; the view keeps every reader honest ───
DROP TRIGGER IF EXISTS trg_zz_notif_appointment_confirmed ON public.t_appointments;
ALTER TABLE public.t_appointments RENAME TO t_appointments_legacy_022;
COMMENT ON TABLE public.t_appointments_legacy_022 IS '022: the pre-2026-09-17 appointments table, kept read-only for a later drop. Truth is n_jtd.appointments; t_appointments is a view over it.';

CREATE VIEW public.t_appointments AS
SELECT (x.it->>'id')::uuid                                   AS id,
       j.tenant_id,
       j.contract_id,
       j.id                                                  AS event_id,
       public.jtd__appt_legacy_status(x.it->>'status')       AS status,
       COALESCE(x.it->'proposed_slots',
                CASE WHEN x.it->>'scheduled_at' IS NOT NULL THEN jsonb_build_array(jsonb_build_object('slot', x.it->'scheduled_at', 'note', 'slot')) ELSE '[]'::jsonb END) AS proposed_slots,
       (x.it->>'scheduled_at')::timestamptz                  AS scheduled_at,
       (x.it->>'assigned_to')::uuid                          AS assigned_to,
       x.it->>'assigned_to_name'                             AS assigned_to_name,
       x.it->>'note'                                         AS notes,
       (x.it->>'updated_at')::timestamptz                    AS last_activity_at,
       COALESCE(j.version, 1)                                AS version,
       COALESCE(j.is_live, true)                             AS is_live,
       (COALESCE((x.it->>'is_active')::boolean, true) AND x.rn = 1) AS is_active,
       (x.it->>'created_at')::timestamptz                    AS created_at,
       (x.it->>'updated_at')::timestamptz                    AS updated_at,
       NULLIF(x.it->'set_by'->>'id', '')::uuid               AS created_by,
       NULL::uuid                                            AS updated_by,
       NULL::uuid                                            AS group_session_occurrence_id,
       NULLIF(x.it->>'token', '')::uuid                      AS slot_token,
       (x.it->>'asked_at')::timestamptz                      AS asked_at,
       COALESCE((x.it->>'ask_count')::integer, 0)            AS ask_count,
       x.it->'customer_response'                             AS customer_response
  FROM public.n_jtd j
  CROSS JOIN LATERAL (
    SELECT t.e AS it, row_number() OVER (ORDER BY (t.e->>'created_at')::timestamptz DESC NULLS LAST, t.ord DESC) AS rn
      FROM jsonb_array_elements(j.appointments) WITH ORDINALITY t(e, ord)
  ) x
 WHERE j.appointments <> '[]'::jsonb;

COMMENT ON VIEW public.t_appointments IS
  '022: compatibility view over n_jtd.appointments — id = item id, event_id = the commitment (job) id, status in the legacy codes (requested/accepted/rescheduled/…), version = the job''s version, is_active = the job''s latest item. INSTEAD OF triggers route INSERT/UPDATE/DELETE through the jtd_item_* tools. New code reads the arrays and calls the tools directly.';

CREATE OR REPLACE FUNCTION public.trg_fn_t_appointments_view()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_job record; v_r jsonb; v_patch jsonb := '{}'::jsonb; v_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.group_session_occurrence_id IS NOT NULL THEN
      RAISE EXCEPTION '022: a group-session chair assignment lives on t_group_session_schedule, not on appointments';
    END IF;
    IF NEW.event_id IS NULL THEN RAISE EXCEPTION '022: an appointment needs event_id — the commitment it belongs to'; END IF;
    PERFORM public.jtd_ensure_visit_job(NEW.event_id);
    SELECT id, tenant_id INTO v_job FROM public.n_jtd WHERE id = NEW.event_id;
    IF v_job.id IS NULL THEN RAISE EXCEPTION '022: no commitment for event %', NEW.event_id; END IF;
    v_r := public.jtd_item_add(v_job.tenant_id, v_job.id, 'appointment',
             jsonb_strip_nulls(jsonb_build_object('id', NEW.id,
               'status', public.jtd__appt_item_status(COALESCE(NEW.status, 'requested'), NEW.asked_at IS NOT NULL),
               'scheduled_at', NEW.scheduled_at, 'proposed_slots', NEW.proposed_slots, 'proposed_by', 'us',
               'assigned_to', NEW.assigned_to, 'assigned_to_name', NEW.assigned_to_name, 'note', NEW.notes,
               'token', NEW.slot_token, 'asked_at', NEW.asked_at, 'ask_count', NEW.ask_count, 'customer_response', NEW.customer_response,
               'is_active', NEW.is_active)),
             CASE WHEN NEW.created_by IS NOT NULL THEN 'user' ELSE 'system' END, NEW.created_by, NULL, NEW.notes, NULL, 'appointment_added');
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      IF v_r->>'reason' = 'slot_already_open' THEN
        RAISE unique_violation USING MESSAGE = 'an open appointment already exists for this event', CONSTRAINT = 'uq_appointments_event';
      END IF;
      RAISE EXCEPTION '022: appointment insert refused: %', v_r->>'reason';
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    SELECT id, tenant_id INTO v_job FROM public.n_jtd
     WHERE appointments @> jsonb_build_array(jsonb_build_object('id', OLD.id::text)) LIMIT 1;
    IF v_job.id IS NULL THEN RETURN NULL; END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      v_status := public.jtd__appt_item_status(NEW.status, COALESCE(NEW.asked_at, OLD.asked_at) IS NOT NULL);
      v_patch := v_patch || jsonb_build_object('status', v_status);
      IF NOT public.jtd_item_is_open('appointment', jsonb_build_object('status', v_status)) THEN
        v_patch := v_patch || jsonb_build_object('closed_at', now(), 'outcome', jsonb_build_object('code', NEW.status, 'at', now()));
      END IF;
    END IF;
    IF NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at THEN
      v_patch := v_patch || jsonb_build_object('scheduled_at', NEW.scheduled_at);
      IF OLD.scheduled_at IS NOT NULL THEN v_patch := v_patch || jsonb_build_object('original_at', COALESCE((public.jtd_item_find(v_job.id, 'appointment', OLD.id))->'original_at', to_jsonb(OLD.scheduled_at))); END IF;
    END IF;
    IF NEW.proposed_slots IS DISTINCT FROM OLD.proposed_slots THEN v_patch := v_patch || jsonb_build_object('proposed_slots', NEW.proposed_slots); END IF;
    IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN v_patch := v_patch || jsonb_build_object('assigned_to', NEW.assigned_to); END IF;
    IF NEW.assigned_to_name IS DISTINCT FROM OLD.assigned_to_name THEN v_patch := v_patch || jsonb_build_object('assigned_to_name', NEW.assigned_to_name); END IF;
    IF NEW.notes IS DISTINCT FROM OLD.notes THEN v_patch := v_patch || jsonb_build_object('note', NEW.notes); END IF;
    IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN v_patch := v_patch || jsonb_build_object('is_active', NEW.is_active); END IF;
    IF NEW.slot_token IS DISTINCT FROM OLD.slot_token THEN v_patch := v_patch || jsonb_build_object('token', NEW.slot_token); END IF;
    IF NEW.asked_at IS DISTINCT FROM OLD.asked_at THEN v_patch := v_patch || jsonb_build_object('asked_at', NEW.asked_at); END IF;
    IF NEW.ask_count IS DISTINCT FROM OLD.ask_count THEN v_patch := v_patch || jsonb_build_object('ask_count', NEW.ask_count); END IF;
    IF NEW.customer_response IS DISTINCT FROM OLD.customer_response THEN v_patch := v_patch || jsonb_build_object('customer_response', NEW.customer_response); END IF;
    IF v_patch = '{}'::jsonb THEN RETURN NEW; END IF;
    v_r := public.jtd_item_write(v_job.tenant_id, v_job.id, 'appointment', OLD.id, v_patch, 'appointment_updated',
             CASE WHEN NEW.updated_by IS NOT NULL THEN 'user' ELSE 'system' END, NEW.updated_by, NULL, NULL, NULL);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION '022: appointment update refused: %', v_r->>'reason'; END IF;
    RETURN NEW;

  ELSE
    UPDATE public.n_jtd
       SET appointments = (SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(appointments) e WHERE e->>'id' <> OLD.id::text),
           version = COALESCE(version, 0) + 1, updated_at = now()
     WHERE appointments @> jsonb_build_array(jsonb_build_object('id', OLD.id::text));
    RETURN OLD;
  END IF;
END;
$$;

CREATE TRIGGER trg_t_appointments_view_ins INSTEAD OF INSERT ON public.t_appointments FOR EACH ROW EXECUTE FUNCTION public.trg_fn_t_appointments_view();
CREATE TRIGGER trg_t_appointments_view_upd INSTEAD OF UPDATE ON public.t_appointments FOR EACH ROW EXECUTE FUNCTION public.trg_fn_t_appointments_view();
CREATE TRIGGER trg_t_appointments_view_del INSTEAD OF DELETE ON public.t_appointments FOR EACH ROW EXECUTE FUNCTION public.trg_fn_t_appointments_view();

-- view row count == item count (the view shows every item; is_active marks the job's latest)
DO $do$
DECLARE v_view integer; v_items integer;
BEGIN
  SELECT count(*) INTO v_view FROM public.t_appointments;
  SELECT COALESCE(sum(jsonb_array_length(appointments)), 0) INTO v_items FROM public.n_jtd WHERE appointments <> '[]'::jsonb;
  IF v_view <> v_items THEN RAISE EXCEPTION '022c view: % rows vs % items', v_view, v_items; END IF;
END $do$;

-- ─── 4. cleanup ─────────────────────────────────────────────────────
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'appointment-auto-expire') THEN PERFORM cron.unschedule('appointment-auto-expire'); END IF;
END $do$;
DROP FUNCTION IF EXISTS public.expire_stale_appointment_requests();
DROP FUNCTION IF EXISTS public.trg_fn_notif_appointment_confirmed();
