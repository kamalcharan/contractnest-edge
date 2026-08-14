-- ============================================================================
-- 070 — Send an invoice through JTD (manual send only)
-- ----------------------------------------------------------------------------
-- Part 3 of 3 of the invoice consolidation. Owner decisions (2026-08-14):
--   · MANUAL SEND ONLY. Nothing fires automatically — no trigger on
--     t_invoices, no scanner change, no schedule. The only caller is the
--     "Send Invoice" button, one invoice at a time. Automatic triggers can be
--     added later, once a real send is proven end to end.
--   · EMAIL FIRST. WhatsApp is built but must not be switched on until one
--     test send confirms the provider template is approved AND whether it was
--     registered named or positional (see the note at the bottom).
--   · REUSE EXISTING. No new template, no new source type, no new table.
--
-- WHAT IS REUSED, and why nothing new was created:
--   · THE AUTOMATION RULE 'notif_payment_request' (Settings → Configure →
--     VaNi → Automation Rules, "Standalone payment request sent to a
--     customer"). This is the tenant's own on/off switch and it GOVERNS this
--     function: when the rule is off, nothing is enqueued. Checked through the
--     existing vani_rule_enabled() helper — the same gate
--     run_contract_event_scanner uses for 'appointment_request', so invoices
--     obey the same standing instructions as everything else rather than
--     acquiring a private switch of their own.
--     ⚠ On BBB this rule is currently OFF, so Send Invoice will correctly
--     refuse until someone turns it on. That refusal is explicit and names
--     the rule — it is never a silent no-op.
--   · source_type_code 'payment_request' — already registered in
--     n_jtd_source_types.
--   · templates 'payment_request_email' / 'payment_request_whatsapp' — already
--     in n_jtd_templates at PLATFORM level (tenant_id IS NULL, so every tenant
--     gets them). Their declared variables are exactly an invoice's:
--     customer_name, tenant_name, invoice_number, amount, currency,
--     payment_link, expire_hours.
--   · gs_member_whatsapp_phone(contact) — the phone resolver written for the
--     group-session notifications. Reused rather than re-derived, because the
--     naive country_code||value concatenation it replaced was a real defect.
--   · trg_jtd_enqueue — the existing BEFORE INSERT trigger still does the
--     pgmq hand-off. This function only inserts the n_jtd row.
--
-- ⚠ ON DEDUPE — the trap from 2026-08-05, avoided differently here.
--   ON CONFLICT DO NOTHING is NOT safe with trg_jtd_enqueue: the trigger is
--   BEFORE INSERT and calls pgmq.send(), so on a conflicting row it has
--   already enqueued before the conflict is detected — the row is discarded,
--   the transaction commits, and a queue message is left pointing at an n_jtd
--   row that never existed.
--   The group-session fix was a NOT EXISTS guard plus a partial unique index.
--   A unique index is WRONG here: this is a manual action and a human must be
--   able to legitimately re-send an invoice tomorrow. So instead:
--     · an advisory lock serialises concurrent sends of the same
--       (invoice, channel) — the double-tap race, closed properly;
--     · a NOT EXISTS over a short window rejects the accidental repeat while
--       leaving a deliberate later re-send possible.
--   Nothing is ever silently discarded: a suppressed send RETURNS a reason,
--   which the button surfaces. The member-facing lesson from the duplicate
--   declarations applies here too — a silent no-op reads as success.
--
-- p_dry_run resolves everything and reports what WOULD be sent without
-- inserting. Use it to verify recipient resolution before any real traffic.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_enqueue_invoice_notification(
  p_tenant  uuid,
  p_invoice uuid,
  p_channel text    DEFAULT 'email',
  p_user    uuid    DEFAULT NULL,
  p_dry_run boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv         record;
  v_contact     uuid;
  v_name        text;
  v_address     text;
  v_tenant_name text;
  v_amount      numeric;
  v_currency    text;
  v_template    text;
  v_recent      timestamptz;
  v_jtd         uuid;
  v_rule_on     boolean;
BEGIN
  IF p_channel NOT IN ('email', 'whatsapp') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unsupported_channel',
      'message', 'Only email and whatsapp can carry an invoice today.');
  END IF;

  -- The tenant's standing instruction decides whether this may go out at all.
  -- A dry run still resolves and reports, so recipient wiring can be verified
  -- while the rule is off — but a real send is refused.
  v_rule_on := public.vani_rule_enabled(p_tenant, 'notif_payment_request');

  IF NOT v_rule_on AND NOT p_dry_run THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rule_disabled',
      'rule_key', 'notif_payment_request',
      'message', 'Payment request notifications are switched off for this business. Turn on "Standalone payment request" in Settings → Configure → Automation Rules.');
  END IF;

  -- ── the invoice ──────────────────────────────────────────────────────────
  SELECT i.id, i.invoice_number, i.contract_id, i.contact_id,
         i.total_amount, i.balance, i.currency, i.due_date,
         COALESCE(i.is_live, true) AS is_live, i.status
    INTO v_inv
    FROM public.t_invoices i
   WHERE i.id = p_invoice
     AND i.tenant_id = p_tenant
     AND COALESCE(i.is_active, true) = true;

  IF v_inv.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invoice_not_found');
  END IF;

  IF v_inv.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invoice_cancelled',
      'message', 'This invoice is cancelled — it cannot be sent.');
  END IF;

  -- ── who it goes to. An ad-hoc invoice carries contact_id directly; a
  --    contract invoice inherits the contract's buyer. Same path from here. ──
  SELECT COALESCE(v_inv.contact_id, c.buyer_id)
    INTO v_contact
    FROM (SELECT 1) _
    LEFT JOIN public.t_contracts c ON c.id = v_inv.contract_id;

  IF v_contact IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_recipient',
      'message', 'This invoice has no contact on file to send it to.');
  END IF;

  SELECT COALESCE(NULLIF(TRIM(ct.company_name), ''), NULLIF(TRIM(ct.name), ''))
    INTO v_name
    FROM public.t_contacts ct
   WHERE ct.id = v_contact;

  -- ── the address for THIS channel ─────────────────────────────────────────
  IF p_channel = 'whatsapp' THEN
    v_address := public.gs_member_whatsapp_phone(v_contact);
  ELSE
    SELECT NULLIF(TRIM(cc.value), '')
      INTO v_address
      FROM public.t_contact_channels cc
     WHERE cc.contact_id = v_contact
       AND cc.channel_type = 'email'
       AND NULLIF(TRIM(cc.value), '') IS NOT NULL
     ORDER BY cc.is_primary DESC NULLS LAST, cc.is_verified DESC NULLS LAST,
              cc.created_at ASC
     LIMIT 1;
  END IF;

  IF v_address IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_address',
      'channel', p_channel,
      'message', format('%s has no %s on file.',
                        COALESCE(v_name, 'This contact'),
                        CASE WHEN p_channel = 'whatsapp' THEN 'WhatsApp number'
                             ELSE 'email address' END));
  END IF;

  -- ── the numbers. What is still OWED is what we ask for; a settled invoice
  --    has nothing to request, so it is refused rather than sent asking for
  --    zero (the gs_confirm_declaration lesson: never enqueue a 0 amount). ──
  v_amount   := GREATEST(COALESCE(v_inv.balance, v_inv.total_amount, 0), 0);
  v_currency := COALESCE(v_inv.currency, 'INR');

  IF v_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'nothing_owed',
      'message', format('%s is fully settled — there is nothing to request.',
                        v_inv.invoice_number));
  END IF;

  -- Business Profile name, never t_tenants.name — the latter is a separate,
  -- shorter value ("BBB") and would silently produce the wrong text.
  SELECT COALESCE(NULLIF(TRIM(tp.business_name), ''), NULLIF(TRIM(t.name), ''))
    INTO v_tenant_name
    FROM public.t_tenants t
    LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = t.id
   WHERE t.id = p_tenant;

  IF COALESCE(TRIM(v_name), '') = '' OR COALESCE(TRIM(v_tenant_name), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'incomplete',
      'message', 'Contact name or business name is missing — refusing to send a message with a blank in it.');
  END IF;

  v_template := CASE WHEN p_channel = 'whatsapp'
                     THEN 'payment_request_whatsapp'
                     ELSE 'payment_request_email' END;

  IF p_dry_run THEN
    RETURN jsonb_build_object('ok', true, 'dry_run', true,
      'rule_enabled', v_rule_on, 'rule_key', 'notif_payment_request',
      'channel', p_channel, 'template_key', v_template,
      'recipient_name', v_name, 'recipient_contact', v_address,
      'invoice_number', v_inv.invoice_number,
      'amount', trim_scale(v_amount)::text, 'currency', v_currency,
      'tenant_name', v_tenant_name, 'is_live', v_inv.is_live);
  END IF;

  -- ── double-tap protection. Lock first so two concurrent sends serialise,
  --    THEN look. See the header for why this is not ON CONFLICT. ──────────
  PERFORM pg_advisory_xact_lock(hashtextextended(p_invoice::text || ':' || p_channel, 0));

  SELECT MAX(j.created_at) INTO v_recent
    FROM public.n_jtd j
   WHERE j.tenant_id = p_tenant
     AND j.source_type_code = 'payment_request'
     AND j.source_id = p_invoice
     AND j.channel_code = p_channel
     AND j.created_at > now() - interval '2 minutes';

  IF v_recent IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_sent_just_now',
      'sent_at', v_recent,
      'message', format('%s was already sent by %s moments ago.',
                        v_inv.invoice_number, p_channel));
  END IF;

  -- ── enqueue. trg_jtd_enqueue does the pgmq hand-off from here. ──────────
  INSERT INTO public.n_jtd (
    tenant_id, event_type_code, channel_code, source_type_code, source_id,
    recipient_type, recipient_id, recipient_name, recipient_contact,
    template_key, template_variables, is_live,
    performed_by_type, performed_by_id, business_context
  ) VALUES (
    p_tenant, 'notification', p_channel, 'payment_request', p_invoice,
    'contact', v_contact, v_name, v_address,
    v_template,
    jsonb_build_object(
      'customer_name',  v_name,
      'tenant_name',    v_tenant_name,
      'invoice_number', v_inv.invoice_number,
      'amount',         trim_scale(v_amount)::text,
      'currency',       v_currency,
      -- No payment gateway link is minted here. The templates mark
      -- payment_link optional, and inventing a dead URL would be worse than
      -- omitting it. Wire this when the gateway link exists.
      'payment_link',   '',
      'expire_hours',   '48'
    ),
    v_inv.is_live,
    CASE WHEN p_user IS NULL THEN 'system' ELSE 'user' END, p_user,
    jsonb_build_object('invoice_id', p_invoice, 'contract_id', v_inv.contract_id,
                       'due_date', v_inv.due_date, 'sent_manually', true)
  )
  RETURNING id INTO v_jtd;

  RETURN jsonb_build_object('ok', true, 'jtd_id', v_jtd,
    'channel', p_channel, 'recipient_name', v_name,
    'recipient_contact', v_address, 'invoice_number', v_inv.invoice_number,
    'amount', trim_scale(v_amount)::text, 'currency', v_currency,
    'is_live', v_inv.is_live);
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_enqueue_invoice_notification(uuid, uuid, text, uuid, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_enqueue_invoice_notification(uuid, uuid, text, uuid, boolean) IS
  'Manual invoice send. Gated by the tenant automation rule '
  'notif_payment_request; enqueues ONE n_jtd row on the existing '
  'payment_request source type + templates. No trigger, no schedule — the '
  'Send Invoice button is the only caller. Returns {ok:false, reason} rather '
  'than failing silently.';

-- ============================================================================
-- ⚠ BEFORE ENABLING WHATSAPP — read this.
--
-- 'payment_request_whatsapp' maps to provider template id 'payment_request'.
-- Two things about it are UNVERIFIED from inside the database:
--   1. whether MSG91/Meta still has that template approved, and
--   2. whether it was registered with NAMED ({{customer_name}}) or POSITIONAL
--      ({{1}}) parameters.
-- Getting (2) wrong fails SILENTLY: MSG91 accepts the request and returns a
-- request_id, the n_jtd row reads 'sent', and WhatsApp rejects it on delivery.
-- Two templates failed exactly this way from 1–4 Aug and were only caught by
-- checking a handset.
--
-- jtd-worker/handlers/whatsapp.ts now carries an explicit 'payment_request'
-- branch (it previously fell through to the positional fallback, which that
-- file's own comment warns is unreliable because n_jtd.template_variables
-- round-trips through jsonb and Postgres does not preserve key order).
-- The branch is written NAMED, per the pre-Aug-2026 registration rule, and is
-- a ONE-LINE flip to positional if a test send proves otherwise.
--
-- So: send ONE whatsapp invoice to your own number, look at the handset, and
-- only then use it on a member.
-- ============================================================================
