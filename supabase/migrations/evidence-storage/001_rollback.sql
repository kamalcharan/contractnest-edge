-- 001_rollback.sql — undo batch A.
-- Safe while nothing has written to the registry. If rows exist, export them first:
-- they are the only index of what Firebase holds.

BEGIN;

-- 5. m_form_submissions — restore strict tenant isolation
DROP POLICY IF EXISTS m_form_submissions_read  ON public.m_form_submissions;
DROP POLICY IF EXISTS m_form_submissions_write ON public.m_form_submissions;
CREATE POLICY m_form_submissions_tenant_isolation
    ON public.m_form_submissions FOR ALL
    USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

-- 4. t_contract_event_assets — back to RLS disabled (its pre-batch state)
DROP POLICY IF EXISTS t_contract_event_assets_read  ON public.t_contract_event_assets;
DROP POLICY IF EXISTS t_contract_event_assets_write ON public.t_contract_event_assets;
ALTER TABLE public.t_contract_event_assets DISABLE ROW LEVEL SECURITY;

-- 3. tenant columns
ALTER TABLE public.t_tenants DROP CONSTRAINT IF EXISTS chk_tenant_evidence_retention;
ALTER TABLE public.t_tenants DROP COLUMN IF EXISTS evidence_retention_days;
ALTER TABLE public.t_tenants DROP COLUMN IF EXISTS storage_quota_bytes;

-- 2. registry
DROP TABLE IF EXISTS public.t_contract_evidence;

-- 1. predicate
DROP FUNCTION IF EXISTS public.contract_membership_self(uuid);
DROP FUNCTION IF EXISTS public.contract_membership(uuid, uuid, text, text);

COMMIT;
