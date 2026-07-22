-- Fix from live testing: get_integrations_by_type / get_tenant_integration
-- join t_tenant_integrations on (tenant_id, is_live = p_is_live) — i.e. a
-- tenant needs a SEPARATE row per environment. 002 only seeded is_live=true,
-- so the toggle never appeared while viewing the Integrations page in TEST
-- mode (the LEFT JOIN found nothing, is_configured came back false, and the
-- static "Active"/"Enabled" copy kept showing with no toggle underneath).
--
-- Fix: seed both is_live=true AND is_live=false rows, for new tenants
-- (trigger) and existing ones (backfill).

CREATE OR REPLACE FUNCTION public.seed_builtin_channel_integrations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO t_tenant_integrations (tenant_id, master_integration_id, is_active, is_live, connection_status)
  SELECT NEW.id::text, p.id, true, env.is_live, 'Connected'
  FROM t_integration_providers p
  CROSS JOIN (VALUES (true), (false)) AS env(is_live)
  WHERE p.name IN ('contractnest_whatsapp', 'contractnest_email')
    AND p.metadata->>'platform_managed' = 'true';
  RETURN NEW;
END;
$function$;

-- Backfill the missing is_live=false rows for every tenant that already
-- got an is_live=true row from 002 (same active-state per tenant as
-- whatever that tenant's true-env row already has, so BBB's already-
-- disabled state carries over to its test-env row too).
INSERT INTO t_tenant_integrations (tenant_id, master_integration_id, is_active, is_live, connection_status)
SELECT ti.tenant_id, ti.master_integration_id, ti.is_active, false, 'Connected'
FROM t_tenant_integrations ti
WHERE ti.master_integration_id IN (
    SELECT id FROM t_integration_providers WHERE name IN ('contractnest_whatsapp', 'contractnest_email')
  )
  AND ti.is_live = true
  AND NOT EXISTS (
    SELECT 1 FROM t_tenant_integrations ti2
    WHERE ti2.tenant_id = ti.tenant_id
      AND ti2.master_integration_id = ti.master_integration_id
      AND ti2.is_live = false
  );
