-- ============================================================================
-- jtd-nucleus/013 — show the message that went (owner request 2026-09-17:
-- "create a helper and show messages in the audit").
--
-- Facts: every reminder row keeps the exact variables that went out
-- (n_jtd.template_variables); n_jtd_templates keeps a text copy of each
-- message with {{placeholders}} (content, subject) next to the provider
-- template id. The PROVIDER renders the final bytes (MSG91 email / WhatsApp
-- template), so what we can show is our copy with the stored variables
-- substituted — faithful as long as the template copy matches what is
-- registered at the provider. The renderer labels it source='template_copy'.
--
-- 1. jtd_render_message(tenant, source_type, channel, vars) → {subject, body,
--    template_key, provider_template_id, source} or NULL when no template.
--    Resolution mirrors the worker: source_type + channel, tenant row first,
--    then the global row.
-- 2. jtd_nudge_payment returns 'message' (rendered) — spliced into its RETURN
--    by prosrc substitution (the 048 technique) with a post-check that the
--    splice landed exactly once.
-- 3. jtd_contract_activity: every communication row carries 'message'.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.jtd_render_message(
  p_tenant      uuid,
  p_source_type text,
  p_channel     text,
  p_vars        jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_t      record;
  v_body   text;
  v_subj   text;
  v_k      text;
  v_v      text;
BEGIN
  IF p_source_type IS NULL OR p_channel IS NULL THEN RETURN NULL; END IF;
  SELECT t.template_key, t.subject, t.content, t.provider_template_id INTO v_t
    FROM public.n_jtd_templates t
   WHERE t.source_type_code = p_source_type AND t.channel_code = p_channel AND COALESCE(t.is_active, true)
     AND (t.tenant_id = p_tenant OR t.tenant_id IS NULL)
   ORDER BY (t.tenant_id IS NULL), t.version DESC NULLS LAST
   LIMIT 1;
  IF v_t.template_key IS NULL OR v_t.content IS NULL THEN RETURN NULL; END IF;

  v_body := v_t.content;
  v_subj := v_t.subject;
  IF jsonb_typeof(p_vars) = 'object' THEN
    FOR v_k, v_v IN SELECT e.key, e.value FROM jsonb_each_text(p_vars) e LOOP
      v_body := regexp_replace(v_body, '\{\{\s*' || regexp_replace(v_k, '([\\.^$|?*+()\[\]{}])', '\\\1', 'g') || '\s*\}\}', COALESCE(v_v, ''), 'g');
      IF v_subj IS NOT NULL THEN
        v_subj := regexp_replace(v_subj, '\{\{\s*' || regexp_replace(v_k, '([\\.^$|?*+()\[\]{}])', '\\\1', 'g') || '\s*\}\}', COALESCE(v_v, ''), 'g');
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'subject', v_subj, 'body', v_body,
    'template_key', v_t.template_key, 'provider_template_id', v_t.provider_template_id,
    'source', 'template_copy'));
END;
$$;

COMMENT ON FUNCTION public.jtd_render_message(uuid, text, text, jsonb) IS
  'Renders our template copy (n_jtd_templates.subject/content, tenant then global, by source_type + channel) with a row''s stored variables. The provider formats the final message; this is the faithful preview.';

-- ── 2. nudge tool returns the rendered message ──────────────────────────────
DO $$
DECLARE
  v_src  text;
  v_old  text := 'RETURN jsonb_build_object(''success'', true, ''reminder_jtd_id'', v_reminder, ''channel'', p_channel,';
  v_new  text := 'RETURN jsonb_build_object(''success'', true, ''reminder_jtd_id'', v_reminder, ''channel'', p_channel, ''message'', public.jtd_render_message(p_tenant, ''payment_nudge_'' || p_channel, p_channel, v_vars),';
  v_n    integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'jtd_nudge_payment';
  IF v_src IS NULL THEN RAISE EXCEPTION '013: jtd_nudge_payment not found'; END IF;
  IF position('''message'', public.jtd_render_message' IN v_src) > 0 THEN
    RAISE NOTICE '013: jtd_nudge_payment already returns message — skipping splice';
    RETURN;
  END IF;
  v_n := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION '013: expected exactly one RETURN anchor in jtd_nudge_payment, found %', v_n; END IF;
  v_src := replace(v_src, v_old, v_new);
  EXECUTE v_src;
  -- post-check: the rewrite landed
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'jtd_nudge_payment';
  IF position('''message'', public.jtd_render_message' IN v_src) = 0 THEN
    RAISE EXCEPTION '013: splice did not land in jtd_nudge_payment';
  END IF;
END $$;

-- ── 3. activity reader: every communication row carries 'message' ──────────
-- Full body re-issued (012b + one column). Kept in one place: this file is
-- now the source of record for jtd_contract_activity.
CREATE OR REPLACE FUNCTION public.jtd_contract_activity(
  p_tenant      uuid,
  p_contract_id uuid,
  p_is_live     boolean DEFAULT true,
  p_sources     text[]  DEFAULT NULL,
  p_limit       integer DEFAULT 50,
  p_offset      integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_limit    integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500);
  v_offset   integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_contract record;
  v_out      jsonb;
BEGIN
  IF p_tenant IS NULL OR p_contract_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'contract_required');
  END IF;
  SELECT c.id, c.contract_number, c.buyer_id, c.buyer_name INTO v_contract
    FROM public.t_contracts c WHERE c.id = p_contract_id AND c.tenant_id = p_tenant;
  IF v_contract.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'contract_not_found');
  END IF;

  WITH jobs AS (
    SELECT j.id, j.recipient_name, j.amount, j.currency
      FROM public.n_jtd j
     WHERE j.tenant_id = p_tenant AND j.contract_id = p_contract_id AND j.event_type_code = 'payment'
       AND COALESCE(j.is_live, true) = p_is_live
  ),
  svc AS (
    SELECT al.id::text AS id, 'service'::text AS source, (COALESCE(al.category,'content') || ':' || al.action)::text AS kind, al.created_at AS at,
           'user'::text AS actor_type, COALESCE(al.performed_by_name, 'System')::text AS actor_name,
           COALESCE(NULLIF(al.description,''), initcap(replace(al.action,'_',' ')))::text AS title,
           NULL::text AS detail,
           COALESCE(CASE WHEN jsonb_typeof(al.old_value) = 'string' THEN al.old_value #>> '{}' END, al.old_value->>'status', al.old_value->>'assigned_to_name')::text AS from_v,
           COALESCE(CASE WHEN jsonb_typeof(al.new_value) = 'string' THEN al.new_value #>> '{}' END, al.new_value->>'status', al.new_value->>'assigned_to_name')::text AS to_v,
           NULL::text AS channel, NULL::text AS status, NULL::numeric AS amount, NULL::text AS currency,
           NULL::uuid AS job_id, CASE WHEN al.entity_type IN ('contract_event','event') THEN al.entity_id END AS event_id, al.id AS ref_id,
           al.category::text AS category, NULL::jsonb AS message
      FROM public.t_audit_log al
     WHERE al.tenant_id = p_tenant AND al.contract_id = p_contract_id
  ),
  bill AS (
    SELECT a.id::text, 'billing', ('event:' || a.field_changed)::text, a.changed_at,
           CASE WHEN a.changed_by IS NULL THEN 'system' ELSE 'user' END::text, COALESCE(a.changed_by_name, 'System')::text,
           ('Billing event ' || COALESCE(e.billing_cycle_label, 'instalment ' || e.sequence_number::text, '') || ' · ' || replace(a.field_changed, '_', ' ') || ' changed')::text,
           a.reason::text, a.old_value::text, a.new_value::text,
           NULL::text, NULL::text, e.amount, COALESCE(e.currency, 'INR')::text,
           e.id, e.id, a.id, 'billing_events'::text, NULL::jsonb
      FROM public.t_contract_event_audit a
      JOIN public.t_contract_events e ON e.id = a.event_id
     WHERE e.contract_id = p_contract_id AND e.tenant_id = p_tenant AND COALESCE(e.is_live, true) = p_is_live
  ),
  comms AS (
    SELECT n.id::text, 'collections', n.source_type_code::text, n.created_at,
           COALESCE(n.performed_by_type, 'system')::text,
           COALESCE(n.performed_by_name, CASE WHEN n.performed_by_type = 'vani' THEN 'VaNi' ELSE 'System' END)::text,
           CASE n.source_type_code
             WHEN 'payment_nudge_email'    THEN 'Reminder by email to ' || COALESCE(n.recipient_name, n.recipient_contact, 'the customer') || CASE WHEN COALESCE(n.dunning_step,0) > 0 THEN ' · rung ' || n.dunning_step ELSE ' · heads-up' END
             WHEN 'payment_nudge_whatsapp' THEN 'Reminder on WhatsApp to ' || COALESCE(n.recipient_name, n.recipient_contact, 'the customer') || CASE WHEN COALESCE(n.dunning_step,0) > 0 THEN ' · rung ' || n.dunning_step ELSE ' · heads-up' END
             WHEN 'payment_call_due'       THEN CASE WHEN n.business_context->>'task_kind' = 'follow_up' THEN 'Follow-up set' ELSE 'Call assigned to ' || COALESCE(n.assigned_to_name, 'a teammate') END
                                                || CASE WHEN n.scheduled_at IS NOT NULL THEN ' · due ' || to_char(n.scheduled_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY') ELSE '' END
             WHEN 'payment_call_logged'    THEN 'Called ' || COALESCE(n.recipient_name, 'the customer') || ' — ' || COALESCE(replace(n.metadata->>'outcome', '_', ' '), 'logged')
             WHEN 'payment_due'            THEN 'Automated payment reminder' || CASE WHEN n.channel_code IS NOT NULL THEN ' by ' || n.channel_code ELSE '' END || CASE WHEN n.recipient_name IS NOT NULL THEN ' to ' || n.recipient_name ELSE '' END
             WHEN 'payment_received'       THEN 'Payment received notice' || CASE WHEN n.channel_code IS NOT NULL THEN ' by ' || n.channel_code ELSE '' END || CASE WHEN n.recipient_name IS NOT NULL THEN ' to ' || n.recipient_name ELSE '' END
             ELSE initcap(replace(n.source_type_code, '_', ' ')) || CASE WHEN n.channel_code IS NOT NULL THEN ' by ' || n.channel_code ELSE '' END || CASE WHEN n.recipient_name IS NOT NULL THEN ' to ' || n.recipient_name ELSE '' END
           END::text,
           COALESCE(n.notes, n.error_message)::text, NULL::text, NULL::text,
           n.channel_code::text, n.status_code::text, n.amount, COALESCE(n.currency, 'INR')::text,
           CASE WHEN n.source_id IN (SELECT id FROM jobs) THEN n.source_id ELSE NULL END, NULL::uuid, n.id, 'collections'::text,
           CASE WHEN n.channel_code IN ('email','whatsapp','sms') AND jsonb_typeof(n.template_variables) = 'object'
                THEN public.jtd_render_message(n.tenant_id, n.source_type_code, n.channel_code, n.template_variables) END
      FROM public.n_jtd n
     WHERE n.tenant_id = p_tenant AND COALESCE(n.is_live, true) = p_is_live
       AND n.event_type_code NOT IN ('payment', 'service_visit')
       AND (n.contract_id = p_contract_id OR n.source_id IN (SELECT id FROM jobs)
            OR n.business_context->>'contract_id' = p_contract_id::text)
  ),
  hist AS (
    SELECT h.id::text, 'collections', ('ladder_' || h.action)::text, h.created_at,
           COALESCE(h.performed_by_type, 'user')::text, COALESCE(h.performed_by_name, 'Someone')::text,
           (CASE h.action
              WHEN 'paused'  THEN 'Reminders paused' || COALESCE(' · ' || (h.details->>'reason'), '') || COALESCE(' until ' || to_char((h.details->>'until')::date, 'DD Mon YYYY'), '')
              WHEN 'resumed' THEN 'Reminders resumed'
              ELSE initcap(replace(h.action, '_', ' ')) END)::text,
           h.note::text, NULL::text, NULL::text, NULL::text, NULL::text, jb.amount, COALESCE(jb.currency, 'INR')::text,
           jb.id, jb.id, h.id, 'collections'::text, NULL::jsonb
      FROM public.n_jtd_history h JOIN jobs jb ON jb.id = h.jtd_id
     WHERE h.action IN ('paused', 'resumed')
  ),
  sdecl AS (
    SELECT d.id, d.billing_event_id AS job_id, d.amount, COALESCE(d.currency, 'INR') AS currency, d.upi_reference AS reference, d.status, d.created_at, d.confirmed_at, d.confirmed_by, d.description,
           COALESCE(ct.name, jb.recipient_name, v_contract.buyer_name) AS who
      FROM public.t_session_payment_declarations d
      JOIN jobs jb ON jb.id = d.billing_event_id
      LEFT JOIN public.t_contacts ct ON ct.id = d.member_contact_id
     WHERE d.tenant_id = p_tenant
  ),
  pdecl AS (
    SELECT d.id, NULL::uuid AS job_id, d.amount, COALESCE(d.currency, 'INR')::text AS currency, d.reference, d.status, d.created_at, d.confirmed_at, d.confirmed_by, NULL::text AS description,
           COALESCE(d.declarer_name, v_contract.buyer_name) AS who
      FROM public.t_public_payment_declarations d
     WHERE d.tenant_id = p_tenant AND d.contract_id = p_contract_id AND COALESCE(d.is_live, true) = p_is_live
  ),
  decl_all AS (SELECT * FROM sdecl UNION ALL SELECT * FROM pdecl),
  decl AS (
    SELECT (d.id::text || ':declared'), 'collections', 'declaration'::text, d.created_at,
           'customer'::text, d.who::text,
           (d.who || ' declared a payment of Rs ' || to_char(round(d.amount), 'FM99,99,99,999') || COALESCE(' · ref ' || NULLIF(d.reference, ''), ' · no reference'))::text,
           d.description::text, NULL::text, NULL::text, 'upi'::text, d.status::text, d.amount, d.currency::text,
           d.job_id, d.job_id, d.id, 'collections'::text, NULL::jsonb
      FROM decl_all d
    UNION ALL
    SELECT (d.id::text || ':' || d.status), 'collections', ('declaration_' || d.status)::text, d.confirmed_at,
           'user'::text, COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email, 'Someone')::text,
           (CASE d.status WHEN 'confirmed' THEN 'Declared payment confirmed' ELSE 'Declared payment rejected' END || ' · Rs ' || to_char(round(d.amount), 'FM99,99,99,999') || ' from ' || d.who)::text,
           NULL::text, NULL::text, NULL::text, 'upi'::text, d.status::text, d.amount, d.currency::text,
           d.job_id, d.job_id, d.id, 'collections'::text, NULL::jsonb
      FROM decl_all d LEFT JOIN public.t_user_profiles up ON up.user_id = d.confirmed_by
     WHERE d.confirmed_at IS NOT NULL AND d.status IN ('confirmed', 'rejected')
  ),
  allr AS (
    SELECT * FROM svc UNION ALL SELECT * FROM bill UNION ALL SELECT * FROM comms UNION ALL SELECT * FROM hist UNION ALL SELECT * FROM decl
  ),
  flt AS (
    SELECT * FROM allr r WHERE r.at IS NOT NULL AND (p_sources IS NULL OR r.source = ANY (p_sources))
  ),
  page AS (
    SELECT * FROM flt ORDER BY at DESC, id LIMIT v_limit OFFSET v_offset
  )
  SELECT jsonb_build_object(
    'rows', COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', x.id, 'source', x.source, 'kind', x.kind, 'at', x.at, 'actor_type', x.actor_type, 'actor_name', x.actor_name,
              'title', x.title, 'detail', x.detail, 'from', x.from_v, 'to', x.to_v, 'channel', x.channel, 'status', x.status,
              'amount', x.amount, 'currency', x.currency, 'job_id', x.job_id, 'event_id', x.event_id, 'ref_id', x.ref_id, 'category', x.category,
              'message', x.message))
              ORDER BY x.at DESC, x.id) FROM page x), '[]'::jsonb),
    'total', (SELECT count(*) FROM flt),
    'counts', (SELECT jsonb_build_object(
                 'service',     count(*) FILTER (WHERE r.source = 'service'),
                 'billing',     count(*) FILTER (WHERE r.source = 'billing'),
                 'collections', count(*) FILTER (WHERE r.source = 'collections'),
                 'all',         count(*)) FROM allr r WHERE r.at IS NOT NULL)
  ) INTO v_out;

  RETURN jsonb_build_object(
    'success', true, 'contract_id', v_contract.id, 'contract_number', v_contract.contract_number,
    'buyer_id', v_contract.buyer_id, 'buyer_name', v_contract.buyer_name,
    'limit', v_limit, 'offset', v_offset, 'sources', to_jsonb(p_sources),
    'rows', v_out->'rows', 'total', v_out->'total', 'counts', v_out->'counts',
    'generated_at', now());
END;
$$;
