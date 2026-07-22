-- Make Settings > Integrations the real, user-facing control for whether
-- the platform actually sends WhatsApp/email for a tenant, instead of the
-- static "Active · Powered by ContractNest" / "Enabled for your workspace"
-- copy it showed before (purely driven by a global catalog metadata flag,
-- with zero connection to any real per-tenant enable/disable state).
--
-- Two parts:
-- 1. Auto-provision a t_tenant_integrations row for the two built-in
--    providers (contractnest_whatsapp, contractnest_email) for every
--    tenant, present and future — this is what makes
--    IntegrationProviderCard.tsx render its already-existing real toggle
--    switch (it only appears when a tenant_integration row exists) instead
--    of just the static badge.
-- 2. Extend toggle_integration_status so flipping that switch also updates
--    n_jtd_tenant_config.channels_enabled — the table jtd-worker actually
--    checks before sending (see MANUAL_COPY_FILES/bbb-notification-killswitch/
--    and bbb-notification-killswitch's follow-up). Without this the toggle
--    would just be more informational UI with no real effect, same problem
--    as before.

-- 1a. Trigger: seed both built-in integrations for every NEW tenant.
CREATE OR REPLACE FUNCTION public.seed_builtin_channel_integrations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO t_tenant_integrations (tenant_id, master_integration_id, is_active, is_live, connection_status)
  SELECT NEW.id::text, p.id, true, true, 'Connected'
  FROM t_integration_providers p
  WHERE p.name IN ('contractnest_whatsapp', 'contractnest_email')
    AND p.metadata->>'platform_managed' = 'true';
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_tenants_seed_builtin_integrations ON public.t_tenants;
CREATE TRIGGER trg_tenants_seed_builtin_integrations
AFTER INSERT ON public.t_tenants
FOR EACH ROW EXECUTE FUNCTION seed_builtin_channel_integrations();

-- 1b. Backfill: every EXISTING tenant that doesn't already have a row for
-- these two providers. BBB (dd194710-92b4-4110-80eb-0b492a0d2c1f) is
-- seeded as already-disabled to match the n_jtd_tenant_config state set
-- earlier today, so the new toggle reflects reality instead of silently
-- flipping back to "on".
INSERT INTO t_tenant_integrations (tenant_id, master_integration_id, is_active, is_live, connection_status)
SELECT
  t.id::text,
  p.id,
  CASE WHEN t.id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f'::uuid THEN false ELSE true END,
  true,
  'Connected'
FROM t_tenants t
CROSS JOIN t_integration_providers p
WHERE p.name IN ('contractnest_whatsapp', 'contractnest_email')
  AND p.metadata->>'platform_managed' = 'true'
  AND NOT EXISTS (
    SELECT 1 FROM t_tenant_integrations ti
    WHERE ti.tenant_id = t.id::text AND ti.master_integration_id = p.id
  );

-- 2. toggle_integration_status: sync the built-in-channel case through to
-- n_jtd_tenant_config (both is_live=true and is_live=false, so the toggle
-- governs the tenant's messaging everywhere, not just one environment).
-- No exception handling added beyond what the original function had —
-- if the config sync fails, the whole toggle should fail loudly rather
-- than the UI reporting success while sending stays out of sync.
CREATE OR REPLACE FUNCTION public.toggle_integration_status(p_tenant_id text, p_integration_id uuid, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result JSONB;
  v_provider_name text;
  v_channel text;
BEGIN
  UPDATE t_tenant_integrations
  SET
    is_active = p_is_active,
    updated_at = NOW()
  WHERE id = p_integration_id
    AND tenant_id = p_tenant_id
  RETURNING jsonb_build_object(
    'success', true,
    'integration', jsonb_build_object(
      'id', id,
      'tenant_id', tenant_id,
      'master_integration_id', master_integration_id,
      'is_active', is_active,
      'is_live', is_live,
      'connection_status', connection_status,
      'last_verified', last_verified,
      'updated_at', updated_at
    )
  ) INTO v_result;

  IF v_result IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Integration not found or not authorized'
    );
  END IF;

  SELECT p.name INTO v_provider_name
  FROM t_integration_providers p
  JOIN t_tenant_integrations ti ON ti.master_integration_id = p.id
  WHERE ti.id = p_integration_id;

  IF v_provider_name IN ('contractnest_whatsapp', 'contractnest_email') THEN
    v_channel := CASE WHEN v_provider_name = 'contractnest_whatsapp' THEN 'whatsapp' ELSE 'email' END;

    INSERT INTO n_jtd_tenant_config (tenant_id, is_live, channels_enabled)
    VALUES (
      p_tenant_id::uuid, true,
      jsonb_set('{"sms": false, "push": false, "email": true, "inapp": true, "whatsapp": false}'::jsonb, ARRAY[v_channel], to_jsonb(p_is_active))
    )
    ON CONFLICT (tenant_id, is_live) DO UPDATE
      SET channels_enabled = jsonb_set(COALESCE(n_jtd_tenant_config.channels_enabled, '{}'::jsonb), ARRAY[v_channel], to_jsonb(p_is_active)),
          updated_at = now();

    INSERT INTO n_jtd_tenant_config (tenant_id, is_live, channels_enabled)
    VALUES (
      p_tenant_id::uuid, false,
      jsonb_set('{"sms": false, "push": false, "email": true, "inapp": true, "whatsapp": false}'::jsonb, ARRAY[v_channel], to_jsonb(p_is_active))
    )
    ON CONFLICT (tenant_id, is_live) DO UPDATE
      SET channels_enabled = jsonb_set(COALESCE(n_jtd_tenant_config.channels_enabled, '{}'::jsonb), ARRAY[v_channel], to_jsonb(p_is_active)),
          updated_at = now();
  END IF;

  RETURN v_result;
END;
$function$;
