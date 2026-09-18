-- ============================================================================
-- jtd-nucleus/024 — AVAILABILITY: working hours, leave, visit duration, clashes
-- ----------------------------------------------------------------------------
-- POA batch 2 (owner 2026-09-18: "go to batch 2"). The three fields the
-- Timeboard grids need, and the clash check that makes "asked ×2, no reply"
-- and a slot in the middle of someone's leave visible before the customer
-- confirms it.
--
--   Tenant defaults (existing t_tenant_cadence_settings, which already holds
--   weekly_holidays + t_tenant_holiday_dates): work_start 09:00, work_end
--   18:00, default_visit_minutes 60 — edited on /settings/configure/cadence.
--   Per user (new t_user_availability): hours and weekly off, NULL = inherit
--   the tenant's. Per user leave (new t_user_leave): a date, full / morning /
--   afternoon, a label. Edited on the user's page under Settings → Users.
--
--   jtd_effective_hours(tenant, user)      the hours that apply to a person
--   jtd_visit_minutes(event)               the block's config.duration (value +
--                                          unit) else the tenant default
--   jtd_slot_check(tenant, user, start, minutes, exclude_event)
--                                          [] or [{kind, detail, event_id?}]:
--                                          weekly_off · holiday · leave ·
--                                          outside_hours · overlap (only against
--                                          services that HAVE a timed slot —
--                                          event rows carry their creation
--                                          clock time, never a real time)
--   A clash is a WARNING, never a refusal: jtd_schedule_visit, jtd_confirm_
--   visit_slot and jtd_assign_visit return `warnings`; jtd_ops_board visit
--   rows carry visit.duration_minutes + visit.clashes; jtd__plan_counts
--   counts `clashes`; jtd_plan_day starts from the tenant's work_start,
--   steps by the default visit length, and refuses a tenant day off.
--   Appointment items gain duration_minutes (new ones at add; existing ones
--   back-filled here).
--
-- Additive. No rows deleted. Source of record for what is live.
-- ============================================================================

-- ── 1. tenant defaults on the cadence settings ──────────────────────────────
ALTER TABLE public.t_tenant_cadence_settings
  ADD COLUMN IF NOT EXISTS work_start time NOT NULL DEFAULT '09:00'::time,
  ADD COLUMN IF NOT EXISTS work_end   time NOT NULL DEFAULT '18:00'::time,
  ADD COLUMN IF NOT EXISTS default_visit_minutes integer NOT NULL DEFAULT 60;
COMMENT ON COLUMN public.t_tenant_cadence_settings.work_start IS '024: the organisation''s working day starts (IST). Per-user overrides in t_user_availability.';
COMMENT ON COLUMN public.t_tenant_cadence_settings.default_visit_minutes IS '024: how long a service visit is assumed to take when the block carries no config.duration.';

-- the getter now returns the three (anchor rewrite, post-checked by jtd__rewrite_fn)
SELECT public.jtd__rewrite_fn('get_tenant_cadence_settings',
  $old$  RETURN jsonb_build_object('weekly_holidays', to_jsonb(v_settings.weekly_holidays), 'default_shift', v_settings.default_shift, 'holidays', v_holidays);$old$,
  $new$  RETURN jsonb_build_object('weekly_holidays', to_jsonb(v_settings.weekly_holidays), 'default_shift', v_settings.default_shift, 'holidays', v_holidays,
                            'work_start', to_char(COALESCE(v_settings.work_start, '09:00'::time), 'HH24:MI'), 'work_end', to_char(COALESCE(v_settings.work_end, '18:00'::time), 'HH24:MI'),
                            'default_visit_minutes', COALESCE(v_settings.default_visit_minutes, 60));$new$,
  '024 cadence getter');

CREATE OR REPLACE FUNCTION public.upsert_tenant_working_hours(
  p_tenant uuid, p_work_start time, p_work_end time, p_default_visit_minutes integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'tenant_required'); END IF;
  IF p_work_start IS NULL OR p_work_end IS NULL OR p_work_end <= p_work_start THEN
    RETURN jsonb_build_object('success', false, 'reason', 'bad_hours', 'message', 'The working day must end after it starts');
  END IF;
  IF p_default_visit_minutes IS NULL OR p_default_visit_minutes < 15 OR p_default_visit_minutes > 480 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'bad_minutes', 'message', 'A visit is between 15 minutes and 8 hours');
  END IF;
  PERFORM public.seed_cadence_defaults(p_tenant);
  UPDATE public.t_tenant_cadence_settings
     SET work_start = p_work_start, work_end = p_work_end, default_visit_minutes = p_default_visit_minutes, updated_at = now()
   WHERE tenant_id = p_tenant;
  RETURN jsonb_build_object('success', true) || public.get_tenant_cadence_settings(p_tenant);
END;
$$;
COMMENT ON FUNCTION public.upsert_tenant_working_hours(uuid, time, time, integer) IS '024: the organisation''s working hours and default visit length (Settings → Cadence).';

-- ── 2. per-user hours and leave ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.t_user_availability (
  tenant_id  uuid NOT NULL,
  user_id    uuid NOT NULL,
  work_start time,                      -- NULL = the tenant's
  work_end   time,
  weekly_off integer[],                 -- 0=Sun … 6=Sat; NULL = the tenant's weekly_holidays
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (tenant_id, user_id),
  CONSTRAINT chk_user_hours CHECK (work_start IS NULL OR work_end IS NULL OR work_end > work_start)
);
COMMENT ON TABLE public.t_user_availability IS '024: a person''s working hours and weekly off in a tenant; NULL columns inherit the tenant''s cadence settings.';
CREATE TABLE IF NOT EXISTS public.t_user_leave (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL,
  user_id    uuid NOT NULL,
  leave_date date NOT NULL,
  part       text NOT NULL DEFAULT 'full' CHECK (part IN ('full','am','pm')),
  label      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  UNIQUE (tenant_id, user_id, leave_date)
);
COMMENT ON TABLE public.t_user_leave IS '024: a person''s days off in a tenant — full day, morning (am) or afternoon (pm).';
CREATE INDEX IF NOT EXISTS idx_user_leave_lookup ON public.t_user_leave (tenant_id, user_id, leave_date);
ALTER TABLE public.t_user_availability ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.t_user_leave        ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.jtd_effective_hours(p_tenant uuid, p_user uuid)
RETURNS TABLE (work_start time, work_end time, weekly_off integer[], source text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(u.work_start, t.work_start, '09:00'::time),
         COALESCE(u.work_end,   t.work_end,   '18:00'::time),
         COALESCE(u.weekly_off, t.weekly_holidays, '{0}'::integer[]),
         CASE WHEN u.user_id IS NOT NULL AND (u.work_start IS NOT NULL OR u.weekly_off IS NOT NULL) THEN 'user' ELSE 'tenant' END
    FROM (SELECT 1) x
    LEFT JOIN public.t_tenant_cadence_settings t ON t.tenant_id = p_tenant
    LEFT JOIN public.t_user_availability u ON u.tenant_id = p_tenant AND u.user_id = p_user;
$$;

CREATE OR REPLACE FUNCTION public.get_user_availability(p_tenant uuid, p_user uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE h record; t record; u record; v_leave jsonb;
BEGIN
  IF p_tenant IS NULL OR p_user IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'user_required'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.t_user_tenants ut WHERE ut.tenant_id = p_tenant AND ut.user_id = p_user) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'user_not_in_tenant');
  END IF;
  SELECT * INTO h FROM public.jtd_effective_hours(p_tenant, p_user);
  SELECT * INTO t FROM public.t_tenant_cadence_settings WHERE tenant_id = p_tenant;
  SELECT * INTO u FROM public.t_user_availability WHERE tenant_id = p_tenant AND user_id = p_user;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('date', l.leave_date, 'part', l.part, 'label', l.label) ORDER BY l.leave_date), '[]'::jsonb) INTO v_leave
    FROM public.t_user_leave l WHERE l.tenant_id = p_tenant AND l.user_id = p_user AND l.leave_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 30;
  RETURN jsonb_build_object('success', true, 'user_id', p_user,
    'work_start', to_char(h.work_start, 'HH24:MI'), 'work_end', to_char(h.work_end, 'HH24:MI'), 'weekly_off', to_jsonb(h.weekly_off), 'source', h.source,
    'own', jsonb_strip_nulls(jsonb_build_object('work_start', to_char(u.work_start, 'HH24:MI'), 'work_end', to_char(u.work_end, 'HH24:MI'), 'weekly_off', to_jsonb(u.weekly_off))),
    'tenant', jsonb_build_object('work_start', to_char(COALESCE(t.work_start, '09:00'::time), 'HH24:MI'), 'work_end', to_char(COALESCE(t.work_end, '18:00'::time), 'HH24:MI'), 'weekly_off', to_jsonb(COALESCE(t.weekly_holidays, '{0}'::integer[]))),
    'leave', v_leave);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_user_availability(
  p_tenant uuid, p_user uuid, p_work_start time, p_work_end time, p_weekly_off integer[], p_actor uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_tenant IS NULL OR p_user IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'user_required'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.t_user_tenants ut WHERE ut.tenant_id = p_tenant AND ut.user_id = p_user) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'user_not_in_tenant');
  END IF;
  IF (p_work_start IS NULL) <> (p_work_end IS NULL) THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_hours', 'message', 'Give both a start and an end, or neither'); END IF;
  IF p_work_start IS NOT NULL AND p_work_end <= p_work_start THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_hours', 'message', 'The working day must end after it starts'); END IF;
  IF p_weekly_off IS NOT NULL AND EXISTS (SELECT 1 FROM unnest(p_weekly_off) d WHERE d < 0 OR d > 6) THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_weekday'); END IF;
  IF p_work_start IS NULL AND p_weekly_off IS NULL THEN
    DELETE FROM public.t_user_availability WHERE tenant_id = p_tenant AND user_id = p_user;   -- back to the tenant's
  ELSE
    INSERT INTO public.t_user_availability (tenant_id, user_id, work_start, work_end, weekly_off, updated_at, updated_by)
    VALUES (p_tenant, p_user, p_work_start, p_work_end, p_weekly_off, now(), p_actor)
    ON CONFLICT (tenant_id, user_id) DO UPDATE SET work_start = excluded.work_start, work_end = excluded.work_end, weekly_off = excluded.weekly_off, updated_at = now(), updated_by = excluded.updated_by;
  END IF;
  RETURN public.get_user_availability(p_tenant, p_user);
END;
$$;

CREATE OR REPLACE FUNCTION public.add_user_leave(
  p_tenant uuid, p_user uuid, p_date date, p_part text DEFAULT 'full', p_label text DEFAULT NULL, p_actor uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_tenant IS NULL OR p_user IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'user_required'); END IF;
  IF p_date IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'date_required'); END IF;
  IF COALESCE(p_part, 'full') NOT IN ('full','am','pm') THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_part'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.t_user_tenants ut WHERE ut.tenant_id = p_tenant AND ut.user_id = p_user) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'user_not_in_tenant');
  END IF;
  INSERT INTO public.t_user_leave (tenant_id, user_id, leave_date, part, label, created_by)
  VALUES (p_tenant, p_user, p_date, COALESCE(p_part, 'full'), NULLIF(TRIM(p_label), ''), p_actor)
  ON CONFLICT (tenant_id, user_id, leave_date) DO UPDATE SET part = excluded.part, label = excluded.label;
  RETURN public.get_user_availability(p_tenant, p_user);
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_user_leave(p_tenant uuid, p_user uuid, p_date date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_tenant IS NULL OR p_user IS NULL OR p_date IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'date_required'); END IF;
  DELETE FROM public.t_user_leave WHERE tenant_id = p_tenant AND user_id = p_user AND leave_date = p_date;
  RETURN public.get_user_availability(p_tenant, p_user);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_team_availability(p_tenant uuid, p_days integer DEFAULT 60)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('success', true,
    'tenant', (SELECT jsonb_build_object('work_start', to_char(COALESCE(t.work_start,'09:00'::time),'HH24:MI'), 'work_end', to_char(COALESCE(t.work_end,'18:00'::time),'HH24:MI'),
                                         'weekly_off', to_jsonb(COALESCE(t.weekly_holidays,'{0}'::integer[])), 'default_visit_minutes', COALESCE(t.default_visit_minutes, 60))
                 FROM public.t_tenant_cadence_settings t WHERE t.tenant_id = p_tenant),
    'holidays', (SELECT COALESCE(jsonb_agg(jsonb_build_object('date', d.holiday_date, 'label', d.label) ORDER BY d.holiday_date), '[]'::jsonb) FROM public.t_tenant_holiday_dates d
                  WHERE d.tenant_id = p_tenant AND d.holiday_date BETWEEN (now() AT TIME ZONE 'Asia/Kolkata')::date - 7 AND (now() AT TIME ZONE 'Asia/Kolkata')::date + GREATEST(COALESCE(p_days, 60), 1)),
    'people', COALESCE((SELECT jsonb_agg(jsonb_build_object('user_id', ut.user_id, 'name', NULLIF(TRIM(COALESCE(up.first_name,'') || ' ' || COALESCE(up.last_name,'')), ''),
                          'work_start', to_char(h.work_start,'HH24:MI'), 'work_end', to_char(h.work_end,'HH24:MI'), 'weekly_off', to_jsonb(h.weekly_off), 'source', h.source,
                          'leave', (SELECT COALESCE(jsonb_agg(jsonb_build_object('date', l.leave_date, 'part', l.part, 'label', l.label) ORDER BY l.leave_date), '[]'::jsonb) FROM public.t_user_leave l
                                     WHERE l.tenant_id = p_tenant AND l.user_id = ut.user_id AND l.leave_date BETWEEN (now() AT TIME ZONE 'Asia/Kolkata')::date - 7 AND (now() AT TIME ZONE 'Asia/Kolkata')::date + GREATEST(COALESCE(p_days, 60), 1)))
                        ORDER BY up.first_name, up.last_name)
                 FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
                 CROSS JOIN LATERAL public.jtd_effective_hours(p_tenant, ut.user_id) h
                WHERE ut.tenant_id = p_tenant AND COALESCE(ut.status, 'active') IN ('active','accepted')), '[]'::jsonb));
$$;

-- ── 3. how long a visit takes, and whether a slot clashes ──────────────────
CREATE OR REPLACE FUNCTION public.jtd_visit_minutes(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT GREATEST(COALESCE(
    (SELECT CASE lower(COALESCE(b.custom_fields->'config'->'duration'->>'unit', 'minutes'))
              WHEN 'hours' THEN round((b.custom_fields->'config'->'duration'->>'value')::numeric * 60)
              WHEN 'hour'  THEN round((b.custom_fields->'config'->'duration'->>'value')::numeric * 60)
              WHEN 'days'  THEN round((b.custom_fields->'config'->'duration'->>'value')::numeric * 480)
              WHEN 'day'   THEN round((b.custom_fields->'config'->'duration'->>'value')::numeric * 480)
              ELSE round((b.custom_fields->'config'->'duration'->>'value')::numeric) END::integer
       FROM public.t_contract_events e JOIN public.t_contract_blocks b ON b.id::text = e.block_id
      WHERE e.id = p_event_id AND (b.custom_fields->'config'->'duration'->>'value') ~ '^[0-9]+(\.[0-9]+)?$'),
    (SELECT t.default_visit_minutes FROM public.t_contract_events e JOIN public.t_tenant_cadence_settings t ON t.tenant_id = e.tenant_id WHERE e.id = p_event_id),
    60), 15);
$$;
COMMENT ON FUNCTION public.jtd_visit_minutes(uuid) IS '024: the block''s config.duration (value + unit) if the contract block carries one, else the tenant''s default_visit_minutes, else 60. Never below 15.';

CREATE OR REPLACE FUNCTION public.jtd_slot_check(
  p_tenant uuid, p_user uuid, p_start timestamptz, p_minutes integer DEFAULT NULL, p_exclude_event uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_min integer := GREATEST(COALESCE(p_minutes, 60), 15);
  v_end timestamptz; v_day date; v_t0 time; v_t1 time; v_out jsonb := '[]'::jsonb;
  h record; lv record; r record; o_start timestamptz; o_end timestamptz; v_label text;
BEGIN
  IF p_tenant IS NULL OR p_start IS NULL THEN RETURN '[]'::jsonb; END IF;
  v_end := p_start + v_min * interval '1 minute';
  v_day := (p_start AT TIME ZONE 'Asia/Kolkata')::date;
  v_t0  := (p_start AT TIME ZONE 'Asia/Kolkata')::time;
  v_t1  := (v_end   AT TIME ZONE 'Asia/Kolkata')::time;
  SELECT * INTO h FROM public.jtd_effective_hours(p_tenant, p_user);

  IF extract(dow FROM v_day)::integer = ANY (h.weekly_off) THEN
    v_out := v_out || jsonb_build_object('kind', 'weekly_off', 'detail', to_char(v_day, 'Dy') || ' is a day off' || CASE WHEN p_user IS NOT NULL AND h.source = 'user' THEN ' for them' ELSE '' END);
  END IF;
  SELECT d.label INTO v_label FROM public.t_tenant_holiday_dates d WHERE d.tenant_id = p_tenant AND d.holiday_date = v_day;
  IF FOUND THEN v_out := v_out || jsonb_build_object('kind', 'holiday', 'detail', COALESCE(NULLIF(v_label, ''), 'a marked holiday')); END IF;
  IF p_user IS NOT NULL THEN
    SELECT * INTO lv FROM public.t_user_leave l WHERE l.tenant_id = p_tenant AND l.user_id = p_user AND l.leave_date = v_day;
    IF FOUND AND (lv.part = 'full' OR (lv.part = 'am' AND v_t0 < '13:00'::time) OR (lv.part = 'pm' AND (v_t1 > '13:00'::time OR v_t1 < v_t0))) THEN
      v_out := v_out || jsonb_build_object('kind', 'leave', 'detail', 'on leave' || CASE lv.part WHEN 'am' THEN ' (morning)' WHEN 'pm' THEN ' (afternoon)' ELSE '' END || COALESCE(' · ' || lv.label, ''));
    END IF;
  END IF;
  IF v_t0 < h.work_start OR v_t1 > h.work_end OR v_t1 < v_t0 THEN
    v_out := v_out || jsonb_build_object('kind', 'outside_hours', 'detail', format('outside %s–%s', to_char(h.work_start, 'HH24:MI'), to_char(h.work_end, 'HH24:MI')));
  END IF;
  -- overlaps: only against services that HAVE a timed slot (an event row's own scheduled_date carries its creation clock time)
  IF p_user IS NOT NULL THEN
    FOR r IN
      SELECT e.id, e.block_name, c.contract_number, a.item
        FROM public.t_contract_events e
        JOIN public.t_contracts c ON c.id = e.contract_id
        CROSS JOIN LATERAL (SELECT public.jtd_item_open(e.id, 'appointment') AS item) a
       WHERE e.tenant_id = p_tenant AND e.assigned_to = p_user AND e.event_type = 'service' AND COALESCE(e.is_active, true)
         AND e.status IN ('scheduled','due','overdue','in_progress') AND e.id IS DISTINCT FROM p_exclude_event
         AND (e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date = v_day
         AND a.item IS NOT NULL AND a.item->>'scheduled_at' IS NOT NULL
    LOOP
      o_start := (r.item->>'scheduled_at')::timestamptz;
      o_end := o_start + GREATEST(COALESCE((r.item->>'duration_minutes')::integer, 60), 15) * interval '1 minute';
      IF p_start < o_end AND v_end > o_start THEN
        v_out := v_out || jsonb_build_object('kind', 'overlap', 'event_id', r.id,
                   'detail', format('overlaps %s · %s at %s', COALESCE(r.block_name, 'a service'), r.contract_number, to_char(o_start AT TIME ZONE 'Asia/Kolkata', 'HH24:MI')));
      END IF;
    END LOOP;
  END IF;
  RETURN v_out;
END;
$$;
COMMENT ON FUNCTION public.jtd_slot_check(uuid, uuid, timestamptz, integer, uuid) IS '024: [] or the reasons a slot clashes for a person — weekly_off · holiday · leave · outside_hours · overlap (against timed slots of the same technician). A warning, never a refusal.';

-- ── 4. the tools warn; the items carry a duration ──────────────────────────
-- jtd_schedule_visit: a new appointment item records how long the visit takes; the result carries warnings
SELECT public.jtd__rewrite_fn('jtd_schedule_visit',
  $old$               'assigned_to', v_e.assigned_to, 'assigned_to_name', v_e.assigned_to_name, 'note', p_note)),$old$,
  $new$               'assigned_to', v_e.assigned_to, 'assigned_to_name', v_e.assigned_to_name, 'note', p_note, 'duration_minutes', public.jtd_visit_minutes(p_event_id))),$new$,
  '024 schedule add duration');
SELECT public.jtd__rewrite_fn('jtd_schedule_visit',
  $old$                            'item_status', v_new, 'scheduled_at', p_scheduled_at, 'confirmed', p_confirmed, 'event_moved', v_event_moved OR p_confirmed);$old$,
  $new$                            'item_status', v_new, 'scheduled_at', p_scheduled_at, 'confirmed', p_confirmed, 'event_moved', v_event_moved OR p_confirmed,
                            'warnings', public.jtd_slot_check(p_tenant, v_e.assigned_to, p_scheduled_at, COALESCE((v_open->>'duration_minutes')::integer, public.jtd_visit_minutes(p_event_id)), p_event_id));$new$,
  '024 schedule warnings');
-- jtd_confirm_visit_slot: warnings on confirm
SELECT public.jtd__rewrite_fn('jtd_confirm_visit_slot',
  $old$  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'scheduled_at', v_at, 'appointment_status', 'accepted', 'item_status', 'confirmed');$old$,
  $new$  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'appointment_id', v_appt, 'scheduled_at', v_at, 'appointment_status', 'accepted', 'item_status', 'confirmed',
                            'warnings', public.jtd_slot_check(p_tenant, v_e.assigned_to, v_at, COALESCE((v_open->>'duration_minutes')::integer, public.jtd_visit_minutes(p_event_id)), p_event_id));$new$,
  '024 confirm warnings');
-- jtd_assign_visit: warnings for the technician when the visit already has a timed slot
SELECT public.jtd__rewrite_fn('jtd_assign_visit',
  $old$  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'assigned_to', p_assign_to, 'assigned_to_name', v_name, 'version', v_e.version + 1);$old$,
  $new$  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'assigned_to', p_assign_to, 'assigned_to_name', v_name, 'version', v_e.version + 1,
                            'warnings', COALESCE((SELECT public.jtd_slot_check(p_tenant, p_assign_to, (i->>'scheduled_at')::timestamptz, (i->>'duration_minutes')::integer, p_event_id)
                                                    FROM public.jtd_item_open(p_event_id, 'appointment') i WHERE i IS NOT NULL AND i->>'scheduled_at' IS NOT NULL), '[]'::jsonb));$new$,
  '024 assign warnings');

-- existing appointment items: record the duration once, so overlaps have an end
UPDATE public.n_jtd j
   SET appointments = (SELECT jsonb_agg(CASE WHEN a ? 'duration_minutes' THEN a ELSE a || jsonb_build_object('duration_minutes', public.jtd_visit_minutes(j.id)) END)
                         FROM jsonb_array_elements(j.appointments) a)
 WHERE jsonb_typeof(j.appointments) = 'array' AND jsonb_array_length(j.appointments) > 0
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(j.appointments) a WHERE NOT (a ? 'duration_minutes'));

-- ── 5. the board carries duration + clashes on every visit row ─────────────
SELECT public.jtd__rewrite_fn('jtd_ops_board',
  $old$           st.id AS ticket_id, st.ticket_number, st.status AS ticket_status$old$,
  $new$           st.id AS ticket_id, st.ticket_number, st.status AS ticket_status,
           COALESCE((oi.item->>'duration_minutes')::integer, public.jtd_visit_minutes(e.id)) AS visit_minutes$new$,
  '024 board visits select');
SELECT public.jtd__rewrite_fn('jtd_ops_board',
  $old$                          WHERE te.event_id = e.id AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1) st ON true$old$,
  $new$                          WHERE te.event_id = e.id AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1) st ON true
      CROSS JOIN LATERAL (SELECT public.jtd_item_open(e.id, 'appointment') AS item) oi$new$,
  '024 board visits join');
SELECT public.jtd__rewrite_fn('jtd_ops_board',
  $old$             'ticket', CASE WHEN v.ticket_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.ticket_id, 'number', v.ticket_number, 'status', v.ticket_status) END)),$old$,
  $new$             'duration_minutes', v.visit_minutes,
             'clashes', CASE WHEN v.appt_at IS NULL THEN NULL ELSE NULLIF(public.jtd_slot_check(p_tenant, v.assigned_to, v.appt_at, v.visit_minutes, v.id), '[]'::jsonb) END,
             'ticket', CASE WHEN v.ticket_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.ticket_id, 'number', v.ticket_number, 'status', v.ticket_status) END)),$new$,
  '024 board visit json');

-- ── 6. the plan counts clashes; "Plan this day" respects hours and days off ─
CREATE OR REPLACE FUNCTION public.jtd__plan_counts(p_cards jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'total',      count(*),
    'needs_you',  count(*) FILTER (WHERE c->>'kind' IN ('declaration_pending','send_failed','call_open','rung_due','overdue_no_ladder','ladder_exhausted','awaiting_activation','invoice_overdue','visit_overdue','visit_today','visit_in_progress','slot_to_confirm')),
    'services',   count(*) FILTER (WHERE c->>'lane' = 'services'),
    'to_place',   count(*) FILTER (WHERE c->>'lane' = 'services' AND c->>'kind' IN ('visit_scheduled','visit_today','visit_overdue') AND COALESCE(c->>'slot_state','none') = 'none'),
    'proposed',   count(*) FILTER (WHERE c->>'lane' = 'services' AND c->>'slot_state' = 'proposed' AND c->>'kind' <> 'slot_to_confirm' AND c->'visit'->'ask'->>'asked_at' IS NULL),
    'asked',      count(*) FILTER (WHERE c->>'lane' = 'services' AND c->>'slot_state' = 'proposed' AND c->>'kind' <> 'slot_to_confirm' AND c->'visit'->'ask'->>'asked_at' IS NOT NULL),
    'to_confirm', count(*) FILTER (WHERE c->>'kind' = 'slot_to_confirm'),
    'confirmed',  count(*) FILTER (WHERE c->>'lane' = 'services' AND c->>'slot_state' = 'confirmed'),
    'in_progress',count(*) FILTER (WHERE c->>'kind' = 'visit_in_progress'),
    'unassigned_services', count(*) FILTER (WHERE c->>'lane' = 'services' AND c->>'owner_id' IS NULL),
    'clashes',    count(*) FILTER (WHERE jsonb_typeof(c->'visit'->'clashes') = 'array' AND jsonb_array_length(c->'visit'->'clashes') > 0),
    'payments',   count(*) FILTER (WHERE c->>'lane' = 'collections' AND c->>'kind' <> 'call_open'),
    'followups',  count(*) FILTER (WHERE c->>'kind' = 'call_open'),
    'reminders_due', count(*) FILTER (WHERE c->>'kind' IN ('rung_due','rung_ahead')),
    'declarations',  count(*) FILTER (WHERE c->>'kind' = 'declaration_pending')
  )
  FROM jsonb_array_elements(COALESCE(p_cards, '[]'::jsonb)) c;
$$;

CREATE OR REPLACE FUNCTION public.jtd_plan_day(
  p_tenant uuid, p_day date, p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_is_live boolean DEFAULT true, p_start time DEFAULT NULL, p_step_minutes integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  r record; v_key text; v_n integer; v_slot timestamptz; v_r jsonb; v_start time; v_step integer; v_off jsonb;
  v_seq jsonb := '{}'::jsonb; v_placed jsonb := '[]'::jsonb; v_refused jsonb := '[]'::jsonb;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  IF p_day IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'day_required'); END IF;
  IF p_day < v_today THEN RETURN jsonb_build_object('success', false, 'reason', 'day_passed', 'message', 'That day has passed — reschedule those services one by one'); END IF;
  IF NOT public.vani_is_enabled(p_tenant) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'vani_off', 'message', 'VaNi is not on for this business — place the services one by one, or open VaNi');
  END IF;
  -- the organisation's hours: start there, step by the default visit length (024)
  SELECT COALESCE(p_start, t.work_start, '10:00'::time), LEAST(GREATEST(COALESCE(p_step_minutes, t.default_visit_minutes, 120), 30), 480)
    INTO v_start, v_step FROM (SELECT 1) x LEFT JOIN public.t_tenant_cadence_settings t ON t.tenant_id = p_tenant;
  -- a tenant day off is refused, not planned around: the human decides
  v_off := public.jtd_slot_check(p_tenant, NULL, (p_day::timestamp + v_start) AT TIME ZONE 'Asia/Kolkata', 60, NULL);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_off) x WHERE x->>'kind' IN ('weekly_off','holiday')) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'day_off', 'message', (SELECT string_agg(x->>'detail', ' · ') FROM jsonb_array_elements(v_off) x WHERE x->>'kind' IN ('weekly_off','holiday')));
  END IF;

  FOR r IN
    SELECT COALESCE(e.assigned_to::text, '-') AS k, count(*) AS n
      FROM public.t_contract_events e
     WHERE e.tenant_id = p_tenant AND e.event_type = 'service' AND e.is_live = p_is_live AND COALESCE(e.is_active, true)
       AND e.status IN ('scheduled','due','overdue','in_progress')
       AND (e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date = p_day
       AND public.jtd_item_open(e.id, 'appointment') IS NOT NULL
     GROUP BY 1
  LOOP
    v_seq := v_seq || jsonb_build_object(r.k, r.n);
  END LOOP;

  FOR r IN
    SELECT e.id, e.assigned_to, e.assigned_to_name, e.block_name, e.scheduled_date,
           (SELECT c.contract_number FROM public.t_contracts c WHERE c.id = e.contract_id) AS contract_number
      FROM public.t_contract_events e
     WHERE e.tenant_id = p_tenant AND e.event_type = 'service' AND e.is_live = p_is_live AND COALESCE(e.is_active, true)
       AND e.status IN ('scheduled','due','overdue')
       AND (e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date = p_day
       AND public.jtd_item_open(e.id, 'appointment') IS NULL
     ORDER BY e.scheduled_date, e.created_at
  LOOP
    v_key := COALESCE(r.assigned_to::text, '-');
    v_n := COALESCE((v_seq->>v_key)::integer, 0);
    v_slot := (p_day::timestamp + v_start + (v_n * v_step) * interval '1 minute') AT TIME ZONE 'Asia/Kolkata';
    IF v_slot < now() THEN
      v_slot := ((date_trunc('hour', now() AT TIME ZONE 'Asia/Kolkata') + interval '1 hour') + (v_n * v_step) * interval '1 minute') AT TIME ZONE 'Asia/Kolkata';
    END IF;
    v_r := public.jtd_schedule_visit(p_tenant, r.id, v_slot, false, p_actor_type, p_actor_id, p_actor_name,
             CASE WHEN p_actor_type = 'vani' THEN 'Placed by VaNi (plan the day)' ELSE 'Placed by "Plan this day"' END);
    IF COALESCE((v_r->>'success')::boolean, false) THEN
      v_seq := v_seq || jsonb_build_object(v_key, v_n + 1);
      v_placed := v_placed || jsonb_build_object('event_id', r.id, 'contract_number', r.contract_number, 'block_name', r.block_name,
                                                 'scheduled_at', v_slot, 'technician', r.assigned_to_name, 'appointment_id', v_r->>'appointment_id', 'warnings', v_r->'warnings');
    ELSE
      v_refused := v_refused || jsonb_build_object('event_id', r.id, 'contract_number', r.contract_number, 'block_name', r.block_name,
                                                   'reason', v_r->>'reason', 'detail', COALESCE(v_r->>'detail', v_r->>'message'));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'day', p_day, 'start', to_char(v_start, 'HH24:MI'), 'step_minutes', v_step,
    'placed_count', jsonb_array_length(v_placed), 'refused_count', jsonb_array_length(v_refused),
    'unassigned_count', (SELECT count(*) FROM jsonb_array_elements(v_placed) x WHERE x->>'technician' IS NULL),
    'warned_count', (SELECT count(*) FROM jsonb_array_elements(v_placed) x WHERE jsonb_typeof(x->'warnings') = 'array' AND jsonb_array_length(x->'warnings') > 0),
    'placed', v_placed, 'refused', v_refused);
END;
$$;
COMMENT ON FUNCTION public.jtd_plan_day(uuid, date, text, uuid, text, boolean, time, integer) IS '023/024: "Plan this day" — proposes a slot for every unslotted service on the day from the organisation''s work_start, stepping by the default visit length per technician; refuses a tenant day off (day_off); each placement carries its clash warnings. VaNi leverage: refuses vani_off.';
