-- ============================================================================
-- bbb-foundation/025_offline_upi_integration.sql
-- G1: "Offline UPI" integration provider. NOT a payment gateway (no API keys,
-- no fees) — it just holds the tenant's UPI VPA + payee name so the group-session
-- check-in can open the member's UPI app (GPay/PhonePe) via a upi:// intent.
--
-- The /settings/integrations page renders providers dynamically from
-- config_schema.fields, and saves the tenant's values into
-- t_tenant_integrations.credentials — so seeding this provider is all G1 needs.
-- metadata.kind='upi_intent' flags it for the check-in "Pay now" logic (G4);
-- metadata.config_only=true tells the setup modal this provider is plain
-- add/edit/delete (nothing to test/connect). Idempotent (insert-if-absent).
-- ============================================================================

INSERT INTO public.t_integration_providers
  (type_id, name, display_name, description, is_active, config_schema, metadata)
SELECT
  'f2135eee-cc3f-423a-9047-e64e06fd9b6e'::uuid,   -- payment_gateway type
  'offline_upi',
  'Offline UPI',
  'Collect dues over UPI without a gateway. Members tap "Pay" at check-in and their UPI app (GPay/PhonePe/Paytm) opens with your VPA and the amount pre-filled — you reconcile the reference. No API keys, no gateway fees.',
  true,
  jsonb_build_object('fields', jsonb_build_array(
    jsonb_build_object(
      'name','upi_id','type','text','required',true,'sensitive',false,
      'display_name','UPI ID (VPA)',
      'description','Where members pay dues, e.g. bbbchapter@okhdfcbank'),
    jsonb_build_object(
      'name','payee_name','type','text','required',true,'sensitive',false,
      'display_name','Payee name',
      'description','Name shown in the member''s UPI app when they pay')
  )),
  jsonb_build_object('kind','upi_intent','fee_free',true,'config_only',true)
WHERE NOT EXISTS (
  SELECT 1 FROM public.t_integration_providers WHERE name = 'offline_upi'
);

-- config_only=true so the setup modal drops the "test/connect" flow for any
-- already-seeded row (plain add/edit/delete of the stored values).
UPDATE public.t_integration_providers
   SET metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object('config_only', true)
 WHERE name = 'offline_upi' AND coalesce((metadata->>'config_only')::boolean, false) = false;
