-- ============================================================================
-- jtd-nucleus/012 — ONE activity timeline per contract (step 6 of the cockpit
-- review, owner decision 2026-09-17). Spec: OPS-JTD-TOOLS-SPEC.md §5.
--
-- The contract page's Audit tab read only t_audit_log (service execution) and
-- so showed none of the collections activity; the cockpit had no per-card
-- history. This reader unions, for one contract:
--   service      t_audit_log rows for the contract (what the Audit tab had)
--   billing      t_contract_event_audit rows of the contract's billing events
--   collections  every n_jtd communication/task ABOUT the contract — rows with
--                contract_id = X OR source_id = one of the contract's payment
--                jobs (the scanner's automated payment_due reminders hang off
--                the job id, not the contract) — excluding the job rows
--                themselves; n_jtd_history paused/resumed on those jobs;
--                declarations (declared, then confirmed/rejected) — session
--                declarations via billing_event_id → job, public ones via
--                contract_id.
-- One row shape, newest first, paged; per-source counts on the whole set.
-- Never returns balances or totals. Facts: n_jtd payment job id = the
-- t_contract_events id (477 = 477 on BBB), so event_id and job id coincide.
-- ============================================================================

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
           al.category::text AS category
      FROM public.t_audit_log al
     WHERE al.tenant_id = p_tenant AND al.contract_id = p_contract_id
  ),
  bill AS (
    SELECT a.id::text, 'billing', ('event:' || a.field_changed)::text, a.changed_at,
           CASE WHEN a.changed_by IS NULL THEN 'system' ELSE 'user' END::text, COALESCE(a.changed_by_name, 'System')::text,
           ('Billing event ' || COALESCE(e.billing_cycle_label, 'instalment ' || e.sequence_number::text, '') || ' · ' || replace(a.field_changed, '_', ' ') || ' changed')::text,
           a.reason::text, a.old_value::text, a.new_value::text,
           NULL::text, NULL::text, e.amount, COALESCE(e.currency, 'INR')::text,
           e.id, e.id, a.id, 'billing_events'::text
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
           CASE WHEN n.source_id IN (SELECT id FROM jobs) THEN n.source_id ELSE NULL END, NULL::uuid, n.id, 'collections'::text
      FROM public.n_jtd n
     WHERE n.tenant_id = p_tenant AND COALESCE(n.is_live, true) = p_is_live
       AND n.event_type_code NOT IN ('payment', 'service_visit')
       -- Three ways a row points at the contract: the column; the payment job
       -- (ladder tools); or business_context.contract_id — the scanner's
       -- payment_due / payment_received rows carry only that (their source_id
       -- is an invoice id, and BBB's were re-issued on 6 Aug so it dangles).
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
           jb.id, jb.id, h.id, 'collections'::text
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
           d.job_id, d.job_id, d.id, 'collections'::text
      FROM decl_all d
    UNION ALL
    SELECT (d.id::text || ':' || d.status), 'collections', ('declaration_' || d.status)::text, d.confirmed_at,
           'user'::text, COALESCE(NULLIF(TRIM(CONCAT_WS(' ', up.first_name, up.last_name)), ''), up.email, 'Someone')::text,
           (CASE d.status WHEN 'confirmed' THEN 'Declared payment confirmed' ELSE 'Declared payment rejected' END || ' · Rs ' || to_char(round(d.amount), 'FM99,99,99,999') || ' from ' || d.who)::text,
           NULL::text, NULL::text, NULL::text, 'upi'::text, d.status::text, d.amount, d.currency::text,
           d.job_id, d.job_id, d.id, 'collections'::text
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
              'amount', x.amount, 'currency', x.currency, 'job_id', x.job_id, 'event_id', x.event_id, 'ref_id', x.ref_id, 'category', x.category))
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

COMMENT ON FUNCTION public.jtd_contract_activity(uuid, uuid, boolean, text[], integer, integer) IS
  'One activity timeline for a contract: service-execution audit + billing-event audit + every JTD communication/task/declaration about it. Paged, newest first, per-source counts. Never returns totals. Spec: OPS-JTD-TOOLS-SPEC §5.';
