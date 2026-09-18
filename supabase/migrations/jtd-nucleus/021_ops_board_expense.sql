-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/021_ops_board_expense.sql  (2026-09-17)
-- The Ops board for the EXPENSE side — what needs the buyer: pay, receive,
-- accept. Same output shape as jtd_ops_board so the same page and card
-- render it; different sources (the contracts this tenant CLAIMED or is
-- being asked to accept) and buyer verbs.
--
-- Lanes · kinds (needs-you kinds marked *):
--   payables   bill_overdue* · bill_due · bill_declared (I declared, seller to confirm)
--   services   slot_offered* (the seller proposed a time — answer it) · service_in_progress
--              · service_awaited (planned day passed, seller has not come) · service_today* · service_scheduled
--   acceptance to_accept* (a contract addressed to me is waiting for my acceptance)
-- Rows carry `cnak` + `seller_name`; to_accept rows also carry
-- `review_link_suffix` (cnak=…&secret=…) so the page opens the review link
-- in-app — the grant is matched to THIS tenant's users by accessor tenant,
-- accessor email, or the seller-side contact's email / mobile, i.e. only the
-- addressee's own workspace ever sees it.
-- Title field: `buyer_name` carries the SELLER's name on this side so the
-- card's layout is unchanged (`seller_name` is also present).
-- jtd_buyer_respond_slot: the in-app twin of the public /slot/:token answer —
-- verifies the appointment belongs to a contract this tenant claimed, mints
-- the slot token if missing, and delegates to visit_slot_respond.
-- Applied live 2026-09-17 (batch ops-expense-board) — source of record.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.jtd_ops_board_expense(p_tenant uuid, p_is_live boolean DEFAULT true, p_filters jsonb DEFAULT '{}'::jsonb, p_user uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_today    date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_horizon  integer; v_from date; v_to date; v_b1 integer := 3; v_b2 integer := 14;
  v_kinds text[]; v_lanes text[]; v_age text; v_q text; v_slot text;
  v_limits jsonb; v_limit integer; v_board jsonb; v_tmp date;
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
  v_age := NULLIF(p_filters->>'age', ''); v_slot := NULLIF(p_filters->>'slot', ''); v_q := NULLIF(TRIM(COALESCE(p_filters->>'q', '')), '');
  BEGIN v_limit := NULLIF(p_filters->>'limit','')::numeric::integer; EXCEPTION WHEN others THEN v_limit := NULL; END;
  v_limit := LEAST(GREATEST(COALESCE(v_limit, 20), 1), 200);
  v_limits := '{}'::jsonb;
  IF jsonb_typeof(p_filters->'limits') = 'object' THEN
    SELECT COALESCE(jsonb_object_agg(e.key, LEAST(GREATEST(e.value::numeric::integer, 1), 500)), '{}'::jsonb) INTO v_limits
      FROM jsonb_each_text(p_filters->'limits') e WHERE jsonb_typeof(p_filters->'limits'->e.key) = 'number';
  END IF;

  WITH
  me AS (
    SELECT lower(u.email) AS email, NULLIF(right(regexp_replace(COALESCE(up.mobile_number, ''), '\D', '', 'g'), 10), '') AS mobile
      FROM public.t_user_tenants ut JOIN auth.users u ON u.id = ut.user_id
      LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
     WHERE ut.tenant_id = p_tenant AND COALESCE(ut.status, 'active') IN ('active','accepted')
  ),
  claimed AS (
    SELECT c.id, c.tenant_id AS seller_tenant_id, c.contract_number::text AS contract_number, c.name, c.global_access_id::text AS cnak, COALESCE(c.currency, 'INR')::text AS currency,
           COALESCE(NULLIF(tp.business_name, ''), t.name)::text AS seller_name
      FROM public.t_contracts c JOIN public.t_tenants t ON t.id = c.tenant_id LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = c.tenant_id
     WHERE c.record_type = 'contract' AND COALESCE(c.is_active, true) AND COALESCE(c.is_live, true) = p_is_live
       AND c.status IN ('active', 'expired', 'completed')
       AND (c.buyer_tenant_id = p_tenant
            OR EXISTS (SELECT 1 FROM public.t_contract_access a WHERE a.contract_id = c.id AND a.accessor_tenant_id = p_tenant AND a.is_active))
  ),
  pending_decl AS (
    SELECT d.invoice_id, d.id, d.amount, d.reference, d.created_at
      FROM public.t_public_payment_declarations d
     WHERE d.status = 'pending' AND COALESCE(d.is_live, true) = p_is_live
  ),
  bill_jobs AS (
    SELECT j.id, j.contract_id, j.invoice_id, j.scheduled_at, j.status_code, j.block_name, j.billing_cycle_label, j.sequence_number, j.total_occurrences,
           (j.scheduled_at AT TIME ZONE 'Asia/Kolkata')::date AS due_date,
           GREATEST(COALESCE(j.amount, 0) - COALESCE(j.amount_settled, 0), 0) AS owed,
           cl.contract_number, cl.seller_name, cl.seller_tenant_id, cl.cnak, cl.currency, i.invoice_number,
           d.id AS decl_id, d.amount AS decl_amount, d.reference AS decl_ref, d.created_at AS decl_at
      FROM public.n_jtd j JOIN claimed cl ON cl.id = j.contract_id
      LEFT JOIN public.t_invoices i ON i.id = j.invoice_id
      LEFT JOIN LATERAL (SELECT * FROM pending_decl x WHERE x.invoice_id = j.invoice_id ORDER BY x.created_at DESC LIMIT 1) d ON true
     WHERE j.event_type_code = 'payment' AND j.channel_code IS NULL AND COALESCE(j.is_active, true) AND COALESCE(j.is_live, true) = p_is_live
       AND j.status_code IN ('scheduled','due','overdue','partial_payment')
  ),
  bill_invoices AS (
    SELECT i.id, i.contract_id, i.balance, i.invoice_number, i.status,
           COALESCE(i.due_date, (i.issued_at AT TIME ZONE 'Asia/Kolkata')::date, (i.created_at AT TIME ZONE 'Asia/Kolkata')::date) AS due,
           cl.contract_number, cl.seller_name, cl.seller_tenant_id, cl.cnak, cl.currency,
           d.id AS decl_id, d.amount AS decl_amount, d.reference AS decl_ref, d.created_at AS decl_at
      FROM public.t_invoices i JOIN claimed cl ON cl.id = i.contract_id
      LEFT JOIN LATERAL (SELECT * FROM pending_decl x WHERE x.invoice_id = i.id ORDER BY x.created_at DESC LIMIT 1) d ON true
     WHERE i.invoice_type = 'receivable' AND COALESCE(i.is_active, true) AND COALESCE(i.is_live, true) = p_is_live
       AND i.status IN ('unpaid','partially_paid') AND i.balance > 0
       AND NOT EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.contract_id = i.contract_id AND j.event_type_code = 'payment' AND j.channel_code IS NULL
                          AND COALESCE(j.is_live, true) = p_is_live AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true))
  ),
  svc AS (
    SELECT e.id, e.contract_id, e.block_name, e.sequence_number, e.total_occurrences, e.scheduled_date, e.status, e.assigned_to_name, e.notes,
           (e.scheduled_date AT TIME ZONE 'Asia/Kolkata')::date AS sd,
           cl.contract_number, cl.seller_name, cl.seller_tenant_id, cl.cnak, cl.currency,
           a.id AS appt_id, a.status AS appt_status, a.scheduled_at AS appt_at, a.customer_response AS appt_response,
           st.ticket_number, st.status AS ticket_status
      FROM public.t_contract_events e JOIN claimed cl ON cl.id = e.contract_id
      LEFT JOIN LATERAL (SELECT x.id, x.status, x.scheduled_at, x.customer_response FROM public.t_appointments x
                          WHERE x.event_id = e.id AND x.is_active AND x.status NOT IN ('cancelled','declined','completed') ORDER BY x.updated_at DESC LIMIT 1) a ON true
      LEFT JOIN LATERAL (SELECT t.ticket_number, t.status FROM public.t_service_ticket_events te JOIN public.t_service_tickets t ON t.id = te.ticket_id
                          WHERE te.event_id = e.id AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1) st ON true
     WHERE e.event_type = 'service' AND COALESCE(e.is_live, true) = p_is_live AND COALESCE(e.is_active, true)
       AND e.status IN ('scheduled','due','overdue','in_progress')
  ),
  acc AS (
    SELECT a.id AS grant_id, a.global_access_id::text AS cnak, a.secret_code, a.created_at AS asked_at,
           c.id AS contract_id, c.contract_number::text AS contract_number, c.name, c.grand_total, COALESCE(c.currency, 'INR')::text AS currency, c.tenant_id AS seller_tenant_id,
           COALESCE(NULLIF(tp.business_name, ''), t.name)::text AS seller_name
      FROM public.t_contract_access a
      JOIN public.t_contracts c ON c.id = a.contract_id
      JOIN public.t_tenants t ON t.id = c.tenant_id
      LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = c.tenant_id
     WHERE a.is_active AND a.status IN ('pending','viewed','sent') AND c.status = 'pending_acceptance' AND c.record_type = 'contract'
       AND COALESCE(c.is_live, true) = p_is_live AND (a.expires_at IS NULL OR a.expires_at > now()) AND c.tenant_id <> p_tenant
       AND (a.accessor_tenant_id = p_tenant
            OR (a.accessor_email IS NOT NULL AND lower(a.accessor_email) IN (SELECT m.email FROM me m WHERE m.email IS NOT NULL))
            OR EXISTS (SELECT 1 FROM public.t_contact_channels ch JOIN me m
                         ON (ch.channel_type = 'email' AND m.email IS NOT NULL AND lower(ch.value) = m.email)
                         OR (ch.channel_type IN ('mobile','whatsapp','phone') AND m.mobile IS NOT NULL AND right(regexp_replace(COALESCE(ch.value, ''), '\D', '', 'g'), 10) = m.mobile)
                       WHERE ch.contact_id = a.accessor_contact_id))
  ),
  all_rows AS (
    -- (row_id, lane, kind, job_id, contract_id, contract_number, invoice_id, invoice_number, block_name, cycle_label, sequence_number, total_occurrences,
    --  amount, currency, due_date, status, days_overdue, days_until, seller_name, seller_tenant_id, cnak, review_link_suffix, declaration, appointment_id, slot_state, visit, anchor_at)
    SELECT b.id::text, 'payables'::text,
           CASE WHEN b.decl_id IS NOT NULL THEN 'bill_declared' WHEN b.due_date < v_today THEN 'bill_overdue' ELSE 'bill_due' END,
           b.id, b.contract_id, b.contract_number, b.invoice_id, b.invoice_number::text, b.block_name::text, b.billing_cycle_label::text, b.sequence_number, b.total_occurrences,
           b.owed, b.currency, b.due_date, b.status_code::text, GREATEST(v_today - b.due_date, 0), (b.due_date - v_today),
           b.seller_name, b.seller_tenant_id, b.cnak, NULL::text,
           CASE WHEN b.decl_id IS NULL THEN NULL ELSE jsonb_build_object('id', b.decl_id, 'kind', 'public', 'amount', b.decl_amount, 'reference', b.decl_ref, 'at', b.decl_at) END,
           NULL::uuid, NULL::text, NULL::jsonb,
           CASE WHEN b.decl_id IS NOT NULL THEN b.decl_at ELSE b.scheduled_at END
      FROM bill_jobs b
    UNION ALL
    SELECT i.id::text, 'payables',
           CASE WHEN i.decl_id IS NOT NULL THEN 'bill_declared' WHEN i.due < v_today THEN 'bill_overdue' ELSE 'bill_due' END,
           NULL::uuid, i.contract_id, i.contract_number, i.id, i.invoice_number::text, NULL::text, NULL::text, NULL::integer, NULL::integer,
           i.balance, i.currency, i.due, i.status::text, GREATEST(v_today - i.due, 0), (i.due - v_today),
           i.seller_name, i.seller_tenant_id, i.cnak, NULL::text,
           CASE WHEN i.decl_id IS NULL THEN NULL ELSE jsonb_build_object('id', i.decl_id, 'kind', 'public', 'amount', i.decl_amount, 'reference', i.decl_ref, 'at', i.decl_at) END,
           NULL::uuid, NULL::text, NULL::jsonb,
           CASE WHEN i.decl_id IS NOT NULL THEN i.decl_at ELSE (i.due::timestamp AT TIME ZONE 'Asia/Kolkata') END
      FROM bill_invoices i
    UNION ALL
    SELECT v.id::text, 'services',
           CASE WHEN v.status = 'in_progress' OR v.ticket_status = 'in_progress' THEN 'service_in_progress'
                WHEN v.appt_id IS NOT NULL AND v.appt_at IS NOT NULL AND v.appt_status IN ('requested','rescheduled')
                     AND COALESCE(v.appt_response->>'action', '') <> 'propose' THEN 'slot_offered'
                WHEN v.sd < v_today THEN 'service_awaited' WHEN v.sd = v_today THEN 'service_today' ELSE 'service_scheduled' END,
           v.id, v.contract_id, v.contract_number, NULL::uuid, NULL::text, v.block_name::text, NULL::text, v.sequence_number, v.total_occurrences,
           NULL::numeric, v.currency, v.sd, v.status::text, GREATEST(v_today - v.sd, 0), (v.sd - v_today),
           v.seller_name, v.seller_tenant_id, v.cnak, NULL::text, NULL::jsonb,
           v.appt_id,
           CASE WHEN v.appt_status = 'accepted' THEN 'confirmed' WHEN v.appt_id IS NOT NULL AND v.appt_at IS NOT NULL THEN 'proposed' ELSE 'none' END,
           jsonb_strip_nulls(jsonb_build_object(
             'block_name', v.block_name, 'sequence', v.sequence_number, 'of', v.total_occurrences, 'scheduled_at', v.scheduled_date, 'notes', v.notes,
             'assigned_to_name', v.assigned_to_name,
             'slot', CASE WHEN v.appt_id IS NULL THEN NULL ELSE jsonb_build_object('id', v.appt_id, 'status', v.appt_status, 'at', v.appt_at, 'confirmed', v.appt_status = 'accepted',
                                                                                  'my_answer', v.appt_response) END,
             'ticket', CASE WHEN v.ticket_number IS NULL THEN NULL ELSE jsonb_build_object('number', v.ticket_number, 'status', v.ticket_status) END)),
           CASE WHEN v.appt_id IS NOT NULL AND v.appt_at IS NOT NULL AND v.appt_status IN ('requested','rescheduled') AND COALESCE(v.appt_response->>'action', '') <> 'propose' THEN v.appt_at
                ELSE v.scheduled_date END
      FROM svc v
    UNION ALL
    SELECT a.grant_id::text, 'acceptance', 'to_accept',
           NULL::uuid, a.contract_id, a.contract_number, NULL::uuid, NULL::text, a.name::text, NULL::text, NULL::integer, NULL::integer,
           a.grand_total, a.currency, (a.asked_at AT TIME ZONE 'Asia/Kolkata')::date, 'pending_acceptance', 0, 0,
           a.seller_name, a.seller_tenant_id, a.cnak, 'cnak=' || a.cnak || '&secret=' || COALESCE(a.secret_code, ''), NULL::jsonb,
           NULL::uuid, NULL::text, NULL::jsonb,
           a.asked_at
      FROM acc a
  ),
  named AS (
    SELECT r.*
      FROM all_rows AS r(row_id, lane, kind, job_id, contract_id, contract_number, invoice_id, invoice_number, block_name, cycle_label, sequence_number, total_occurrences,
                         amount, currency, due_date, status, days_overdue, days_until, seller_name, seller_tenant_id, cnak, review_link_suffix, declaration, appointment_id, slot_state, visit, anchor_at)
  ),
  placed AS (
    SELECT n.*, (n.anchor_at AT TIME ZONE 'Asia/Kolkata')::date AS anchor_date, ((n.anchor_at AT TIME ZONE 'Asia/Kolkata')::date - v_today) AS days FROM named n
  ),
  bucketed AS (
    SELECT p.*,
           CASE WHEN p.anchor_at IS NULL THEN 'parked' WHEN p.days < 0 THEN 'overdue' WHEN p.days = 0 THEN 'today'
                WHEN p.days <= v_b1 THEN 'b1' WHEN p.days <= v_b2 THEN 'b2' ELSE 'b3' END AS bucket,
           CASE p.kind WHEN 'to_accept' THEN 0 WHEN 'slot_offered' THEN 1 WHEN 'bill_overdue' THEN 2 WHEN 'service_in_progress' THEN 3 WHEN 'service_today' THEN 4
                       WHEN 'service_awaited' THEN 5 WHEN 'bill_declared' THEN 6 WHEN 'bill_due' THEN 7 WHEN 'service_scheduled' THEN 8 ELSE 9 END AS kind_rank,
           (CASE WHEN p.anchor_at IS NULL THEN v_from IS NULL
                 ELSE (v_from IS NULL OR (p.anchor_at AT TIME ZONE 'Asia/Kolkata')::date >= v_from) AND (p.anchor_at AT TIME ZONE 'Asia/Kolkata')::date <= v_to END) AS f_window,
           (v_kinds IS NULL OR p.kind = ANY (v_kinds)) AS f_kind,
           (v_lanes IS NULL OR p.lane = ANY (v_lanes)) AS f_lane,
           (v_age IS NULL OR (v_age = '0-7' AND p.days_overdue BETWEEN 1 AND 7) OR (v_age = '8-30' AND p.days_overdue BETWEEN 8 AND 30)
                          OR (v_age = '31-90' AND p.days_overdue BETWEEN 31 AND 90) OR (v_age = '90+' AND p.days_overdue > 90)) AS f_age,
           (v_slot IS NULL OR p.slot_state = v_slot) AS f_slot,
           (v_q IS NULL OR p.seller_name ILIKE '%' || v_q || '%' OR p.contract_number ILIKE '%' || v_q || '%' OR p.invoice_number ILIKE '%' || v_q || '%'
                        OR p.block_name ILIKE '%' || v_q || '%') AS f_q
      FROM placed p
  ),
  matched AS (SELECT b.* FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_lane AND b.f_age AND b.f_slot AND b.f_q),
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
             'buyer_name', n.seller_name, 'seller_name', n.seller_name, 'seller_tenant_id', n.seller_tenant_id, 'cnak', n.cnak, 'review_link_suffix', n.review_link_suffix,
             'invoice_id', n.invoice_id, 'invoice_number', n.invoice_number,
             'block_name', n.block_name, 'cycle_label', n.cycle_label, 'sequence', n.sequence_number, 'of', n.total_occurrences,
             'amount', n.amount, 'currency', n.currency, 'due_date', n.due_date, 'status', n.status,
             'days_overdue', n.days_overdue, 'days_until', n.days_until,
             'dunning_step', 0, 'nudge_count', 0,
             'declaration', n.declaration, 'appointment_id', n.appointment_id, 'slot_state', n.slot_state, 'visit', n.visit)) AS card
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
      (SELECT COALESCE(jsonb_object_agg(x.kind, x.n), '{}'::jsonb) FROM (SELECT b.kind, count(*) AS n FROM bucketed b WHERE b.f_window AND b.f_lane AND b.f_age AND b.f_slot AND b.f_q GROUP BY b.kind) x) AS kinds,
      (SELECT COALESCE(jsonb_object_agg(x.lane, x.n), '{}'::jsonb) FROM (SELECT b.lane, count(*) AS n FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_age AND b.f_slot AND b.f_q GROUP BY b.lane) x) AS lanes,
      (SELECT jsonb_build_object('0-7', count(*) FILTER (WHERE b.days_overdue BETWEEN 1 AND 7), '8-30', count(*) FILTER (WHERE b.days_overdue BETWEEN 8 AND 30),
                                 '31-90', count(*) FILTER (WHERE b.days_overdue BETWEEN 31 AND 90), '90+', count(*) FILTER (WHERE b.days_overdue > 90))
         FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_lane AND b.f_slot AND b.f_q) AS ages,
      (SELECT COALESCE(jsonb_object_agg(x.s, x.n), '{}'::jsonb) FROM (SELECT b.slot_state AS s, count(*) AS n FROM bucketed b WHERE b.slot_state IS NOT NULL AND b.f_window AND b.f_kind AND b.f_lane AND b.f_age AND b.f_q GROUP BY b.slot_state) x) AS slots,
      (SELECT jsonb_build_object('team', count(*), 'mine', 0, 'unassigned', 0) FROM bucketed b WHERE b.f_window AND b.f_kind AND b.f_lane AND b.f_age AND b.f_slot AND b.f_q) AS who,
      (SELECT jsonb_build_object('payables', count(*) FILTER (WHERE b.lane = 'payables'), 'services', count(*) FILTER (WHERE b.lane = 'services'), 'acceptance', count(*) FILTER (WHERE b.lane = 'acceptance'))
         FROM bucketed b WHERE b.f_window AND b.kind IN ('bill_overdue','slot_offered','service_today','to_accept')) AS needs_by_lane,
      (SELECT count(*) FROM bucketed b WHERE b.f_window) AS in_window,
      (SELECT count(*) FROM matched) AS matched
  )
  SELECT jsonb_build_object(
    'buckets', (SELECT jsonb_agg(jsonb_build_object('key', b.key, 'from_days', b.from_days, 'to_days', b.to_days, 'count', b.total, 'cards', b.cards) ORDER BY b.ord) FROM buckets b),
    'facets', (SELECT jsonb_build_object('kinds', f.kinds, 'lanes', f.lanes, 'channels', '{}'::jsonb, 'ages', f.ages, 'cycles', '{}'::jsonb, 'slots', f.slots, 'who', f.who, 'needs_by_lane', f.needs_by_lane) FROM facets f),
    'counts', (SELECT jsonb_build_object('in_window', f.in_window, 'matched', f.matched) FROM facets f)
  ) INTO v_board;

  RETURN jsonb_build_object(
    'success', true, 'perspective', 'expense', 'today', v_today, 'is_live', p_is_live,
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'horizon_days', CASE WHEN p_filters->>'to' IS NULL OR p_filters->>'to' = '' THEN v_horizon ELSE NULL END, 'bands', jsonb_build_array(v_b1, v_b2)),
    'filters', jsonb_strip_nulls(jsonb_build_object('kinds', to_jsonb(v_kinds), 'lanes', to_jsonb(v_lanes), 'age', v_age, 'slot', v_slot, 'q', v_q, 'limit', v_limit)),
    'buckets', v_board->'buckets', 'facets', v_board->'facets', 'counts', v_board->'counts',
    'happened', '[]'::jsonb, 'team', '[]'::jsonb,
    'ladder', jsonb_build_object('rule_enabled', false, 'vani_enabled', public.vani_is_enabled(p_tenant), 'rungs', '[]'::jsonb),
    'ask_channels', '[]'::jsonb,
    'generated_at', now());
END;
$function$;

-- The buyer answers a slot from inside the app — same tool as the public link.
CREATE OR REPLACE FUNCTION public.jtd_buyer_respond_slot(p_tenant uuid, p_appointment_id uuid, p_action text, p_proposed_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_tok uuid; v_r jsonb;
BEGIN
  IF p_tenant IS NULL OR p_appointment_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_request'); END IF;
  IF p_action NOT IN ('accept','propose','decline') THEN RETURN jsonb_build_object('success', false, 'reason', 'bad_action'); END IF;
  -- 021b (applied live as jtd_nucleus_021b_buyer_respond_slot_guard): FOUND, not a flag that
  -- SELECT INTO nulls when no row matches (NOT NULL never fires); and the seller is never the buyer.
  SELECT a.slot_token INTO v_tok
    FROM public.t_appointments a JOIN public.t_contracts c ON c.id = a.contract_id
   WHERE a.id = p_appointment_id AND a.is_active AND c.tenant_id <> p_tenant
     AND (c.buyer_tenant_id = p_tenant
          OR EXISTS (SELECT 1 FROM public.t_contract_access g WHERE g.contract_id = c.id AND g.accessor_tenant_id = p_tenant AND g.is_active))
   FOR UPDATE OF a;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'reason', 'not_your_contract'); END IF;
  IF v_tok IS NULL THEN
    v_tok := gen_random_uuid();
    UPDATE public.t_appointments SET slot_token = v_tok WHERE id = p_appointment_id;
  END IF;
  v_r := public.visit_slot_respond(v_tok, p_action, p_proposed_at, p_note);
  RETURN jsonb_build_object('success', COALESCE((v_r->>'ok')::boolean, false)) || (v_r - 'ok');
END;
$function$;
