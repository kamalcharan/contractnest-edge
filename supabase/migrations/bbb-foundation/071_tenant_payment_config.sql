-- ============================================================================
-- 071 — get_tenant_payment_config: the third door onto one lookup
-- ----------------------------------------------------------------------------
-- Reading a tenant's offline-UPI settings already existed TWICE, as two public
-- surfaces onto the same body:
--   · get_public_offline_upi_config(cnak, secret)  — public contract page
--   · gs_checkin_payment_config(token)             — group-session check-in
-- Both resolve a key to a tenant, then read the same
-- t_tenant_integrations.credentials->'public' for provider 'offline_upi'.
--
-- The invoice screen needs a THIRD door: authenticated, keyed by tenant
-- directly rather than by a public token. Rather than paste the body a third
-- time, this is the shared implementation. The two existing functions are left
-- untouched — they can adopt this later without being disturbed now.
--
-- GENERIC BY CONSTRUCTION: takes (tenant, is_live) and nothing else. No tenant
-- is named anywhere. is_live is NOT defaulted and NOT guessed — it arrives
-- from auth context (the x-environment header) on every call, because a
-- tenant's Live and Test integrations are independently configured and
-- answering for the wrong one is answering wrongly. This is the scoping
-- dimension can_collect_payment silently drops.
--
-- Returns, always with 'configured' present so callers can branch on one key:
--   {configured:false}
--   {configured:true, upi_id, payee_name, qr_image_url, has_qr}
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_tenant_payment_config(
  p_tenant  uuid,
  p_is_live boolean
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pub jsonb;
BEGIN
  IF p_tenant IS NULL OR p_is_live IS NULL THEN
    RETURN jsonb_build_object('configured', false, 'reason', 'tenant_and_environment_required');
  END IF;

  -- t_tenant_integrations.tenant_id is TEXT, hence the cast — matching
  -- gs_checkin_payment_config rather than inventing a different comparison.
  SELECT ti.credentials->'public'
    INTO v_pub
    FROM public.t_tenant_integrations ti
    JOIN public.t_integration_providers ip ON ip.id = ti.master_integration_id
   WHERE ip.name = 'offline_upi'
     AND ti.tenant_id = p_tenant::text
     AND ti.is_live = p_is_live
     AND ti.is_active
   ORDER BY ti.updated_at DESC NULLS LAST
   LIMIT 1;

  IF v_pub IS NULL OR COALESCE(v_pub->>'upi_id', '') = '' THEN
    RETURN jsonb_build_object('configured', false);
  END IF;

  RETURN jsonb_build_object(
    'configured',   true,
    'upi_id',       v_pub->>'upi_id',
    'payee_name',   COALESCE(v_pub->>'payee_name', ''),
    -- Optional per the provider's own config_schema. Absent is normal: a
    -- tenant can collect on the VPA alone, so callers must not assume an image.
    'qr_image_url', NULLIF(COALESCE(v_pub->>'qr_image_url', ''), ''),
    'has_qr',       COALESCE(v_pub->>'qr_image_url', '') <> ''
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_tenant_payment_config(uuid, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.get_tenant_payment_config(uuid, boolean) IS
  'Tenant-scoped offline UPI config (upi_id, payee_name, qr_image_url), '
  'environment-aware. Shared implementation behind the public CNAK and '
  'check-in token variants; generic — takes tenant + is_live only.';


-- ============================================================================
-- fn_enqueue_invoice_notification gains p_payment_link.
-- ----------------------------------------------------------------------------
-- 070 hardcoded payment_link to '' because I had not found the payment-link
-- feature. It exists: paymentGatewayService.createLink() mints a Razorpay
-- short URL ("Create a payment link for email/WhatsApp delivery"), and
-- t_contract_payment_requests carries gateway_short_url + a jtd_id column that
-- was always meant to point at the notification that delivered it.
--
-- The CALLER decides what goes in, mirroring getPublicPaymentContext — which
-- is the app's existing single source of truth for "can this tenant collect":
--     gatewayConfigured  → the Razorpay short URL
--     offline_upi        → a upi:// intent or the VPA
--     neither            → NULL, and the message simply carries no pay line
-- Deciding in the API layer keeps this function free of gateway knowledge and
-- keeps is_live where it belongs — on the request, from auth context.
--
-- p_qr_url rides along for WhatsApp: the worker sends it as the header image
-- (components.header_1), which is how a payer gets a scannable QR when there
-- is no gateway link. NULL is normal and must not break the send.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_enqueue_invoice_notification(
  p_tenant       uuid,
  p_invoice      uuid,
  p_channel      text    DEFAULT 'email',
  p_user         uuid    DEFAULT NULL,
  p_dry_run      boolean DEFAULT false,
  p_payment_link text    DEFAULT NULL,
  p_qr_url       text    DEFAULT NULL
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

  v_rule_on := public.vani_rule_enabled(p_tenant, 'notif_payment_request');

  IF NOT v_rule_on AND NOT p_dry_run THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rule_disabled',
      'rule_key', 'notif_payment_request',
      'message', 'Payment request notifications are switched off for this business. Turn on "Standalone payment request" in Settings → Configure → Automation Rules.');
  END IF;

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

  v_amount   := GREATEST(COALESCE(v_inv.balance, v_inv.total_amount, 0), 0);
  v_currency := COALESCE(v_inv.currency, 'INR');

  IF v_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'nothing_owed',
      'message', format('%s is fully settled — there is nothing to request.',
                        v_inv.invoice_number));
  END IF;

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
      'tenant_name', v_tenant_name, 'is_live', v_inv.is_live,
      'payment_link', COALESCE(p_payment_link, ''), 'qr_url', p_qr_url);
  END IF;

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

  INSERT INTO public.n_jtd (
    tenant_id, event_type_code, channel_code, source_type_code, source_id,
    recipient_type, recipient_id, recipient_name, recipient_contact,
    template_key, template_variables, is_live,
    performed_by_type, performed_by_id, business_context, metadata
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
      'payment_link',   COALESCE(p_payment_link, ''),
      'expire_hours',   '48'
    ),
    v_inv.is_live,
    CASE WHEN p_user IS NULL THEN 'system' ELSE 'user' END, p_user,
    jsonb_build_object('invoice_id', p_invoice, 'contract_id', v_inv.contract_id,
                       'due_date', v_inv.due_date, 'sent_manually', true),
    -- media_url is where the worker looks for a header image. A QR only makes
    -- sense on WhatsApp; email carries the VPA in text instead.
    CASE WHEN p_channel = 'whatsapp' AND p_qr_url IS NOT NULL
         THEN jsonb_build_object('media_url', p_qr_url)
         ELSE '{}'::jsonb END
  )
  RETURNING id INTO v_jtd;

  RETURN jsonb_build_object('ok', true, 'jtd_id', v_jtd,
    'channel', p_channel, 'recipient_name', v_name,
    'recipient_contact', v_address, 'invoice_number', v_inv.invoice_number,
    'amount', trim_scale(v_amount)::text, 'currency', v_currency,
    'is_live', v_inv.is_live);
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_enqueue_invoice_notification(uuid, uuid, text, uuid, boolean, text, text)
  TO authenticated, service_role;

-- 070's 5-argument signature is superseded. Dropped so it cannot resolve by
-- accident — the stale gs_checkin_guest overload is the cautionary tale.
DROP FUNCTION IF EXISTS public.fn_enqueue_invoice_notification(uuid, uuid, text, uuid, boolean);
