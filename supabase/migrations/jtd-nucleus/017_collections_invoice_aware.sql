-- ============================================================================
-- 017_collections_invoice_aware.sql — a Collections row is A PAYMENT DUE, in
-- any of its shapes (batch collections-invoice-aware, 2026-09-17)
-- ============================================================================
-- Owner: "collection might not be an installment — it might be an installment
-- under an invoice or the whole invoice completely"; "we already have
-- /invoices functionality — reuse."
--
-- Measured before this migration (live): 58 invoices cover several
-- instalments, 74 invoices are one instalment, 800 billing events have no
-- invoice yet — all of those already reach the board through payment jobs.
-- But an invoice with NO billing schedule under it (renown-wspace ₹6.3 L,
-- stw ₹4.42 L, signia ₹2.67 L, vikuna ₹18 k — eight live invoices, ₹13.6 L)
-- never appeared on the board or the register: both read events / payment
-- jobs, never t_invoices. Money In shows them, so the pages disagreed.
--
-- PART A · jtd_ops_board gains INVOICE ROWS, using Money In's own rule for a
--   whole-invoice due (get_tenant_receivables' `ev` union): an open receivable
--   invoice (unpaid / partially_paid, balance > 0) whose contract has no live
--   billing event. Excluded when an OPEN payment job already points at the
--   invoice (that job is the row). Kinds `invoice_overdue` (needs you) and
--   `invoice_ahead` (coming due); anchor = due date (issued/created when the
--   invoice has none); amount = balance; lane collections; no ladder — the
--   ladder tools work on payment jobs. Their tools are the existing per-invoice
--   send (fn_enqueue_invoice_notification via POST /api/invoices/:id/send,
--   source type `payment_request`) and View invoice. `nudge_count` /
--   `last_nudge_at` / `last_channel` on these rows count those sends so the
--   evidence line reads "sent 2× · last email 3 Sep".
--   The "what happened" feed now includes `payment_request` rows.
--   Applied as a live anchor rewrite of the deployed body (the technique of
--   014/015): every anchor must match exactly once and the post-check RAISEs
--   if the rewrite did not land. The staged 014 file carries the same text.
--
-- PART B · jtd_tasks — the Commitments Register's Follow-ups lane: every call
--   task (`payment_call_due`), open or closed, with its due date, assignee,
--   kind (follow_up = self-assigned + dated, else escalation), the payment it
--   is about, and how it closed (the first call logged after it). Filters
--   from/to (IST days on the due date), who, kind, state open|closed|all, q,
--   paging. Counts ignore the state filter. Never returns totals of money.
--
-- APPLIED LIVE 2026-09-17 (probe in a DO block ending in RAISE, then applied).
-- Source of record. Spec: OPS-JTD-TOOLS-SPEC §5.
-- ============================================================================

-- ───────────────────────────── PART A ──────────────────────────────────────
DO $do$
DECLARE
  v_src text; v_new text;
  a1 text := 'all_rows AS (SELECT * FROM job_rows UNION ALL SELECT * FROM awaiting_rows UNION ALL SELECT * FROM visit_rows)';
  a2 text := 'WHEN ''overdue_no_ladder'' THEN 7';
  a3 text := 'WHEN ''payment_ahead'' THEN 11';
  a4 text := '''awaiting_activation'',''visit_overdue''';
  a5 text := '''payment_call_due'',''payment_call_logged'') ORDER BY n.created_at DESC LIMIT 40';
  r1 text;
  cnt integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'jtd_ops_board';
  IF v_src IS NULL THEN RAISE EXCEPTION 'jtd_ops_board not found'; END IF;

  -- each anchor exactly once
  IF (length(v_src) - length(replace(v_src, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'anchor a1 (all_rows) not unique'; END IF;
  IF (length(v_src) - length(replace(v_src, a2, ''))) / length(a2) <> 1 THEN RAISE EXCEPTION 'anchor a2 (kind_rank 7) not unique'; END IF;
  IF (length(v_src) - length(replace(v_src, a3, ''))) / length(a3) <> 1 THEN RAISE EXCEPTION 'anchor a3 (kind_rank 11) not unique'; END IF;
  IF (length(v_src) - length(replace(v_src, a4, ''))) / length(a4) <> 1 THEN RAISE EXCEPTION 'anchor a4 (needs_by_lane) not unique'; END IF;
  IF (length(v_src) - length(replace(v_src, a5, ''))) / length(a5) <> 1 THEN RAISE EXCEPTION 'anchor a5 (happened feed) not unique'; END IF;
  IF position('invoice_rows' in v_src) > 0 THEN RAISE EXCEPTION 'jtd_ops_board already carries invoice_rows — 017 applied before'; END IF;

  -- A1: the invoice rows, same 53 columns as job_rows / awaiting_rows / visit_rows
  r1 := $r$invoice_rows AS (
    -- a WHOLE-INVOICE due: Money In's rule (get_tenant_receivables `ev` union) — open receivable invoice, balance > 0,
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
  all_rows AS (SELECT * FROM job_rows UNION ALL SELECT * FROM awaiting_rows UNION ALL SELECT * FROM visit_rows UNION ALL SELECT * FROM invoice_rows)$r$;

  v_new := replace(v_src, a1, r1);
  v_new := replace(v_new, a2, a2 || ' WHEN ''invoice_overdue'' THEN 7');
  v_new := replace(v_new, a3, a3 || ' WHEN ''invoice_ahead'' THEN 11');
  v_new := replace(v_new, a4, '''awaiting_activation'',''invoice_overdue'',''visit_overdue''');
  v_new := replace(v_new, a5, '''payment_call_due'',''payment_call_logged'',''payment_request'') ORDER BY n.created_at DESC LIMIT 40');

  EXECUTE v_new;

  -- post-check: the rewrite landed
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'jtd_ops_board';
  cnt := (length(v_src) - length(replace(v_src, 'invoice_rows', ''))) / length('invoice_rows');
  IF cnt <> 2 THEN RAISE EXCEPTION 'post-check: invoice_rows expected 2 occurrences, found %', cnt; END IF;
  IF position('''invoice_overdue'' THEN 7' in v_src) = 0 OR position('''invoice_ahead'' THEN 11' in v_src) = 0 THEN RAISE EXCEPTION 'post-check: kind_rank not rewritten'; END IF;
  IF position('''awaiting_activation'',''invoice_overdue'',''visit_overdue''' in v_src) = 0 THEN RAISE EXCEPTION 'post-check: needs_by_lane not rewritten'; END IF;
  IF position('''payment_request'') ORDER BY n.created_at DESC LIMIT 40' in v_src) = 0 THEN RAISE EXCEPTION 'post-check: feed not rewritten'; END IF;
END
$do$;

COMMENT ON FUNCTION public.jtd_ops_board(uuid, boolean, jsonb, uuid) IS
  'Ops board: one row per open commitment — payment jobs (Collections), contracts awaiting the activation payment, whole-invoice dues with no billing schedule (invoice_overdue / invoice_ahead, Money In''s rule, 017), service visits (Services). Filters, facets, per-bucket paging server-side. Never returns totals. Spec: OPS-JTD-TOOLS-SPEC §5.';

-- ───────────────────────────── PART B ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.jtd_tasks(
  p_tenant  uuid,
  p_is_live boolean DEFAULT true,
  p_filters jsonb   DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today  date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
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
    SELECT n.id, n.status_code, n.scheduled_at, n.created_at, n.completed_at, n.assigned_to, n.assigned_to_name,
           n.performed_by_type, n.performed_by_name, n.notes,
           COALESCE(n.business_context->>'task_kind', 'escalation') AS kind,
           n.source_id AS job_id, COALESCE(j.contract_id, n.contract_id) AS contract_id,
           c.contract_number, c.buyer_id, c.buyer_name, j.invoice_id, i.invoice_number,
           GREATEST(COALESCE(j.amount, 0) - COALESCE(j.amount_settled, 0), 0) AS owed, COALESCE(j.currency, 'INR') AS currency,
           j.billing_cycle_label, j.status_code AS payment_status, (j.scheduled_at AT TIME ZONE 'Asia/Kolkata')::date AS payment_due,
           n.status_code IN ('assigned','in_progress','pending','created') AS is_open,
           (COALESCE(n.scheduled_at, n.created_at) AT TIME ZONE 'Asia/Kolkata')::date AS due_on,
           l.outcome, l.notes AS outcome_notes, l.created_at AS logged_at, l.performed_by_name AS logged_by
      FROM public.n_jtd n
      LEFT JOIN public.n_jtd j ON j.id = n.source_id
      LEFT JOIN public.t_contracts c ON c.id = COALESCE(j.contract_id, n.contract_id)
      LEFT JOIN public.t_invoices i ON i.id = j.invoice_id
      LEFT JOIN LATERAL (SELECT x.metadata->>'outcome' AS outcome, x.notes, x.created_at, x.performed_by_name
                           FROM public.n_jtd x WHERE x.source_type_code = 'payment_call_logged' AND x.source_id = n.source_id AND x.created_at >= n.created_at
                          ORDER BY x.created_at LIMIT 1) l ON true
     WHERE n.tenant_id = p_tenant AND n.source_type_code = 'payment_call_due' AND COALESCE(n.is_live, true) = p_is_live
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
     ORDER BY CASE WHEN is_open THEN 0 ELSE 1 END,
              CASE WHEN is_open THEN due_on END ASC NULLS LAST,
              CASE WHEN NOT is_open THEN due_on END DESC NULLS LAST,
              created_at DESC
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

COMMENT ON FUNCTION public.jtd_tasks(uuid, boolean, jsonb) IS
  'Commitments Register · Follow-ups: every call task (payment_call_due), open or closed, with due date, assignee, kind (follow_up | escalation), the payment it is about and how it closed. Filters from/to (IST days on the due date), who, kind, state open|closed|all, q, limit/offset. Counts ignore the state filter. Never returns totals of money. Spec: OPS-JTD-TOOLS-SPEC §5.';
