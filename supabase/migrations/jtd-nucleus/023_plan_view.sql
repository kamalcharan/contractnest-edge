-- ============================================================================
-- jtd-nucleus/023 — the PLAN VIEW (Commitments Register · Plan tab)
-- ----------------------------------------------------------------------------
-- Owner (2026-09-18): "as per JTD, Wed 16 Sep has a few events — can't those be
-- shown as commitments lined up, and the user reviews (tooltip / popup) and
-- confirms or proposes?" Plus the cross-selling rule agreed the same day:
-- the plan is for everyone; the LEVERAGE is VaNi's — placing a whole day,
-- asking every customer at once — and sits behind vani_is_enabled().
--
--   jtd_plan(tenant, is_live, filters, user)
--     Every day of the window with its commitments lined up, slotted or not.
--     A regrouping of jtd_ops_board (014/017/020) by the row's IST anchor day:
--     no new row model, the register's Plan tab renders the same JobCard with
--     the same verbs. Per-day counts say what the day needs (to place, asked,
--     to confirm, confirmed, payments, follow-ups, reminders due) and what
--     VaNi would do with it (place · ask · remind) — shown greyed when VaNi is
--     off, as buttons when it is on. Rows anchored before the window (overdue)
--     come back as `carried`, rows with no anchor as `parked`.
--
--   jtd_plan_day(tenant, day, actor…)          — "Plan this day"
--     Places every service on that day that has no slot yet: 10:00 IST first,
--     then +2h per service already placed for the same technician (unassigned
--     services share one sequence; nobody is guessed a technician — the owner's
--     rule is that unassigned is a signal, never a headline). Each placement is
--     the existing jtd_schedule_visit (proposed, never confirmed). Gated on
--     vani_is_enabled(): refuses `vani_off` otherwise.
--
--   jtd_ask_day(tenant, day, channel, actor…)  — "Ask everyone"
--     Asks the customer of every service on that day whose slot is proposed
--     and not yet asked, on email or WhatsApp, through the existing
--     jtd_ask_visit_slot (which refuses no_template until the provider
--     template is registered — the UI only offers channels in ask_channels).
--     Gated the same way.
--
-- No tables, no columns. Additive. Source of record for what is live.
-- ============================================================================

-- ── per-list counts: one place that says what a set of board cards needs ─────
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
    'payments',   count(*) FILTER (WHERE c->>'lane' = 'collections' AND c->>'kind' <> 'call_open'),
    'followups',  count(*) FILTER (WHERE c->>'kind' = 'call_open'),
    'reminders_due', count(*) FILTER (WHERE c->>'kind' IN ('rung_due','rung_ahead')),
    'declarations',  count(*) FILTER (WHERE c->>'kind' = 'declaration_pending')
  )
  FROM jsonb_array_elements(COALESCE(p_cards, '[]'::jsonb)) c;
$$;
COMMENT ON FUNCTION public.jtd__plan_counts(jsonb) IS '023: counts over a list of jtd_ops_board cards — what a day needs, and what VaNi would do with it (to_place → place, proposed → ask, reminders_due → remind).';

-- ── the reader ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_plan(
  p_tenant uuid, p_is_live boolean DEFAULT true, p_filters jsonb DEFAULT '{}'::jsonb, p_user uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_from date; v_to date; v_tmp date; v_bf jsonb; v_board jsonb;
  v_days jsonb; v_carried jsonb; v_parked jsonb; v_all jsonb; v_truncated boolean := false;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'tenant_required'); END IF;
  BEGIN v_from := NULLIF(p_filters->>'from', '')::date; EXCEPTION WHEN others THEN v_from := NULL; END;
  BEGIN v_to   := NULLIF(p_filters->>'to',   '')::date; EXCEPTION WHEN others THEN v_to   := NULL; END;
  v_from := COALESCE(v_from, v_today);
  v_to   := COALESCE(v_to, v_from + 13);
  IF v_to < v_from THEN v_tmp := v_from; v_from := v_to; v_to := v_tmp; END IF;
  IF v_to - v_from > 120 THEN v_to := v_from + 120; END IF;

  -- the board does the row model, filters and Who; we ask for everything in the window.
  -- A plan that starts today (or earlier) also wants what is already overdue: leave `from`
  -- out so the board includes the overdue bucket, and sort those rows into `carried` below.
  v_bf := jsonb_strip_nulls(jsonb_build_object(
    'from', CASE WHEN v_from > v_today THEN v_from::text END,
    'to', v_to::text, 'limit', 200,
    'limits', jsonb_build_object('overdue', 500, 'today', 500, 'b1', 500, 'b2', 500, 'b3', 500, 'parked', 500),
    'lanes', CASE WHEN jsonb_typeof(p_filters->'lanes') = 'array' AND jsonb_array_length(p_filters->'lanes') > 0 THEN p_filters->'lanes' END,
    'who', NULLIF(p_filters->>'who', ''), 'q', NULLIF(p_filters->>'q', '')));
  v_board := public.jtd_ops_board(p_tenant, p_is_live, v_bf, p_user);
  IF NOT COALESCE((v_board->>'success')::boolean, false) THEN RETURN v_board; END IF;

  SELECT bool_or((b->>'count')::integer > jsonb_array_length(b->'cards')) INTO v_truncated FROM jsonb_array_elements(v_board->'buckets') b;

  -- every day of the window, empty ones included — an empty day is information
  SELECT jsonb_agg(jsonb_build_object('day', g.day, 'dow', to_char(g.day, 'Dy'), 'is_today', g.day = v_today,
                                      'counts', public.jtd__plan_counts(g.cards), 'cards', g.cards) ORDER BY g.day)
    INTO v_days
  FROM (
    SELECT s.day::date AS day,   -- generate_series over dates yields timestamps; the day is a date
           COALESCE((SELECT jsonb_agg(c.card ORDER BY (c.card->>'anchor_at')::timestamptz, c.card->>'contract_number')
                       FROM jsonb_array_elements(v_board->'buckets') b, jsonb_array_elements(b->'cards') c(card)
                      WHERE c.card->>'anchor_at' IS NOT NULL
                        AND ((c.card->>'anchor_at')::timestamptz AT TIME ZONE 'Asia/Kolkata')::date = s.day::date), '[]'::jsonb) AS cards
      FROM generate_series(v_from, v_to, interval '1 day') s(day)
  ) g;

  -- overdue / before the window (only when the window starts today or earlier — see above)
  SELECT COALESCE(jsonb_agg(c.card ORDER BY (c.card->>'anchor_at')::timestamptz, c.card->>'contract_number'), '[]'::jsonb) INTO v_carried
    FROM jsonb_array_elements(v_board->'buckets') b, jsonb_array_elements(b->'cards') c(card)
   WHERE c.card->>'anchor_at' IS NOT NULL AND ((c.card->>'anchor_at')::timestamptz AT TIME ZONE 'Asia/Kolkata')::date < v_from;
  -- no anchor at all (the board's parked bucket)
  SELECT COALESCE(jsonb_agg(c.card ORDER BY c.card->>'contract_number'), '[]'::jsonb) INTO v_parked
    FROM jsonb_array_elements(v_board->'buckets') b, jsonb_array_elements(b->'cards') c(card)
   WHERE c.card->>'anchor_at' IS NULL;
  SELECT COALESCE(jsonb_agg(c.card), '[]'::jsonb) INTO v_all
    FROM jsonb_array_elements(v_board->'buckets') b, jsonb_array_elements(b->'cards') c(card);

  RETURN jsonb_build_object(
    'success', true, 'today', v_today, 'is_live', p_is_live,
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'days', (v_to - v_from) + 1),
    'filters', v_board->'filters',
    'days', COALESCE(v_days, '[]'::jsonb),
    'carried', jsonb_build_object('counts', public.jtd__plan_counts(v_carried), 'cards', v_carried),
    'parked',  jsonb_build_object('counts', public.jtd__plan_counts(v_parked),  'cards', v_parked),
    'totals', public.jtd__plan_counts(v_all),
    'truncated', COALESCE(v_truncated, false),
    'team', v_board->'team', 'ladder', v_board->'ladder', 'ask_channels', COALESCE(v_board->'ask_channels', '[]'::jsonb),
    'vani_enabled', public.vani_is_enabled(p_tenant),
    'generated_at', now());
END;
$$;
COMMENT ON FUNCTION public.jtd_plan(uuid, boolean, jsonb, uuid) IS '023: the Plan view — every day of the window with its board cards lined up (jtd_ops_board regrouped by IST anchor day), per-day counts, carried (overdue) and parked rows, and whether VaNi is on. Filters: from, to (≤120 days), lanes[], who, q.';

-- ── "Plan this day": place every unslotted service (VaNi leverage) ───────────
CREATE OR REPLACE FUNCTION public.jtd_plan_day(
  p_tenant uuid, p_day date, p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_is_live boolean DEFAULT true, p_start time DEFAULT '10:00'::time, p_step_minutes integer DEFAULT 120
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  r record; v_key text; v_n integer; v_slot timestamptz; v_r jsonb;
  v_seq jsonb := '{}'::jsonb; v_placed jsonb := '[]'::jsonb; v_refused jsonb := '[]'::jsonb;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  IF p_day IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'day_required'); END IF;
  IF p_day < v_today THEN RETURN jsonb_build_object('success', false, 'reason', 'day_passed', 'message', 'That day has passed — reschedule those services one by one'); END IF;
  IF NOT public.vani_is_enabled(p_tenant) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'vani_off', 'message', 'VaNi is not on for this business — place the services one by one, or open VaNi');
  END IF;
  p_step_minutes := LEAST(GREATEST(COALESCE(p_step_minutes, 120), 15), 480);
  p_start := COALESCE(p_start, '10:00'::time);

  -- seed each technician's sequence with the slots already on the day, so new ones land after them
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
    v_slot := (p_day::timestamp + p_start + (v_n * p_step_minutes) * interval '1 minute') AT TIME ZONE 'Asia/Kolkata';
    -- today, and that hour has passed: start from the next full hour instead
    IF v_slot < now() THEN
      v_slot := ((date_trunc('hour', now() AT TIME ZONE 'Asia/Kolkata') + interval '1 hour') + (v_n * p_step_minutes) * interval '1 minute') AT TIME ZONE 'Asia/Kolkata';
    END IF;
    v_r := public.jtd_schedule_visit(p_tenant, r.id, v_slot, false, p_actor_type, p_actor_id, p_actor_name,
             CASE WHEN p_actor_type = 'vani' THEN 'Placed by VaNi (plan the day)' ELSE 'Placed by "Plan this day"' END);
    IF COALESCE((v_r->>'success')::boolean, false) THEN
      v_seq := v_seq || jsonb_build_object(v_key, v_n + 1);
      v_placed := v_placed || jsonb_build_object('event_id', r.id, 'contract_number', r.contract_number, 'block_name', r.block_name,
                                                 'scheduled_at', v_slot, 'technician', r.assigned_to_name, 'appointment_id', v_r->>'appointment_id');
    ELSE
      v_refused := v_refused || jsonb_build_object('event_id', r.id, 'contract_number', r.contract_number, 'block_name', r.block_name,
                                                   'reason', v_r->>'reason', 'detail', COALESCE(v_r->>'detail', v_r->>'message'));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'day', p_day,
    'placed_count', jsonb_array_length(v_placed), 'refused_count', jsonb_array_length(v_refused),
    'unassigned_count', (SELECT count(*) FROM jsonb_array_elements(v_placed) x WHERE x->>'technician' IS NULL),
    'placed', v_placed, 'refused', v_refused);
END;
$$;
COMMENT ON FUNCTION public.jtd_plan_day(uuid, date, text, uuid, text, boolean, time, integer) IS '023: "Plan this day" — proposes a slot for every service on the day that has none (10:00 IST, then +step per service already placed for the same technician; nobody is guessed a technician), through jtd_schedule_visit. VaNi leverage: refuses vani_off.';

-- ── "Ask everyone": ask every proposed-not-asked slot of the day (VaNi leverage) ──
CREATE OR REPLACE FUNCTION public.jtd_ask_day(
  p_tenant uuid, p_day date, p_channel text, p_actor_type text, p_actor_id uuid, p_actor_name text,
  p_is_live boolean DEFAULT true, p_link_base text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r record; v_r jsonb; v_asked jsonb := '[]'::jsonb; v_refused jsonb := '[]'::jsonb;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  IF p_day IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'day_required'); END IF;
  IF p_channel NOT IN ('email','whatsapp') THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_channel', 'message', 'Ask everyone sends — pick email or whatsapp'); END IF;
  IF NOT public.vani_is_enabled(p_tenant) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'vani_off', 'message', 'VaNi is not on for this business — ask the customers one by one, or open VaNi');
  END IF;

  FOR r IN
    SELECT e.id, e.block_name, a.item,
           (SELECT c.contract_number FROM public.t_contracts c WHERE c.id = e.contract_id) AS contract_number
      FROM public.t_contract_events e
     CROSS JOIN LATERAL (SELECT public.jtd_item_open(e.id, 'appointment') AS item) a
     WHERE e.tenant_id = p_tenant AND e.event_type = 'service' AND e.is_live = p_is_live AND COALESCE(e.is_active, true)
       AND e.status IN ('scheduled','due','overdue')
       AND a.item IS NOT NULL AND a.item->>'status' = 'proposed'
       AND (COALESCE((a.item->>'scheduled_at')::timestamptz, e.scheduled_date) AT TIME ZONE 'Asia/Kolkata')::date = p_day
     ORDER BY COALESCE((a.item->>'scheduled_at')::timestamptz, e.scheduled_date)
  LOOP
    v_r := public.jtd_ask_visit_slot(p_tenant, r.id, p_channel, p_actor_type, p_actor_id, p_actor_name, NULL, p_link_base);
    IF COALESCE((v_r->>'success')::boolean, false) THEN
      v_asked := v_asked || jsonb_build_object('event_id', r.id, 'contract_number', r.contract_number, 'block_name', r.block_name,
                                               'recipient_name', v_r->>'recipient_name', 'scheduled_at', v_r->>'scheduled_at', 'communication_id', v_r->>'communication_id');
    ELSE
      v_refused := v_refused || jsonb_build_object('event_id', r.id, 'contract_number', r.contract_number, 'block_name', r.block_name,
                                                   'reason', v_r->>'reason', 'detail', COALESCE(v_r->>'detail', v_r->>'message'));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'day', p_day, 'channel', p_channel,
    'asked_count', jsonb_array_length(v_asked), 'refused_count', jsonb_array_length(v_refused),
    'asked', v_asked, 'refused', v_refused);
END;
$$;
COMMENT ON FUNCTION public.jtd_ask_day(uuid, date, text, text, uuid, text, boolean, text) IS '023: "Ask everyone" — asks the customer of every service on the day whose slot is proposed and not yet asked, on email or whatsapp, through jtd_ask_visit_slot (no_template until the provider template is registered). VaNi leverage: refuses vani_off.';
