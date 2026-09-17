-- ============================================================================
-- jtd-nucleus/011 — Follow up: the call task gets a DUE DATE, the board
-- anchors an open call on it. Spec: OPS-JTD-TOOLS-SPEC.md §4 (tools), §5.
-- Owner decision 2026-09-17: "Follow up" = a self-assigned JTD task via the
-- existing escalate tool (not a bookmark; distinct from an appointment, which
-- involves the customer and a slot). Nothing new is piped: the same
-- payment_call_due task row, with scheduled_at = the chosen date, and
-- business_context.task_kind = 'follow_up' when the actor assigns themself.
--
-- 1. jtd_escalate_payment_call(+ p_due_at timestamptz DEFAULT NULL)
--    The 7-argument overload is DROPPED first — otherwise a call without
--    p_due_at would be ambiguous between the two signatures ("function is
--    not unique") and break the existing Assign call button.
-- 2. jtd_collections_board: open_call carries scheduled_at; a call_open row
--    is anchored at COALESCE(task.scheduled_at, task.created_at), so
--    "follow up on Tuesday" lands in the right column and turns overdue when
--    Tuesday passes. call_task gains due_at; the feed gains task_kind/due_at.
-- ============================================================================

DROP FUNCTION IF EXISTS public.jtd_escalate_payment_call(uuid, uuid, uuid, text, uuid, text, text);

CREATE OR REPLACE FUNCTION public.jtd_escalate_payment_call(
  p_tenant     uuid,
  p_job_id     uuid,
  p_assign_to  uuid,
  p_actor_type text,
  p_actor_id   uuid,
  p_actor_name text,
  p_note       text DEFAULT NULL,
  p_due_at     timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job      public.n_jtd%ROWTYPE;
  v_contract record;
  v_assignee text;
  v_rung     record;
  v_rung_no  integer := 0;
  v_row      uuid;
  v_next     timestamptz;
  v_due      timestamptz := COALESCE(p_due_at, now());
  v_kind     text := CASE WHEN p_actor_type = 'user' AND p_assign_to = p_actor_id THEN 'follow_up' ELSE 'escalation' END;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
  END IF;
  IF p_due_at IS NOT NULL AND p_due_at < now() - interval '1 day' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'due_in_past');
  END IF;
  SELECT * INTO v_job FROM public.n_jtd
   WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment' FOR UPDATE;
  IF v_job.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'job_not_found');
  END IF;
  IF v_job.status_code NOT IN ('scheduled','due','overdue','partial_payment') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'job_not_open', 'status', v_job.status_code);
  END IF;

  SELECT COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email) INTO v_assignee
    FROM public.t_user_tenants ut
    LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND ut.user_id = p_assign_to
   LIMIT 1;
  IF v_assignee IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'assignee_not_in_tenant');
  END IF;

  IF EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.source_id = p_job_id AND j.source_type_code = 'payment_call_due'
                AND j.status_code IN ('assigned','in_progress','pending','created')) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'call_already_open');
  END IF;

  SELECT c.contract_number, c.buyer_id, c.buyer_name INTO v_contract FROM public.t_contracts c WHERE c.id = v_job.contract_id;

  SELECT r.step INTO v_rung FROM public.jtd_ladder_rungs(p_tenant) r
   WHERE r.step = v_job.dunning_step + 1 AND r.channel = 'call'
     AND public.jtd_rung_due_at(v_job.scheduled_at, r.after_days) <= now();
  v_rung_no := COALESCE(v_rung.step, 0);

  BEGIN
    INSERT INTO public.n_jtd (
      tenant_id, event_type_code, channel_code, source_type_code, source_id, source_ref,
      recipient_type, recipient_id, recipient_name,
      status_code, scheduled_at, assigned_to, assigned_to_name, notes, business_context, metadata,
      performed_by_type, performed_by_id, performed_by_name, is_live,
      contract_id, block_id, block_name, invoice_id, amount, currency, dunning_step
    ) VALUES (
      p_tenant, 'task', NULL, 'payment_call_due', p_job_id, v_contract.contract_number,
      'contact', v_contract.buyer_id, v_contract.buyer_name,
      'assigned', v_due, p_assign_to, v_assignee, p_note,
      jsonb_build_object('job_id', p_job_id, 'contract_id', v_job.contract_id, 'invoice_id', v_job.invoice_id,
                         'rung', v_rung_no, 'origin', 'collections_tool', 'task_kind', v_kind, 'due_at', v_due),
      '{}'::jsonb,
      p_actor_type, p_actor_id, p_actor_name, COALESCE(v_job.is_live, true),
      v_job.contract_id, v_job.block_id, v_job.block_name, v_job.invoice_id,
      GREATEST(COALESCE(v_job.amount,0) - COALESCE(v_job.amount_settled,0), 0), v_job.currency, v_rung_no
    ) RETURNING id INTO v_row;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'reason', 'duplicate_rung', 'rung', v_rung_no);
  END;

  UPDATE public.n_jtd
     SET dunning_step = GREATEST(dunning_step, v_rung_no), version = COALESCE(version,0) + 1, updated_at = now()
   WHERE id = p_job_id;
  v_next := public.jtd_recompute_dunning(p_job_id);

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, CASE WHEN v_kind = 'follow_up' THEN 'follow_up_set' ELSE 'escalated' END, p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('assigned_to', p_assign_to, 'assigned_to_name', v_assignee, 'rung', v_rung_no, 'task_jtd_id', v_row, 'due_at', v_due, 'task_kind', v_kind),
          p_note, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'task_jtd_id', v_row, 'assigned_to', p_assign_to,
                            'assigned_to_name', v_assignee, 'rung', v_rung_no, 'next_dunning_at', v_next,
                            'task_kind', v_kind, 'due_at', v_due);
END;
$$;

-- ── the board: anchor an open call on its due date ──────────────────────────
-- Full body re-issued (same as 010 except: open_call.scheduled_at, call_task.due_at,
-- the call_open anchor, and task_kind/due_at in the feed).
CREATE OR REPLACE FUNCTION public.jtd_collections_board(
  p_tenant   uuid,
  p_is_live  boolean DEFAULT true,
  p_filters  jsonb   DEFAULT '{}'::jsonb,
  p_user     uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today    date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_horizon  integer;
  v_from     date;
  v_to       date;
  v_b1       integer := 3;
  v_b2       integer := 14;
  v_kinds    text[];
  v_channel  text;
  v_age      text;
  v_cycle    text;
  v_who      text;
  v_q        text;
  v_limits   jsonb;
  v_limit    integer;
  v_board    jsonb;
  v_happened jsonb;
  v_team     jsonb;
  v_ladder   jsonb;
  v_tmp      date;
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
    BEGIN
      v_b1 := (p_filters->'bands'->>0)::numeric::integer;
      v_b2 := (p_filters->'bands'->>1)::numeric::integer;
    EXCEPTION WHEN others THEN v_b1 := 3; v_b2 := 14; END;
    IF v_b1 IS NULL OR v_b2 IS NULL OR v_b1 < 1 OR v_b2 <= v_b1 THEN v_b1 := 3; v_b2 := 14; END IF;
  END IF;

  IF jsonb_typeof(p_filters->'kinds') = 'array' AND jsonb_array_length(p_filters->'kinds') > 0 THEN
    v_kinds := ARRAY(SELECT jsonb_array_elements_text(p_filters->'kinds'));
  END IF;
  v_channel := NULLIF(p_filters->>'channel', '');
  v_age     := NULLIF(p_filters->>'age', '');
  v_cycle   := NULLIF(p_filters->>'cycle', '');
  v_who     := COALESCE(NULLIF(p_filters->>'who', ''), 'team');
  v_q       := NULLIF(TRIM(COALESCE(p_filters->>'q', '')), '');
  BEGIN v_limit := NULLIF(p_filters->>'limit','')::numeric::integer; EXCEPTION WHEN others THEN v_limit := NULL; END;
  v_limit   := LEAST(GREATEST(COALESCE(v_limit, 20), 1), 200);
  v_limits  := '{}'::jsonb;
  IF jsonb_typeof(p_filters->'limits') = 'object' THEN
    SELECT COALESCE(jsonb_object_agg(e.key, LEAST(GREATEST(e.value::numeric::integer, 1), 500)), '{}'::jsonb)
      INTO v_limits
      FROM jsonb_each_text(p_filters->'limits') e
     WHERE jsonb_typeof(p_filters->'limits'->e.key) = 'number';
  END IF;

  WITH jobs AS (
    SELECT j.id, j.contract_id, j.invoice_id, j.scheduled_at, j.status_code, j.amount, j.amount_settled, j.currency,
           j.dunning_step, j.nudge_count, j.last_nudge_at, j.dunning_paused_reason, j.promise_date, j.block_name,
           j.billing_cycle_label, j.sequence_number, j.total_occurrences,
           (j.scheduled_at AT TIME ZONE 'Asia/Kolkata')::date AS due_date,
           c.contract_number, c.buyer_id, c.buyer_name, i.invoice_number,
           GREATEST(COALESCE(j.amount,0) - COALESCE(j.amount_settled,0), 0) AS owed
      FROM public.n_jtd j
      JOIN public.t_contracts c ON c.id = j.contract_id
      LEFT JOIN public.t_invoices i ON i.id = j.invoice_id
     WHERE j.tenant_id = p_tenant AND j.event_type_code = 'payment' AND COALESCE(j.is_live, true) = p_is_live
       AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true)
  ),
  rung AS (
    SELECT jb.id AS job_id, r.step, r.after_days, r.channel, public.jtd_rung_due_at(jb.scheduled_at, r.after_days) AS due_at
      FROM jobs jb JOIN LATERAL (SELECT * FROM public.jtd_ladder_rungs(p_tenant) x WHERE x.step = jb.dunning_step + 1) r ON true
  ),
  last_nudge AS (
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.id AS reminder_id, n.channel_code, n.status_code, n.created_at, n.source_type_code, n.error_message
      FROM public.n_jtd n
     WHERE n.tenant_id = p_tenant AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_logged')
     ORDER BY n.source_id, n.created_at DESC
  ),
  open_call AS (
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.id AS task_id, n.assigned_to, n.assigned_to_name, n.created_at,
           n.scheduled_at, n.business_context->>'task_kind' AS task_kind
      FROM public.n_jtd n
     WHERE n.tenant_id = p_tenant AND n.source_type_code = 'payment_call_due' AND n.status_code IN ('assigned','in_progress','pending','created')
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
           oc.task_id AS call_task_id, oc.assigned_to AS call_assigned_to, oc.assigned_to_name AS call_assigned_to_name, oc.created_at AS call_created_at,
           oc.scheduled_at AS call_due_at, oc.task_kind AS call_task_kind,
           d.declaration_id, d.amount AS declared_amount, d.reference AS declared_reference, d.created_at AS declared_at, d.kind AS declaration_kind,
           CASE WHEN d.declaration_id IS NOT NULL THEN NULL
                WHEN jb.dunning_paused_reason = 'promise' AND jb.promise_date IS NOT NULL AND jb.promise_date < v_today THEN NULL
                ELSE jb.dunning_paused_reason END AS effective_pause
      FROM jobs jb
      LEFT JOIN rung r ON r.job_id = jb.id
      LEFT JOIN last_nudge ln ON ln.job_id = jb.id
      LEFT JOIN open_call oc ON oc.job_id = jb.id
      LEFT JOIN LATERAL (SELECT * FROM decl x WHERE x.job_id = jb.id ORDER BY x.created_at DESC LIMIT 1) d ON true
  ),
  kinded AS (
    SELECT e.*,
           CASE WHEN e.declaration_id IS NOT NULL THEN 'declaration_pending'
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
    SELECT k.id::text AS row_id, k.kind, k.id AS job_id, k.contract_id, k.contract_number::text AS contract_number, k.buyer_id, k.buyer_name::text AS buyer_name,
           k.invoice_id, k.invoice_number, k.block_name, k.billing_cycle_label AS cycle_label, k.sequence_number, k.total_occurrences,
           k.owed AS amount, COALESCE(k.currency,'INR')::text AS currency, k.due_date, k.status_code::text AS status,
           k.days_overdue, k.days_until, k.dunning_step, k.nudge_count, k.last_nudge_at,
           k.last_channel, k.last_kind, k.last_status, k.last_error, k.last_reminder_id, k.last_at,
           k.rung_step, k.rung_after_days, k.rung_channel, k.rung_due_at,
           k.effective_pause AS paused_reason, k.promise_date,
           k.declaration_id, k.declaration_kind, k.declared_amount, k.declared_reference, k.declared_at,
           k.call_task_id, k.call_assigned_to, k.call_assigned_to_name, k.call_due_at, k.call_task_kind,
           NULL::text AS awaiting_status, NULL::timestamptz AS awaiting_since, NULL::date AS awaiting_start,
           CASE k.kind
             WHEN 'declaration_pending' THEN k.declared_at
             WHEN 'send_failed'         THEN k.last_at
             WHEN 'call_open'           THEN COALESCE(k.call_due_at, k.call_created_at)
             WHEN 'paused'              THEN CASE WHEN k.effective_pause = 'promise' AND k.promise_date IS NOT NULL
                                                  THEN (k.promise_date::timestamp AT TIME ZONE 'Asia/Kolkata') ELSE NULL END
             WHEN 'rung_due'            THEN k.rung_due_at
             WHEN 'rung_ahead'          THEN k.rung_due_at
             ELSE k.scheduled_at
           END AS anchor_at
      FROM kinded k
  ),
  awaiting_rows AS (
    SELECT c.id::text AS row_id, 'awaiting_activation'::text AS kind, NULL::uuid AS job_id, c.id AS contract_id, c.contract_number::text AS contract_number, c.buyer_id, c.buyer_name::text AS buyer_name,
           NULL::uuid AS invoice_id, NULL::text AS invoice_number, NULL::text AS block_name, NULL::text AS cycle_label, NULL::integer AS sequence_number, NULL::integer AS total_occurrences,
           c.grand_total AS amount, COALESCE(c.currency,'INR')::text AS currency, (c.start_date AT TIME ZONE 'Asia/Kolkata')::date AS due_date, c.status::text AS status,
           0 AS days_overdue, NULL::integer AS days_until, 0 AS dunning_step, 0 AS nudge_count, NULL::timestamptz AS last_nudge_at,
           NULL::text AS last_channel, NULL::text AS last_kind, NULL::text AS last_status, NULL::text AS last_error, NULL::uuid AS last_reminder_id, NULL::timestamptz AS last_at,
           NULL::integer AS rung_step, NULL::integer AS rung_after_days, NULL::text AS rung_channel, NULL::timestamptz AS rung_due_at,
           NULL::text AS paused_reason, NULL::date AS promise_date,
           NULL::uuid AS declaration_id, NULL::text AS declaration_kind, NULL::numeric AS declared_amount, NULL::text AS declared_reference, NULL::timestamptz AS declared_at,
           NULL::uuid AS call_task_id, NULL::uuid AS call_assigned_to, NULL::text AS call_assigned_to_name, NULL::timestamptz AS call_due_at, NULL::text AS call_task_kind,
           c.status::text AS awaiting_status, c.created_at AS awaiting_since, (c.start_date AT TIME ZONE 'Asia/Kolkata')::date AS awaiting_start,
           c.created_at AS anchor_at
      FROM public.t_contracts c
     WHERE c.tenant_id = p_tenant AND c.record_type = 'contract' AND COALESCE(c.is_live, true) = p_is_live
       AND c.acceptance_method = 'payment' AND c.status IN ('pending_acceptance','sent') AND COALESCE(c.is_active, true)
  ),
  all_rows AS (SELECT * FROM job_rows UNION ALL SELECT * FROM awaiting_rows),
  placed AS (
    SELECT r.*,
           (r.anchor_at AT TIME ZONE 'Asia/Kolkata')::date AS anchor_date,
           ((r.anchor_at AT TIME ZONE 'Asia/Kolkata')::date - v_today) AS days
      FROM all_rows r
  ),
  bucketed AS (
    SELECT p.*,
           CASE WHEN p.anchor_at IS NULL THEN 'parked'
                WHEN p.days < 0 THEN 'overdue'
                WHEN p.days = 0 THEN 'today'
                WHEN p.days <= v_b1 THEN 'b1'
                WHEN p.days <= v_b2 THEN 'b2'
                ELSE 'b3' END AS bucket,
           CASE p.kind WHEN 'declaration_pending' THEN 0 WHEN 'send_failed' THEN 1 WHEN 'rung_due' THEN 2 WHEN 'call_open' THEN 3
                       WHEN 'overdue_no_ladder' THEN 4 WHEN 'ladder_exhausted' THEN 5 WHEN 'awaiting_activation' THEN 6
                       WHEN 'payment_ahead' THEN 7 WHEN 'rung_ahead' THEN 8 ELSE 9 END AS kind_rank,
           (CASE WHEN p.anchor_at IS NULL THEN v_from IS NULL
                 ELSE (v_from IS NULL OR (p.anchor_at AT TIME ZONE 'Asia/Kolkata')::date >= v_from)
                      AND (p.anchor_at AT TIME ZONE 'Asia/Kolkata')::date <= v_to END) AS f_window,
           (v_kinds IS NULL OR p.kind = ANY (v_kinds)) AS f_kind,
           (v_channel IS NULL OR p.rung_channel = v_channel) AS f_channel,
           (v_age IS NULL OR (v_age = '0-7'   AND p.days_overdue BETWEEN 1 AND 7)
                          OR (v_age = '8-30'  AND p.days_overdue BETWEEN 8 AND 30)
                          OR (v_age = '31-90' AND p.days_overdue BETWEEN 31 AND 90)
                          OR (v_age = '90+'   AND p.days_overdue > 90)) AS f_age,
           (v_cycle IS NULL OR p.cycle_label = v_cycle) AS f_cycle,
           (v_who = 'team' OR (v_who = 'mine' AND p_user IS NOT NULL AND p.call_assigned_to = p_user)
                           OR (v_who = 'unassigned' AND p.call_task_id IS NULL)) AS f_who,
           (v_q IS NULL OR p.buyer_name ILIKE '%' || v_q || '%' OR p.contract_number ILIKE '%' || v_q || '%'
                        OR p.invoice_number ILIKE '%' || v_q || '%' OR p.declared_reference ILIKE '%' || v_q || '%'
                        OR p.block_name ILIKE '%' || v_q || '%') AS f_q
      FROM placed p
  ),
  matched AS (
    SELECT b.* FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_who AND b.f_q
  ),
  numbered AS (
    SELECT m.*,
           row_number() OVER (PARTITION BY m.bucket ORDER BY m.kind_rank, m.anchor_at NULLS LAST, m.contract_number) AS rn,
           count(*) OVER (PARTITION BY m.bucket) AS bucket_count
      FROM matched m
  ),
  card AS (
    SELECT n.bucket, n.rn, n.bucket_count,
           jsonb_strip_nulls(jsonb_build_object(
             'id', n.row_id, 'kind', n.kind, 'bucket', n.bucket, 'days', n.days, 'anchor_at', n.anchor_at,
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
             'awaiting', CASE WHEN n.kind <> 'awaiting_activation' THEN NULL ELSE jsonb_build_object('status', n.awaiting_status, 'since', n.awaiting_since, 'start_date', n.awaiting_start) END
           )) AS card
      FROM numbered n
  ),
  bucket_defs AS (
    SELECT * FROM (VALUES
      ('overdue', 0, NULL::integer, -1),
      ('today',   1, 0, 0),
      ('b1',      2, 1, v_b1),
      ('b2',      3, v_b1 + 1, v_b2),
      ('b3',      4, v_b2 + 1, GREATEST(v_to - v_today, v_b2 + 1)),
      ('parked',  5, NULL, NULL)) AS t(key, ord, from_days, to_days)
  ),
  buckets AS (
    SELECT bd.key, bd.ord, bd.from_days, bd.to_days,
           COALESCE((SELECT max(c.bucket_count) FROM card c WHERE c.bucket = bd.key), 0) AS total,
           COALESCE((SELECT jsonb_agg(c.card ORDER BY c.rn) FROM card c
                      WHERE c.bucket = bd.key AND c.rn <= COALESCE((v_limits->>bd.key)::integer, v_limit)), '[]'::jsonb) AS cards
      FROM bucket_defs bd
  ),
  facets AS (
    SELECT
      (SELECT COALESCE(jsonb_object_agg(x.kind, x.n), '{}'::jsonb) FROM (
         SELECT b.kind, count(*) AS n FROM bucketed b
          WHERE b.f_window AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_who AND b.f_q GROUP BY b.kind) x) AS kinds,
      (SELECT COALESCE(jsonb_object_agg(x.ch, x.n), '{}'::jsonb) FROM (
         SELECT b.rung_channel AS ch, count(*) AS n FROM bucketed b
          WHERE b.rung_channel IS NOT NULL AND b.f_window AND b.f_kind AND b.f_age AND b.f_cycle AND b.f_who AND b.f_q GROUP BY b.rung_channel) x) AS channels,
      (SELECT jsonb_build_object(
         '0-7',   count(*) FILTER (WHERE b.days_overdue BETWEEN 1 AND 7),
         '8-30',  count(*) FILTER (WHERE b.days_overdue BETWEEN 8 AND 30),
         '31-90', count(*) FILTER (WHERE b.days_overdue BETWEEN 31 AND 90),
         '90+',   count(*) FILTER (WHERE b.days_overdue > 90))
         FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_channel AND b.f_cycle AND b.f_who AND b.f_q) AS ages,
      (SELECT COALESCE(jsonb_object_agg(x.cy, x.n), '{}'::jsonb) FROM (
         SELECT b.cycle_label AS cy, count(*) AS n FROM bucketed b
          WHERE b.cycle_label IS NOT NULL AND b.f_window AND b.f_kind AND b.f_channel AND b.f_age AND b.f_who AND b.f_q GROUP BY b.cycle_label) x) AS cycles,
      (SELECT jsonb_build_object(
         'team',       count(*),
         'mine',       count(*) FILTER (WHERE p_user IS NOT NULL AND b.call_assigned_to = p_user),
         'unassigned', count(*) FILTER (WHERE b.call_task_id IS NULL))
         FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_channel AND b.f_age AND b.f_cycle AND b.f_q) AS who,
      (SELECT count(*) FROM bucketed b WHERE b.f_window) AS in_window,
      (SELECT count(*) FROM matched) AS matched
  )
  SELECT jsonb_build_object(
    'buckets', (SELECT jsonb_agg(jsonb_build_object('key', b.key, 'from_days', b.from_days, 'to_days', b.to_days, 'count', b.total, 'cards', b.cards) ORDER BY b.ord) FROM buckets b),
    'facets', (SELECT jsonb_build_object('kinds', f.kinds, 'channels', f.channels, 'ages', f.ages, 'cycles', f.cycles, 'who', f.who) FROM facets f),
    'counts', (SELECT jsonb_build_object('in_window', f.in_window, 'matched', f.matched) FROM facets f)
  ) INTO v_board;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.source_type_code, 'job_id', n.source_id, 'contract_id', n.contract_id, 'contract_number', n.source_ref,
      'buyer_name', n.recipient_name, 'channel', n.channel_code, 'status', n.status_code, 'amount', n.amount, 'currency', COALESCE(n.currency,'INR'),
      'rung', n.dunning_step, 'outcome', n.metadata->>'outcome', 'notes', n.notes,
      'assigned_to', n.assigned_to, 'assigned_to_name', n.assigned_to_name,
      'task_kind', n.business_context->>'task_kind', 'due_at', CASE WHEN n.source_type_code = 'payment_call_due' THEN n.scheduled_at ELSE NULL END,
      'actor_type', n.performed_by_type, 'actor_name', n.performed_by_name, 'at', n.created_at, 'error', n.error_message)
      ORDER BY n.created_at DESC), '[]'::jsonb)
    INTO v_happened
    FROM (SELECT * FROM public.n_jtd n
           WHERE n.tenant_id = p_tenant AND COALESCE(n.is_live, true) = p_is_live
             AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_due','payment_call_logged')
           ORDER BY n.created_at DESC LIMIT 40) n;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', ut.user_id,
      'name', COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email)) ORDER BY up.first_name), '[]'::jsonb)
    INTO v_team
    FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND COALESCE(ut.status, 'active') IN ('active','accepted');

  SELECT jsonb_build_object(
      'rule_enabled', public.vani_rule_enabled(p_tenant, 'payment_reminder'),
      'vani_enabled', public.vani_is_enabled(p_tenant),
      'rungs', COALESCE((SELECT jsonb_agg(jsonb_build_object('step', r.step, 'after_days', r.after_days, 'channel', r.channel) ORDER BY r.step)
                          FROM public.jtd_ladder_rungs(p_tenant) r), '[]'::jsonb))
    INTO v_ladder;

  RETURN jsonb_build_object(
    'success', true, 'today', v_today, 'is_live', p_is_live,
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'horizon_days', CASE WHEN p_filters->>'to' IS NULL OR p_filters->>'to' = '' THEN v_horizon ELSE NULL END,
                                 'bands', jsonb_build_array(v_b1, v_b2)),
    'filters', jsonb_strip_nulls(jsonb_build_object('kinds', to_jsonb(v_kinds), 'channel', v_channel, 'age', v_age, 'cycle', v_cycle, 'who', v_who, 'q', v_q, 'limit', v_limit)),
    'buckets', v_board->'buckets', 'facets', v_board->'facets', 'counts', v_board->'counts',
    'happened', v_happened, 'team', v_team, 'ladder', v_ladder,
    'generated_at', now());
END;
$$;

-- Post-check: exactly one escalate overload, with 8 arguments.
DO $$
DECLARE v_n integer; v_args text;
BEGIN
  SELECT count(*), max(pg_get_function_arguments(p.oid)) INTO v_n, v_args
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'jtd_escalate_payment_call';
  IF v_n <> 1 OR v_args NOT LIKE '%p_due_at%' THEN
    RAISE EXCEPTION '011: expected one jtd_escalate_payment_call overload with p_due_at, found % (%)', v_n, v_args;
  END IF;
END $$;
