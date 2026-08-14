-- ============================================================================
-- 072 — Wire the invoice send to the MSG91 templates registered 2026-08-14
-- ALREADY APPLIED LIVE (three migrations, recorded here as one). DO NOT RE-RUN.
-- ----------------------------------------------------------------------------
-- Registered in MSG91 by the owner:
--   WhatsApp  payment_request_v2         positional {{1}}..{{5}}, UTILITY
--   Email     payment_request_email_v2   named, HTML body held by MSG91
--
-- Registering fresh removed the biggest unknown in Part 3: anything created
-- from Aug 2026 onward is POSITIONAL, so the named-vs-positional guess that
-- cost a cycle in early August does not apply. The worker's generic path
-- already emits positional from each template's declared `variables`.
--
-- ⚠ `variables` IS THE CONTRACT, NOT DOCUMENTATION.
-- jtd-worker reads that array to order the WhatsApp parameters. If it ever
-- disagrees with the {{1}}..{{5}} registered at MSG91, values land in the
-- wrong slots — and WhatsApp ACCEPTS that, so it fails while looking like it
-- worked. Any edit to the MSG91 template must be mirrored here in the same
-- change.
--   WhatsApp order: customer_name, tenant_name, invoice_number, amount, pay_line
--   Email  (named): the same five plus due_date
-- ============================================================================

UPDATE public.n_jtd_templates
   SET provider_template_id = 'payment_request_v2',
       content = 'Hi {{customer_name}}, {{tenant_name}} has sent you an invoice.

Invoice: {{invoice_number}}
Amount due: {{amount}}

Pay here: {{pay_line}}

Thank you!',
       variables = '["customer_name","tenant_name","invoice_number","amount","pay_line"]'::jsonb,
       updated_at = now()
 WHERE template_key = 'payment_request_whatsapp';

UPDATE public.n_jtd_templates
   SET provider_template_id = 'payment_request_email_v2',
       subject = 'Invoice {{invoice_number}} from {{tenant_name}} — {{amount}} due',
       content = 'Hi {{customer_name}},

{{tenant_name}} has sent you an invoice.

Invoice: {{invoice_number}}
Amount due: {{amount}}
Due: {{due_date}}

Pay here: {{pay_line}}

Thank you.',
       variables = '["customer_name","tenant_name","invoice_number","amount","due_date","pay_line"]'::jsonb,
       updated_at = now()
 WHERE template_key = 'payment_request_email';

-- ── fn_invoice_pay_line ─────────────────────────────────────────────────────
-- No parameter may go out blank. WhatsApp/Meta reject empty body values on
-- DELIVERY, not on submit: MSG91 accepts, returns a request_id, the n_jtd row
-- reads 'sent', and nothing arrives. Same silent class as the CRLF-in-names
-- defect of 2026-08-05. Also: only a real gateway link expires — claiming
-- "48 hours" for a UPI intent would simply be false.
CREATE OR REPLACE FUNCTION public.fn_invoice_pay_line(
  p_payment_link text,
  p_upi_id       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN COALESCE(p_payment_link, '') <> '' AND p_payment_link LIKE 'http%'
      THEN jsonb_build_object('pay_line', p_payment_link, 'expire_hours', '48')
    WHEN COALESCE(p_payment_link, '') <> ''
      THEN jsonb_build_object('pay_line',
             COALESCE(NULLIF(p_upi_id, ''), p_payment_link), 'expire_hours', 'no')
    ELSE jsonb_build_object('pay_line', 'Please contact us for payment details',
                            'expire_hours', 'no')
  END;
$fn$;

GRANT EXECUTE ON FUNCTION public.fn_invoice_pay_line(text, text) TO authenticated, service_role;

-- ── fn_enqueue_invoice_notification: emits exactly the declared variable sets
-- Full body applied live; see 070/071 for the surrounding rationale. Changes
-- in this revision:
--   · p_upi_id added, so a upi:// intent can be shown as the readable VPA
--     rather than a raw scheme URL nobody can act on inside a message
--   · amount is formatted ONCE here ("Rs 18,000", Indian digit grouping)
--     instead of shipping currency as a separate slot — one less slot to
--     misalign
--   · due_date formatted for the email template ("03 Aug 2026"), or the
--     honest "on receipt" when an invoice carries no due date
--   · template_variables built per channel to match the declared arrays above
--   · the 7-argument signature is dropped so it cannot resolve by accident
-- Verified live by dry run before enabling:
--   email    → 6 vars, Rs 18,000 / 03 Aug 2026 / BBB Bhagyanagar / INV-10067
--   whatsapp → 5 vars, pay_line collapsed to 9849502193@kbl
-- (Function body identical to the applied version; omitted here for brevity —
--  read it with \sf fn_enqueue_invoice_notification.)

-- ── activation ──────────────────────────────────────────────────────────────
-- Through the product's own version-checked RPC rather than a raw UPDATE, so
-- the optimistic-concurrency guard behaves exactly as it would had someone
-- clicked Edit in Settings → Configure → Automation Rules.
--   select update_vani_rule('<tenant>', 'notif_payment_request', '{}', true, <version>, null);
-- BBB: version 1 → 2, is_enabled false → true, 2026-08-14.
-- Safe to enable because sends are MANUAL ONLY — the Send Invoice button is
-- the sole caller. Turning the rule on starts no automatic traffic.
