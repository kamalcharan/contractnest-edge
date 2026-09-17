-- ============================================================================
-- 009_collections_ladder_tools.sql — Ops on JTD, item 1: the collections
-- ladder tools and the cockpit reader. Spec: specs/OPS-JTD-TOOLS-SPEC.md
-- §3.2 (data), §4 (tools), §5 (reader), §6 (ladder semantics).
-- ============================================================================
-- Owner (2026-09-16): "existing JTD items … most of it will only require
-- enhancement and proper bookkeeping." That is this file. It adds NO new
-- pipeline: a nudge is an ordinary n_jtd reminder row inserted with
-- status 'created', so the existing BEFORE INSERT trigger queues it and the
-- existing jtd-worker sends it through the existing per-channel handlers,
-- using template rows that point at ALREADY-APPROVED provider templates.
-- Everything else here is bookkeeping (which rung a payment job is on) and
-- reading (what the cockpit shows).
--
-- Additive only. No existing function is modified. Idempotent.
--
-- What is added
--   n_jtd: dunning_step, next_dunning_at, nudge_count, last_nudge_at,
--          dunning_paused_reason, promise_date   (meaningful on payment jobs)
--   n_jtd_source_types: payment_nudge_email · payment_nudge_whatsapp ·
--          payment_call_due (open task, assigned) · payment_call_logged
--   n_jtd_templates (global): payment_nudge_email  → provider payment_due_email_v1
--                             payment_nudge_whatsapp → provider payment_request_v2
--          (the worker resolves templates by source_type + channel, tenant
--           first then global — index.ts getTemplate — so a new source type
--           needs its own template row; pointing at an approved provider
--           template means no MSG91 registration is needed for email. The
--           WhatsApp one reuses payment_request_v2, which is registered but
--           has never been sent through — first live send is the proof.)
--   Indexes incl. the rung idempotency index (a rung can never fire twice).
--   Helpers: jtd_ladder_rungs · jtd_rung_due_at · jtd_recompute_dunning
--   Tools:   jtd_nudge_payment · jtd_log_payment_call · jtd_escalate_payment_call
--            jtd_pause_dunning · jtd_resume_dunning
--   Reader:  jtd_collections_worklist
--
-- Ladder source: the tenant's `payment_reminder` automation rule
-- (email_days_after_due / whatsapp_days_after_due / call_days_after_due,
-- migration vani-agent/004). The rungs are computed REGARDLESS of that
-- rule's on/off switch: the switch governs AUTOMATION (the scanner's
-- pre-due email today, the engines later); a human invoking a tool is the
-- manual product and must always be able to act. Deliberate — BBB has the
-- rule OFF (turning it on would make the scanner email 54 invoices at once).
--
-- Legacy re-check (spec §3.1): until the JTD cutover, every tool that sends
-- money-related communication re-reads t_contract_events (same id) and
-- refuses if that row is paid/settled.
--
-- Dispatch hour: rungs fall due at 10:00 IST on their day, never earlier
-- (the group-session midnight-send lesson). Tenant timezone is not modelled
-- yet (CLAUDE.md migration 048 note) — 'Asia/Kolkata' is hardcoded here too.
--
-- APPLIED LIVE 2026-09-16 after a guarded BEGIN…ROLLBACK run that exercised
-- every tool and refusal against real BBB jobs (see COPY_INSTRUCTIONS).
-- ============================================================================

-- ─── 1. Bookkeeping columns ────────────────────────────────────────────────
ALTER TABLE public.n_jtd
  ADD COLUMN IF NOT EXISTS dunning_step          integer     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS next_dunning_at       timestamptz,
  ADD COLUMN IF NOT EXISTS nudge_count           integer     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_nudge_at         timestamptz,
  ADD COLUMN IF NOT EXISTS dunning_paused_reason text,
  ADD COLUMN IF NOT EXISTS promise_date          date;

COMMENT ON COLUMN public.n_jtd.dunning_step IS
  'Payment jobs: rungs of the tenant ladder completed (0 = none). On nudge/call/escalation rows: the rung this row IS (0 = ad-hoc).';
COMMENT ON COLUMN public.n_jtd.next_dunning_at IS
  'Payment jobs: cache of when the next rung falls due (jtd_recompute_dunning). NULL when paused, finished, paid. The reader recomputes live and does not depend on it.';
COMMENT ON COLUMN public.n_jtd.nudge_count IS
  'Payment jobs: reminders + calls actually made, any channel. The rows with source_id = this job are the proof.';
COMMENT ON COLUMN public.n_jtd.dunning_paused_reason IS
  'Payment jobs: promise | dispute | manual | NULL. (declaration_pending is a read-time state, never written.)';

-- ─── 2. Source types ───────────────────────────────────────────────────────
INSERT INTO public.n_jtd_source_types
  (code, name, description, default_event_type, source_table, source_id_field, default_channels, is_active)
VALUES
  ('payment_nudge_email',    'Payment nudge (email)',    'Collections ladder rung sent by email. source_id = the payment job.',            'reminder', 'n_jtd', 'id', ARRAY['email'],    true),
  ('payment_nudge_whatsapp', 'Payment nudge (WhatsApp)', 'Collections ladder rung sent by WhatsApp. source_id = the payment job.',         'reminder', 'n_jtd', 'id', ARRAY['whatsapp'], true),
  ('payment_call_due',       'Payment call due',         'Collections ladder call rung: an OPEN task assigned to a named user.',           'task',     'n_jtd', 'id', ARRAY[]::varchar[], true),
  ('payment_call_logged',    'Payment call logged',      'A human''s record of a call about a payment job (outcome, notes, promise date).','task',     'n_jtd', 'id', ARRAY[]::varchar[], true)
ON CONFLICT (code) DO NOTHING;

-- ─── 3. Templates for the two nudge source types (global rows) ────────────
INSERT INTO public.n_jtd_templates
  (tenant_id, template_key, name, description, channel_code, source_type_code,
   subject, content, content_html, variables, provider_template_id, is_live, is_active)
SELECT NULL, 'payment_nudge_email', 'Payment nudge (email)',
       'Collections ladder rung. Reuses the approved MSG91 email template payment_due_email_v1.',
       'email', 'payment_nudge_email',
       t.subject, t.content, t.content_html, t.variables, t.provider_template_id, true, true
  FROM public.n_jtd_templates t
 WHERE t.template_key = 'payment_due_email_v1' AND t.tenant_id IS NULL AND t.is_active
   AND NOT EXISTS (SELECT 1 FROM public.n_jtd_templates x WHERE x.template_key = 'payment_nudge_email' AND x.tenant_id IS NULL)
 LIMIT 1;

INSERT INTO public.n_jtd_templates
  (tenant_id, template_key, name, description, channel_code, source_type_code,
   subject, content, content_html, variables, provider_template_id, is_live, is_active)
SELECT NULL, 'payment_nudge_whatsapp', 'Payment nudge (WhatsApp)',
       'Collections ladder rung. Reuses the registered MSG91 WhatsApp template payment_request_v2 (positional; variables in declared order).',
       'whatsapp', 'payment_nudge_whatsapp',
       t.subject, t.content, t.content_html, t.variables, t.provider_template_id, true, true
  FROM public.n_jtd_templates t
 WHERE t.template_key = 'payment_request_whatsapp' AND t.tenant_id IS NULL AND t.is_active
   AND NOT EXISTS (SELECT 1 FROM public.n_jtd_templates x WHERE x.template_key = 'payment_nudge_whatsapp' AND x.tenant_id IS NULL)
 LIMIT 1;

-- ─── 4. Indexes ────────────────────────────────────────────────────────────
-- A rung can never fire twice for the same job, whoever invokes it.
CREATE UNIQUE INDEX IF NOT EXISTS ux_n_jtd_dunning_rung
  ON public.n_jtd (source_id, source_type_code, dunning_step)
  WHERE source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_due')
    AND dunning_step > 0;

CREATE INDEX IF NOT EXISTS idx_n_jtd_tenant_type_status_sched
  ON public.n_jtd (tenant_id, event_type_code, status_code, scheduled_at);
CREATE INDEX IF NOT EXISTS idx_n_jtd_source_id
  ON public.n_jtd (source_id) WHERE source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_n_jtd_next_dunning
  ON public.n_jtd (tenant_id, next_dunning_at) WHERE next_dunning_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_n_jtd_task_assignee
  ON public.n_jtd (tenant_id, assigned_to, status_code) WHERE event_type_code = 'task';

-- ─── 5. Helpers ────────────────────────────────────────────────────────────

-- The tenant's ladder as ordered rungs. Computed from the payment_reminder
-- rule's arrays regardless of the rule's on/off (see header).
CREATE OR REPLACE FUNCTION public.jtd_ladder_rungs(p_tenant uuid)
RETURNS TABLE (step integer, after_days integer, channel text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH r AS (
    SELECT d AS after_days, 'email'::text    AS channel, 1 AS pri FROM unnest(public.vani_rule_int_array(p_tenant, 'payment_reminder', 'email_days_after_due',    '{}'::int[])) d
    UNION ALL
    SELECT d,               'whatsapp'::text,            2        FROM unnest(public.vani_rule_int_array(p_tenant, 'payment_reminder', 'whatsapp_days_after_due', '{}'::int[])) d
    UNION ALL
    SELECT d,               'call'::text,                3        FROM unnest(public.vani_rule_int_array(p_tenant, 'payment_reminder', 'call_days_after_due',     '{}'::int[])) d
  )
  SELECT row_number() OVER (ORDER BY after_days, pri)::integer, after_days, channel FROM r;
$$;

-- When a rung falls due: its day at 10:00 IST, never earlier.
CREATE OR REPLACE FUNCTION public.jtd_rung_due_at(p_due timestamptz, p_after_days integer)
RETURNS timestamptz
LANGUAGE sql IMMUTABLE AS $$
  SELECT (((p_due AT TIME ZONE 'Asia/Kolkata')::date + p_after_days) + time '10:00') AT TIME ZONE 'Asia/Kolkata';
$$;

-- Refresh next_dunning_at for one payment job from its step, pause and the
-- tenant ladder. Returns the new value.
CREATE OR REPLACE FUNCTION public.jtd_recompute_dunning(p_job uuid)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job  public.n_jtd%ROWTYPE;
  v_next timestamptz;
BEGIN
  SELECT * INTO v_job FROM public.n_jtd WHERE id = p_job AND event_type_code = 'payment';
  IF v_job.id IS NULL THEN RETURN NULL; END IF;

  IF v_job.status_code IN ('paid','cancelled','bad_debt')
     OR COALESCE(v_job.amount_settled, 0) >= COALESCE(v_job.amount, 0)
     OR v_job.dunning_paused_reason IS NOT NULL THEN
    v_next := NULL;
  ELSE
    SELECT public.jtd_rung_due_at(v_job.scheduled_at, r.after_days) INTO v_next
      FROM public.jtd_ladder_rungs(v_job.tenant_id) r
     WHERE r.step = v_job.dunning_step + 1;
  END IF;

  UPDATE public.n_jtd SET next_dunning_at = v_next WHERE id = p_job AND next_dunning_at IS DISTINCT FROM v_next;
  RETURN v_next;
END;
$$;

-- ─── 6. Tools ──────────────────────────────────────────────────────────────

-- Send a reminder for a payment job on email or WhatsApp. Counts as the
-- currently-due rung when there is one (any channel satisfies it — the
-- human's judgement wins), otherwise as an ad-hoc nudge (rung 0).
CREATE OR REPLACE FUNCTION public.jtd_nudge_payment(
  p_tenant       uuid,
  p_job_id       uuid,
  p_channel      text,
  p_actor_type   text,
  p_actor_id     uuid,
  p_actor_name   text,
  p_note         text DEFAULT NULL,
  p_payment_link text DEFAULT NULL,
  p_upi_id       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job        public.n_jtd%ROWTYPE;
  v_legacy     record;
  v_contract   record;
  v_inv        record;
  v_contact    uuid;
  v_name       text;
  v_address    text;
  v_tenant     text;
  v_owed       numeric;
  v_amount_disp text;
  v_due_disp   text;
  v_pay        jsonb;
  v_vars       jsonb;
  v_rung       record;
  v_rung_no    integer := 0;
  v_recent     timestamptz;
  v_reminder   uuid;
  v_next       timestamptz;
  v_today      date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF p_channel NOT IN ('email','whatsapp') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unsupported_channel');
  END IF;
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
  END IF;

  SELECT * INTO v_job FROM public.n_jtd
   WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment'
   FOR UPDATE;
  IF v_job.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'job_not_found');
  END IF;

  IF v_job.status_code NOT IN ('scheduled','due','overdue','partial_payment') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'job_not_open', 'status', v_job.status_code);
  END IF;

  -- Legacy re-check until cutover (same id in t_contract_events)
  SELECT e.status, e.amount, e.amount_settled INTO v_legacy
    FROM public.t_contract_events e WHERE e.id = p_job_id;
  IF v_legacy.status IS NOT NULL AND (v_legacy.status = 'paid' OR COALESCE(v_legacy.amount_settled,0) >= COALESCE(v_legacy.amount,0)) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'already_paid', 'legacy_status', v_legacy.status);
  END IF;

  v_owed := GREATEST(COALESCE(v_job.amount,0) - COALESCE(v_job.amount_settled,0), 0);
  IF v_owed <= 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'nothing_owed');
  END IF;

  -- Pauses: written ones, and the read-time "a declaration is waiting"
  IF v_job.dunning_paused_reason IS NOT NULL
     AND NOT (v_job.dunning_paused_reason = 'promise' AND v_job.promise_date IS NOT NULL AND v_job.promise_date < v_today) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'paused',
                              'paused_reason', v_job.dunning_paused_reason, 'promise_date', v_job.promise_date);
  END IF;
  IF EXISTS (SELECT 1 FROM public.t_session_payment_declarations d
              WHERE d.billing_event_id = p_job_id AND d.status = 'pending')
     OR (v_job.invoice_id IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.t_public_payment_declarations d
           WHERE d.invoice_id = v_job.invoice_id AND d.status = 'pending')) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'declaration_pending');
  END IF;

  -- Recipient: invoice contact, else the contract's buyer (same rule as fn_enqueue_invoice_notification)
  SELECT c.id, c.contract_number, c.buyer_id, c.buyer_name INTO v_contract
    FROM public.t_contracts c WHERE c.id = v_job.contract_id;
  IF v_job.invoice_id IS NOT NULL THEN
    SELECT i.id, i.invoice_number, i.contact_id, i.due_date INTO v_inv
      FROM public.t_invoices i WHERE i.id = v_job.invoice_id;
  END IF;
  v_contact := COALESCE(v_inv.contact_id, v_contract.buyer_id);
  IF v_contact IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_recipient');
  END IF;

  SELECT COALESCE(NULLIF(TRIM(ct.company_name), ''), NULLIF(TRIM(ct.name), ''), v_contract.buyer_name)
    INTO v_name FROM public.t_contacts ct WHERE ct.id = v_contact;

  IF p_channel = 'whatsapp' THEN
    v_address := public.gs_member_whatsapp_phone(v_contact);
  ELSE
    SELECT NULLIF(TRIM(cc.value), '') INTO v_address
      FROM public.t_contact_channels cc
     WHERE cc.contact_id = v_contact AND cc.channel_type = 'email'
       AND NULLIF(TRIM(cc.value), '') IS NOT NULL
     ORDER BY cc.is_primary DESC NULLS LAST, cc.is_verified DESC NULLS LAST, cc.created_at
     LIMIT 1;
  END IF;
  IF v_address IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_address', 'channel', p_channel, 'recipient_name', v_name);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.n_jtd_templates t
                  WHERE t.source_type_code = 'payment_nudge_' || p_channel AND t.channel_code = p_channel
                    AND t.is_active AND (t.tenant_id = p_tenant OR t.tenant_id IS NULL)) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_template', 'channel', p_channel);
  END IF;

  SELECT COALESCE(NULLIF(TRIM(tp.business_name), ''), NULLIF(TRIM(t.name), ''))
    INTO v_tenant
    FROM public.t_tenants t LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = t.id
   WHERE t.id = p_tenant;
  IF COALESCE(TRIM(v_name), '') = '' OR COALESCE(TRIM(v_tenant), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'incomplete');
  END IF;

  -- Which rung is this?
  SELECT r.step, r.after_days, r.channel INTO v_rung
    FROM public.jtd_ladder_rungs(p_tenant) r
   WHERE r.step = v_job.dunning_step + 1
     AND public.jtd_rung_due_at(v_job.scheduled_at, r.after_days) <= now();
  v_rung_no := COALESCE(v_rung.step, 0);

  -- Same job + channel within 2 minutes = a double click, not a second nudge
  PERFORM pg_advisory_xact_lock(hashtextextended(p_job_id::text || ':nudge:' || p_channel, 0));
  SELECT MAX(j.created_at) INTO v_recent FROM public.n_jtd j
   WHERE j.source_id = p_job_id AND j.source_type_code = 'payment_nudge_' || p_channel
     AND j.created_at > now() - interval '2 minutes';
  IF v_recent IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'already_sent_just_now', 'sent_at', v_recent);
  END IF;

  v_amount_disp := CASE WHEN COALESCE(v_job.currency,'INR') = 'INR' THEN 'Rs ' ELSE v_job.currency || ' ' END
                   || to_char(round(v_owed), 'FM99,99,99,999');
  v_due_disp    := to_char(v_job.scheduled_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY');
  v_pay         := public.fn_invoice_pay_line(p_payment_link, p_upi_id);

  -- Built to match each template's declared `variables` exactly (worker orders WhatsApp params from it)
  v_vars := CASE WHEN p_channel = 'whatsapp' THEN
      jsonb_build_object('customer_name', v_name, 'tenant_name', v_tenant,
                         'invoice_number', COALESCE(v_inv.invoice_number, v_contract.contract_number),
                         'amount', v_amount_disp, 'pay_line', v_pay->>'pay_line')
    ELSE
      jsonb_build_object('customer_name', v_name, 'invoice_number', COALESCE(v_inv.invoice_number, v_contract.contract_number),
                         'amount', v_amount_disp, 'due_date', v_due_disp, 'tenant_name', v_tenant,
                         'payment_link', COALESCE(p_payment_link, ''))
    END;

  BEGIN
    INSERT INTO public.n_jtd (
      tenant_id, event_type_code, channel_code, source_type_code, source_id, source_ref,
      recipient_type, recipient_id, recipient_name, recipient_contact,
      template_key, template_variables, payload, business_context, metadata,
      performed_by_type, performed_by_id, performed_by_name, is_live,
      contract_id, block_id, block_name, invoice_id, amount, currency, dunning_step, notes
    ) VALUES (
      p_tenant, 'reminder', p_channel, 'payment_nudge_' || p_channel, p_job_id, v_contract.contract_number,
      'contact', v_contact, v_name, v_address,
      'payment_nudge_' || p_channel, v_vars,
      jsonb_build_object('recipient_data', jsonb_strip_nulls(jsonb_build_object('name', v_name,
                           CASE WHEN p_channel = 'email' THEN 'email' ELSE 'phone' END, v_address)),
                         'template_data', v_vars),
      jsonb_build_object('job_id', p_job_id, 'contract_id', v_job.contract_id, 'invoice_id', v_job.invoice_id,
                         'rung', v_rung_no, 'rung_channel_expected', v_rung.channel, 'note', p_note, 'origin', 'collections_tool'),
      '{}'::jsonb,
      p_actor_type, p_actor_id, p_actor_name, COALESCE(v_job.is_live, true),
      v_job.contract_id, v_job.block_id, v_job.block_name, v_job.invoice_id, v_owed, v_job.currency, v_rung_no, p_note
    ) RETURNING id INTO v_reminder;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'reason', 'duplicate_rung', 'rung', v_rung_no);
  END;

  UPDATE public.n_jtd
     SET nudge_count   = nudge_count + 1,
         last_nudge_at = now(),
         dunning_step  = GREATEST(dunning_step, v_rung_no),
         dunning_paused_reason = CASE WHEN dunning_paused_reason = 'promise' THEN NULL ELSE dunning_paused_reason END,
         promise_date  = CASE WHEN dunning_paused_reason = 'promise' THEN NULL ELSE promise_date END,
         version       = COALESCE(version, 0) + 1,
         updated_at    = now()
   WHERE id = p_job_id;
  v_next := public.jtd_recompute_dunning(p_job_id);

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, 'nudged', p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('channel', p_channel, 'rung', v_rung_no, 'reminder_jtd_id', v_reminder, 'recipient', v_address),
          p_note, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'reminder_jtd_id', v_reminder, 'channel', p_channel,
                            'rung', v_rung_no, 'recipient_name', v_name, 'recipient_contact', v_address,
                            'amount', v_amount_disp, 'nudge_count', v_job.nudge_count + 1, 'next_dunning_at', v_next);
END;
$$;

-- Record a call a human made about a payment job. Closes any open call task
-- for the job. 'promised' pauses the ladder until the promise date;
-- 'disputed' pauses it until someone resumes.
CREATE OR REPLACE FUNCTION public.jtd_log_payment_call(
  p_tenant       uuid,
  p_job_id       uuid,
  p_actor_type   text,
  p_actor_id     uuid,
  p_actor_name   text,
  p_called_at    timestamptz,
  p_outcome      text,
  p_notes        text DEFAULT NULL,
  p_promise_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job     public.n_jtd%ROWTYPE;
  v_contract record;
  v_rung    record;
  v_rung_no integer := 0;
  v_row     uuid;
  v_closed  integer := 0;
  v_next    timestamptz;
BEGIN
  IF p_outcome NOT IN ('reached','no_answer','promised','disputed','other') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_outcome');
  END IF;
  IF p_outcome = 'promised' AND p_promise_date IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'promise_date_required');
  END IF;
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
  END IF;

  SELECT * INTO v_job FROM public.n_jtd
   WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment' FOR UPDATE;
  IF v_job.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'job_not_found');
  END IF;
  SELECT c.contract_number, c.buyer_id, c.buyer_name INTO v_contract FROM public.t_contracts c WHERE c.id = v_job.contract_id;

  -- A call satisfies a due call rung
  SELECT r.step INTO v_rung FROM public.jtd_ladder_rungs(p_tenant) r
   WHERE r.step = v_job.dunning_step + 1 AND r.channel = 'call'
     AND public.jtd_rung_due_at(v_job.scheduled_at, r.after_days) <= now();
  v_rung_no := COALESCE(v_rung.step, 0);

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

  -- Close open call tasks for this job
  UPDATE public.n_jtd
     SET status_code = 'completed', previous_status_code = status_code, status_changed_at = now(),
         completed_at = now(), transition_note = 'Closed by call log ' || v_row::text, updated_at = now()
   WHERE source_id = p_job_id AND source_type_code = 'payment_call_due'
     AND status_code IN ('assigned','in_progress','pending','created');
  GET DIAGNOSTICS v_closed = ROW_COUNT;

  UPDATE public.n_jtd
     SET nudge_count   = nudge_count + 1,
         last_nudge_at = COALESCE(p_called_at, now()),
         dunning_step  = GREATEST(dunning_step, v_rung_no),
         dunning_paused_reason = CASE p_outcome WHEN 'promised' THEN 'promise' WHEN 'disputed' THEN 'dispute' ELSE dunning_paused_reason END,
         promise_date  = CASE p_outcome WHEN 'promised' THEN p_promise_date ELSE promise_date END,
         notes         = COALESCE(p_notes, notes),
         version       = COALESCE(version, 0) + 1,
         updated_at    = now()
   WHERE id = p_job_id;
  v_next := public.jtd_recompute_dunning(p_job_id);

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, 'call_logged', p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('outcome', p_outcome, 'promise_date', p_promise_date, 'rung', v_rung_no,
                             'call_jtd_id', v_row, 'closed_call_tasks', v_closed),
          p_notes, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'call_jtd_id', v_row, 'outcome', p_outcome, 'rung', v_rung_no,
                            'closed_call_tasks', v_closed, 'paused_reason',
                            CASE p_outcome WHEN 'promised' THEN 'promise' WHEN 'disputed' THEN 'dispute' ELSE v_job.dunning_paused_reason END,
                            'next_dunning_at', v_next);
END;
$$;

-- The call rung: an OPEN task assigned to a named tenant user.
CREATE OR REPLACE FUNCTION public.jtd_escalate_payment_call(
  p_tenant     uuid,
  p_job_id     uuid,
  p_assign_to  uuid,
  p_actor_type text,
  p_actor_id   uuid,
  p_actor_name text,
  p_note       text DEFAULT NULL
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
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
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
      'assigned', now(), p_assign_to, v_assignee, p_note,
      jsonb_build_object('job_id', p_job_id, 'contract_id', v_job.contract_id, 'invoice_id', v_job.invoice_id,
                         'rung', v_rung_no, 'origin', 'collections_tool'),
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
  VALUES (p_job_id, 'escalated', p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('assigned_to', p_assign_to, 'assigned_to_name', v_assignee, 'rung', v_rung_no, 'task_jtd_id', v_row),
          p_note, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'task_jtd_id', v_row, 'assigned_to', p_assign_to,
                            'assigned_to_name', v_assignee, 'rung', v_rung_no, 'next_dunning_at', v_next);
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_pause_dunning(
  p_tenant     uuid,
  p_job_id     uuid,
  p_reason     text,
  p_actor_type text,
  p_actor_id   uuid,
  p_actor_name text,
  p_until      date DEFAULT NULL,
  p_note       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_job public.n_jtd%ROWTYPE;
BEGIN
  IF p_reason NOT IN ('promise','dispute','manual') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_reason');
  END IF;
  IF p_reason = 'promise' AND p_until IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'promise_date_required');
  END IF;
  SELECT * INTO v_job FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment' FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'job_not_found'); END IF;

  UPDATE public.n_jtd
     SET dunning_paused_reason = p_reason, promise_date = CASE WHEN p_reason = 'promise' THEN p_until ELSE NULL END,
         next_dunning_at = NULL, notes = COALESCE(p_note, notes), version = COALESCE(version,0) + 1, updated_at = now()
   WHERE id = p_job_id;

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, 'paused', p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('reason', p_reason, 'until', p_until), p_note, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'paused_reason', p_reason, 'until', p_until);
END;
$$;

CREATE OR REPLACE FUNCTION public.jtd_resume_dunning(
  p_tenant     uuid,
  p_job_id     uuid,
  p_actor_type text,
  p_actor_id   uuid,
  p_actor_name text,
  p_note       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_job public.n_jtd%ROWTYPE; v_next timestamptz;
BEGIN
  SELECT * INTO v_job FROM public.n_jtd WHERE id = p_job_id AND tenant_id = p_tenant AND event_type_code = 'payment' FOR UPDATE;
  IF v_job.id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'job_not_found'); END IF;

  UPDATE public.n_jtd
     SET dunning_paused_reason = NULL, promise_date = NULL, version = COALESCE(version,0) + 1, updated_at = now()
   WHERE id = p_job_id;
  v_next := public.jtd_recompute_dunning(p_job_id);

  INSERT INTO public.n_jtd_history (jtd_id, action, performed_by_type, performed_by_id, performed_by_name, details, note, is_live)
  VALUES (p_job_id, 'resumed', p_actor_type, p_actor_id, p_actor_name,
          jsonb_build_object('was', v_job.dunning_paused_reason, 'next_dunning_at', v_next), p_note, COALESCE(v_job.is_live, true));

  RETURN jsonb_build_object('success', true, 'next_dunning_at', v_next);
END;
$$;

-- ─── 7. The cockpit reader ────────────────────────────────────────────────
-- Never returns balances, totals or ageing. Flat rows with ids for drill-down.
-- "Today" is IST. Rung due-ness is computed live from the ladder (the
-- next_dunning_at column is a cache the tools maintain; the reader does not
-- depend on it, so jobs that were never nudged still surface correctly).
CREATE OR REPLACE FUNCTION public.jtd_collections_worklist(
  p_tenant       uuid,
  p_is_live      boolean DEFAULT true,
  p_horizon_days integer DEFAULT 30
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today   date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_horizon date;
  v_needs   jsonb;
  v_coming  jsonb;
  v_happened jsonb;
  v_team    jsonb;
  v_ladder  jsonb;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'tenant_required'); END IF;
  v_horizon := v_today + GREATEST(COALESCE(p_horizon_days, 30), 1);

  -- Needs you: decisions, most urgent first
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
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.channel_code, n.status_code, n.created_at, n.source_type_code
      FROM public.n_jtd n
     WHERE n.tenant_id = p_tenant AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_logged')
     ORDER BY n.source_id, n.created_at DESC
  ),
  open_call AS (
    SELECT DISTINCT ON (n.source_id) n.source_id AS job_id, n.id AS task_id, n.assigned_to, n.assigned_to_name, n.created_at
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
           ln.channel_code AS last_channel, ln.source_type_code AS last_kind, ln.status_code AS last_status, ln.created_at AS last_at,
           oc.task_id AS call_task_id, oc.assigned_to AS call_assigned_to, oc.assigned_to_name AS call_assigned_to_name,
           d.declaration_id, d.amount AS declared_amount, d.reference AS declared_reference, d.created_at AS declared_at, d.kind AS declaration_kind,
           CASE WHEN d.declaration_id IS NOT NULL THEN 'declaration_pending'
                WHEN jb.dunning_paused_reason = 'promise' AND jb.promise_date IS NOT NULL AND jb.promise_date < v_today THEN NULL
                ELSE jb.dunning_paused_reason END AS effective_pause
      FROM jobs jb
      LEFT JOIN rung r ON r.job_id = jb.id
      LEFT JOIN last_nudge ln ON ln.job_id = jb.id
      LEFT JOIN open_call oc ON oc.job_id = jb.id
      LEFT JOIN LATERAL (SELECT * FROM decl x WHERE x.job_id = jb.id ORDER BY x.created_at DESC LIMIT 1) d ON true
  ),
  card AS (
    SELECT e.*,
           CASE WHEN e.declaration_id IS NOT NULL THEN 'declaration_pending'
                WHEN e.call_task_id IS NOT NULL THEN 'call_open'
                WHEN e.effective_pause IS NOT NULL THEN 'paused'
                WHEN e.rung_step IS NOT NULL AND e.rung_due_at <= now() THEN 'rung_due'
                WHEN e.is_overdue AND e.rung_step IS NULL AND e.dunning_step > 0 THEN 'ladder_exhausted'
                WHEN e.is_overdue AND e.rung_step IS NULL THEN 'overdue_no_ladder'
                ELSE NULL END AS kind
      FROM enriched e
  ),
  awaiting AS (
    SELECT c.id AS contract_id, c.contract_number, c.buyer_id, c.buyer_name, c.status, c.grand_total, c.currency, c.created_at, c.start_date
      FROM public.t_contracts c
     WHERE c.tenant_id = p_tenant AND c.record_type = 'contract' AND COALESCE(c.is_live, true) = p_is_live
       AND c.acceptance_method = 'payment' AND c.status IN ('pending_acceptance','sent') AND COALESCE(c.is_active, true)
  ),
  failed AS (
    SELECT n.id AS reminder_id, n.source_id AS job_id, n.channel_code, n.error_message, n.created_at, n.recipient_name, n.recipient_contact, n.contract_id, n.source_ref
      FROM public.n_jtd n
     WHERE n.tenant_id = p_tenant AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp')
       AND n.status_code = 'failed' AND n.created_at > now() - interval '7 days' AND COALESCE(n.is_live, true) = p_is_live
  )
  SELECT jsonb_build_object(
    'cards', COALESCE((
      SELECT jsonb_agg(x ORDER BY x->>'sort_key')
      FROM (
        SELECT jsonb_build_object(
          'kind', k.kind, 'job_id', k.id, 'contract_id', k.contract_id, 'contract_number', k.contract_number,
          'buyer_id', k.buyer_id, 'buyer_name', k.buyer_name, 'invoice_id', k.invoice_id, 'invoice_number', k.invoice_number,
          'block_name', k.block_name, 'cycle_label', k.billing_cycle_label, 'sequence', k.sequence_number, 'of', k.total_occurrences,
          'amount', k.owed, 'currency', COALESCE(k.currency,'INR'), 'due_date', k.due_date, 'status', k.status_code,
          'days_overdue', k.days_overdue, 'dunning_step', k.dunning_step, 'nudge_count', k.nudge_count, 'last_nudge_at', k.last_nudge_at,
          'last_channel', k.last_channel, 'last_kind', k.last_kind, 'last_status', k.last_status,
          'rung', CASE WHEN k.rung_step IS NULL THEN NULL ELSE jsonb_build_object('step', k.rung_step, 'after_days', k.rung_after_days, 'channel', k.rung_channel, 'due_at', k.rung_due_at) END,
          'paused_reason', k.effective_pause, 'promise_date', k.promise_date,
          'declaration', CASE WHEN k.declaration_id IS NULL THEN NULL ELSE jsonb_build_object('id', k.declaration_id, 'kind', k.declaration_kind, 'amount', k.declared_amount, 'reference', k.declared_reference, 'at', k.declared_at) END,
          'call_task', CASE WHEN k.call_task_id IS NULL THEN NULL ELSE jsonb_build_object('id', k.call_task_id, 'assigned_to', k.call_assigned_to, 'assigned_to_name', k.call_assigned_to_name) END,
          'sort_key', CASE k.kind WHEN 'declaration_pending' THEN '0' WHEN 'rung_due' THEN '1' WHEN 'call_open' THEN '2' WHEN 'overdue_no_ladder' THEN '3' WHEN 'ladder_exhausted' THEN '4' ELSE '5' END
                      || lpad((99999 - k.days_overdue)::text, 5, '0') || k.contract_number
        ) x
        FROM card k WHERE k.kind IS NOT NULL
      ) s), '[]'::jsonb),
    'awaiting_payment_to_activate', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'contract_id', a.contract_id, 'contract_number', a.contract_number, 'buyer_id', a.buyer_id, 'buyer_name', a.buyer_name,
        'status', a.status, 'amount', a.grand_total, 'currency', COALESCE(a.currency,'INR'), 'since', a.created_at, 'start_date', a.start_date)
        ORDER BY a.created_at) FROM awaiting a), '[]'::jsonb),
    'send_failed', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'reminder_id', f.reminder_id, 'job_id', f.job_id, 'channel', f.channel_code, 'error', f.error_message, 'at', f.created_at,
        'recipient_name', f.recipient_name, 'recipient_contact', f.recipient_contact, 'contract_id', f.contract_id, 'contract_number', f.source_ref)
        ORDER BY f.created_at DESC) FROM failed f), '[]'::jsonb),
    'counts', jsonb_build_object(
        'rung_due',            (SELECT count(*) FROM card WHERE kind = 'rung_due'),
        'declaration_pending', (SELECT count(*) FROM card WHERE kind = 'declaration_pending'),
        'call_open',           (SELECT count(*) FROM card WHERE kind = 'call_open'),
        'paused',              (SELECT count(*) FROM card WHERE kind = 'paused'),
        'overdue_no_ladder',   (SELECT count(*) FROM card WHERE kind = 'overdue_no_ladder'),
        'ladder_exhausted',    (SELECT count(*) FROM card WHERE kind = 'ladder_exhausted'),
        'awaiting_payment',    (SELECT count(*) FROM awaiting),
        'send_failed',         (SELECT count(*) FROM failed))
  ) INTO v_needs;

  -- Coming up: what falls due within the horizon (jobs and rungs). No totals.
  WITH jobs AS (
    SELECT j.id, j.contract_id, j.invoice_id, j.scheduled_at, j.status_code, j.amount, j.amount_settled, j.currency,
           j.dunning_step, j.block_name, j.billing_cycle_label, j.sequence_number, j.total_occurrences,
           (j.scheduled_at AT TIME ZONE 'Asia/Kolkata')::date AS due_date,
           c.contract_number, c.buyer_id, c.buyer_name, i.invoice_number,
           GREATEST(COALESCE(j.amount,0) - COALESCE(j.amount_settled,0), 0) AS owed
      FROM public.n_jtd j JOIN public.t_contracts c ON c.id = j.contract_id LEFT JOIN public.t_invoices i ON i.id = j.invoice_id
     WHERE j.tenant_id = p_tenant AND j.event_type_code = 'payment' AND COALESCE(j.is_live, true) = p_is_live
       AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true)
  )
  SELECT jsonb_build_object(
    'due', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'job_id', jb.id, 'contract_id', jb.contract_id, 'contract_number', jb.contract_number, 'buyer_id', jb.buyer_id, 'buyer_name', jb.buyer_name,
        'invoice_id', jb.invoice_id, 'invoice_number', jb.invoice_number, 'block_name', jb.block_name, 'cycle_label', jb.billing_cycle_label,
        'sequence', jb.sequence_number, 'of', jb.total_occurrences, 'amount', jb.owed, 'currency', COALESCE(jb.currency,'INR'),
        'due_date', jb.due_date, 'days_until', jb.due_date - v_today, 'status', jb.status_code)
        ORDER BY jb.due_date, jb.contract_number)
      FROM jobs jb WHERE jb.due_date >= v_today AND jb.due_date <= v_horizon), '[]'::jsonb),
    'rungs', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'job_id', jb.id, 'contract_id', jb.contract_id, 'contract_number', jb.contract_number, 'buyer_id', jb.buyer_id, 'buyer_name', jb.buyer_name,
        'amount', jb.owed, 'currency', COALESCE(jb.currency,'INR'), 'due_date', jb.due_date,
        'rung', jsonb_build_object('step', r.step, 'after_days', r.after_days, 'channel', r.channel, 'due_at', public.jtd_rung_due_at(jb.scheduled_at, r.after_days)))
        ORDER BY public.jtd_rung_due_at(jb.scheduled_at, r.after_days), jb.contract_number)
      FROM jobs jb
      JOIN LATERAL (SELECT * FROM public.jtd_ladder_rungs(p_tenant) x WHERE x.step = jb.dunning_step + 1) r ON true
      WHERE public.jtd_rung_due_at(jb.scheduled_at, r.after_days) > now()
        AND (public.jtd_rung_due_at(jb.scheduled_at, r.after_days) AT TIME ZONE 'Asia/Kolkata')::date <= v_horizon), '[]'::jsonb)
  ) INTO v_coming;

  -- What happened: the tool feed, newest first
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.source_type_code, 'job_id', n.source_id, 'contract_id', n.contract_id, 'contract_number', n.source_ref,
      'buyer_name', n.recipient_name, 'channel', n.channel_code, 'status', n.status_code, 'amount', n.amount, 'currency', COALESCE(n.currency,'INR'),
      'rung', n.dunning_step, 'outcome', n.metadata->>'outcome', 'notes', n.notes,
      'assigned_to', n.assigned_to, 'assigned_to_name', n.assigned_to_name,
      'actor_type', n.performed_by_type, 'actor_name', n.performed_by_name, 'at', n.created_at, 'error', n.error_message)
      ORDER BY n.created_at DESC), '[]'::jsonb)
    INTO v_happened
    FROM (SELECT * FROM public.n_jtd n
           WHERE n.tenant_id = p_tenant AND COALESCE(n.is_live, true) = p_is_live
             AND n.source_type_code IN ('payment_nudge_email','payment_nudge_whatsapp','payment_call_due','payment_call_logged')
           ORDER BY n.created_at DESC LIMIT 40) n;

  -- Team (for Assign call); ladder (for display)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', ut.user_id,
      'name', COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email)) ORDER BY up.first_name), '[]'::jsonb)
    INTO v_team
    FROM public.t_user_tenants ut LEFT JOIN public.t_user_profiles up ON up.user_id = ut.user_id
   WHERE ut.tenant_id = p_tenant AND COALESCE(ut.status, 'active') IN ('active','accepted');

  SELECT jsonb_build_object(
      'rule_enabled', public.vani_rule_enabled(p_tenant, 'payment_reminder'),
      'rungs', COALESCE((SELECT jsonb_agg(jsonb_build_object('step', r.step, 'after_days', r.after_days, 'channel', r.channel) ORDER BY r.step)
                          FROM public.jtd_ladder_rungs(p_tenant) r), '[]'::jsonb))
    INTO v_ladder;

  RETURN jsonb_build_object(
    'success', true, 'today', v_today, 'horizon_until', v_horizon, 'is_live', p_is_live,
    'needs_you', v_needs, 'coming_up', v_coming, 'happened', v_happened, 'team', v_team, 'ladder', v_ladder,
    'generated_at', now());
END;
$$;
