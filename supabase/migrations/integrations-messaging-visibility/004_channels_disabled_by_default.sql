-- 004_channels_disabled_by_default.sql
--
-- Audit item #7 (2026-08-01): "onboarding should switch off integrations —
-- email, WhatsApp and SMS should be in disabled mode."
--
-- WHAT WAS WRONG (verified live):
--   1. seed_builtin_channel_integrations() created email + WhatsApp rows
--      with is_active = TRUE from the instant the tenant existed —
--      channels live before the tenant ever saw the Integrations page.
--   2. contractnest_sms was NEVER in the trigger's provider list, so no
--      tenant rows existed and no SMS toggle could even render.
--   3. No n_jtd_tenant_config rows were created at tenant creation, and
--      that's the table the jtd-worker (the single chokepoint every queued
--      message passes through) actually checks — only 1 of 117 tenants had
--      rows. Worse, both the column default and toggle_integration_status'
--      fallback template carry "email": true — a config-less tenant, or the
--      first WhatsApp toggle on one, silently enabled email.
--
-- WHAT THIS DOES (new tenants only — existing tenants are being wiped, per
-- owner decision 2026-08-02, so no backfill):
--   a. Trigger seeds ALL THREE built-in channels (email, WhatsApp, SMS),
--      both environments, is_active = FALSE. connection_status stays
--      'Connected' — built-ins need no setup; disabled ≠ disconnected.
--   b. Trigger also creates n_jtd_tenant_config rows (both environments)
--      with every OUTBOUND channel off (inapp stays true — in-product
--      notifications are harmless and expected). The real kill switch now
--      exists, in the off position, from second zero.
--   c. toggle_integration_status(): learns the SMS mapping and its
--      create-if-missing fallback template becomes all-off, so a first
--      toggle of one channel can never side-enable another.
--
-- The ENABLE path needs no work: the toggle RPC already syncs
-- t_tenant_integrations.is_active ↔ n_jtd_tenant_config.channels_enabled
-- for both environments (002/003 of this series).

-- ============================================================================
-- a + b: tenant-creation trigger — all channels seeded DISABLED + jtd config
-- ============================================================================
CREATE OR REPLACE FUNCTION public.seed_builtin_channel_integrations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Built-in channel rows, both environments, DISABLED by default.
  INSERT INTO t_tenant_integrations (tenant_id, master_integration_id, is_active, is_live, connection_status)
  SELECT NEW.id::text, p.id, false, env.is_live, 'Connected'
  FROM t_integration_providers p
  CROSS JOIN (VALUES (true), (false)) AS env(is_live)
  WHERE p.name IN ('contractnest_whatsapp', 'contractnest_email', 'contractnest_sms')
    AND p.metadata->>'platform_managed' = 'true';

  -- The worker-side kill switch, present from creation, outbound channels off.
  INSERT INTO n_jtd_tenant_config (tenant_id, is_live, is_active, channels_enabled)
  SELECT NEW.id, env.is_live, true,
         '{"sms": false, "push": false, "email": false, "inapp": true, "whatsapp": false}'::jsonb
  FROM (VALUES (true), (false)) AS env(is_live)
  ON CONFLICT (tenant_id, is_live) DO NOTHING;

  RETURN NEW;
END;
$function$;

-- ============================================================================
-- c: toggle RPC — SMS mapping + all-off fallback template
-- ============================================================================
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

  IF v_provider_name IN ('contractnest_whatsapp', 'contractnest_email', 'contractnest_sms') THEN
    v_channel := CASE v_provider_name
      WHEN 'contractnest_whatsapp' THEN 'whatsapp'
      WHEN 'contractnest_sms'      THEN 'sms'
      ELSE 'email'
    END;

    -- Fallback template is ALL-OFF (was "email": true — toggling WhatsApp on
    -- a config-less tenant used to silently enable email as a side effect).
    INSERT INTO n_jtd_tenant_config (tenant_id, is_live, channels_enabled)
    VALUES (
      p_tenant_id::uuid, true,
      jsonb_set('{"sms": false, "push": false, "email": false, "inapp": true, "whatsapp": false}'::jsonb, ARRAY[v_channel], to_jsonb(p_is_active))
    )
    ON CONFLICT (tenant_id, is_live) DO UPDATE
      SET channels_enabled = jsonb_set(COALESCE(n_jtd_tenant_config.channels_enabled, '{}'::jsonb), ARRAY[v_channel], to_jsonb(p_is_active)),
          updated_at = now();

    INSERT INTO n_jtd_tenant_config (tenant_id, is_live, channels_enabled)
    VALUES (
      p_tenant_id::uuid, false,
      jsonb_set('{"sms": false, "push": false, "email": false, "inapp": true, "whatsapp": false}'::jsonb, ARRAY[v_channel], to_jsonb(p_is_active))
    )
    ON CONFLICT (tenant_id, is_live) DO UPDATE
      SET channels_enabled = jsonb_set(COALESCE(n_jtd_tenant_config.channels_enabled, '{}'::jsonb), ARRAY[v_channel], to_jsonb(p_is_active)),
          updated_at = now();
  END IF;

  RETURN v_result;
END;
$function$;
