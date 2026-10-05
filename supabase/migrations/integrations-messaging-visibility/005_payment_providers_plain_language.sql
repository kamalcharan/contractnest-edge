-- ============================================================================
-- 005 — Payment Gateway providers in plain language (batch onboarding-team-payments)
-- ============================================================================
-- Data only, no schema change. Settings → Integrations and the onboarding
-- "How you get paid" step read these rows.
--
-- 1. Stripe is hidden (is_active = false). Nothing in the product can take a
--    Stripe payment: payment-webhook accepts only 'razorpay' and
--    fn_tenant_payment_options looks only at razorpay + offline_upi, so a
--    tenant could "connect" Stripe and collect nothing. No tenant has a Stripe
--    row (checked 2026-10-02). Re-enable by flipping is_active back.
--
-- 2. Offline UPI gets a name and description any tenant recognises. The old
--    text was written for BBB's check-in ("Members tap Pay at check-in").
--    provider name 'offline_upi' (the key code reads) is unchanged.
--
-- 3. Razorpay carries setup help for IntegrationSetupModal
--    (components/integrations/IntegrationSetupGuide reads these keys):
--      setup_steps   ordered "where to find these" steps
--      webhook_path  edge function path; the UI prefixes the Supabase URL
--      webhook_note  why the webhook matters
--    The webhook is a backup, not a requirement: checkout verifies the payment
--    signature in the browser (payment-gateway verify-payment) and records the
--    receipt; the webhook catches a payment whose page was closed before that
--    call, and payment links.
--
-- Idempotent: every statement sets absolute values.
-- ============================================================================

BEGIN;

UPDATE t_integration_providers
   SET is_active = false
 WHERE name = 'stripe';

UPDATE t_integration_providers
   SET display_name = 'UPI to your bank account',
       description  = 'Collect over UPI with no gateway and no fees. Customers scan your QR or pay your UPI ID, then tell you the reference — you confirm it in Money In.'
 WHERE name = 'offline_upi';

UPDATE t_integration_providers
   SET description = 'Online payments by card, UPI and netbanking. Payments are matched to the invoice automatically. Razorpay charges its own fee.',
       metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
         'setup_steps', jsonb_build_array(
           'In the Razorpay Dashboard (Live mode), open Account & Settings → API Keys and click Generate key.',
           'Paste the Key ID and Key Secret below.',
           'Recommended: open Account & Settings → Webhooks → Add new webhook, paste the Webhook URL below, tick payment.captured and payment.failed, and set a secret.',
           'Paste that webhook secret below.'
         ),
         'webhook_path', 'payment-webhook/razorpay',
         'webhook_note', 'Payments are recorded without it. The webhook catches a payment whose page was closed before it finished, and payment-link payments.'
       )
 WHERE name = 'razorpay';

-- Post-check: all three rows exist and landed as intended.
DO $$
BEGIN
  IF (SELECT count(*) FROM t_integration_providers
       WHERE (name = 'stripe' AND is_active = false)
          OR (name = 'offline_upi' AND display_name = 'UPI to your bank account')
          OR (name = 'razorpay' AND metadata ? 'webhook_path')) <> 3 THEN
    RAISE EXCEPTION '005: expected 3 provider rows updated';
  END IF;
END $$;

COMMIT;
