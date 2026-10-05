-- 025_payment_instalment_due_template.sql
-- APPLIED LIVE 2026-10-02 — source-of-record copy, do not re-run (it is idempotent anyway).
--
-- A reminder for ONE instalment of a multi-payment invoice — distinct from
--   payment_request  (full invoice sent)  and
--   payment_due      (scanner: whole-invoice balance, once per invoice).
-- MSG91 WhatsApp template `payment_instalment_due_v1` (POSITIONAL, registered
-- 2026-10-02, awaiting Meta approval). The worker's generic path fills
-- body_1..body_7 from `variables` in the declared order below.
--
--   Hi {{1}},
--
--   As per your {{2}} plan with {{3}}, your payment for {{4}} is {{5}}, due on {{6}}.
--
--   Please pay {{7}}.
--
--   Thank you!
--
-- Nothing produces this source type yet: no message can be sent from it until
-- the Nudge / ladder is pointed at it (next step, after approval).
-- WhatsApp only — the email twin is not registered.

BEGIN;

INSERT INTO n_jtd_source_types (code, name, description, source_table, source_id_field,
                                default_channels, default_event_type, is_active)
VALUES ('payment_instalment_due', 'Instalment due (reminder)',
        'Reminder for one instalment of a multi-payment invoice. source_id = the payment job.',
        'n_jtd', 'id', ARRAY['whatsapp']::text[], 'reminder', true)
ON CONFLICT (code) DO NOTHING;

-- Global seed row: copied to every NEW tenant by trg_tenants_seed_jtd_templates.
INSERT INTO n_jtd_templates (tenant_id, template_key, name, description, channel_code,
       source_type_code, subject, content, variables, provider_template_id, version, is_live, is_active)
SELECT NULL, 'payment_instalment_due_whatsapp', 'Instalment due (WhatsApp)',
       'One instalment of a multi-payment invoice. MSG91 template payment_instalment_due_v1 (positional; variables in declared order).',
       'whatsapp', 'payment_instalment_due', NULL,
       E'Hi {{customer_name}},\n\nAs per your {{plan}} plan with {{tenant_name}}, your payment for {{period}} is {{amount}}, due on {{due_date}}.\n\nPlease pay {{pay_line}}.\n\nThank you!',
       '["customer_name","plan","tenant_name","period","amount","due_date","pay_line"]'::jsonb,
       'payment_instalment_due_v1', 1, true, true
WHERE NOT EXISTS (SELECT 1 FROM n_jtd_templates
                   WHERE tenant_id IS NULL AND source_type_code = 'payment_instalment_due'
                     AND channel_code = 'whatsapp' AND is_active);

-- Existing tenants: copy the global row (same columns fn_seed_jtd_templates_for_tenant copies).
-- Only this template — other templates a tenant may be missing are not touched here.
INSERT INTO n_jtd_templates (tenant_id, template_key, name, description, channel_code,
       source_type_code, subject, content, content_html, variables, provider_template_id, version, is_live, is_active)
SELECT t.id, g.template_key, g.name, g.description, g.channel_code, g.source_type_code,
       g.subject, g.content, g.content_html, g.variables, g.provider_template_id, COALESCE(g.version,1), true, true
  FROM t_tenants t
  JOIN n_jtd_templates g ON g.tenant_id IS NULL AND g.is_active
                        AND g.source_type_code = 'payment_instalment_due' AND g.channel_code = 'whatsapp'
 WHERE COALESCE(t.status,'') <> 'closed'
ON CONFLICT (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid),
             source_type_code, channel_code) WHERE is_active DO NOTHING;

DO $$
DECLARE v_missing int;
BEGIN
  SELECT count(*) INTO v_missing FROM t_tenants t
   WHERE COALESCE(t.status,'') <> 'closed'
     AND NOT EXISTS (SELECT 1 FROM n_jtd_templates x WHERE x.tenant_id = t.id AND x.is_active
                       AND x.source_type_code = 'payment_instalment_due' AND x.channel_code = 'whatsapp');
  IF v_missing > 0 THEN
    RAISE EXCEPTION '025: % tenant(s) still without the instalment template', v_missing;
  END IF;
END $$;

COMMIT;
