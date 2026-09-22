-- 001_evidence_registry_and_membership.sql
-- Evidence Storage Redesign — batch A (ADDITIVE ONLY, no drops)
--
-- Builds the substrate the whole redesign stands on:
--   1. contract_membership()       — the ONE access predicate (seller / buyer tenant / CNAK)
--   2. t_contract_evidence         — the file registry; source of truth for what exists,
--                                    who owns it and what it costs
--   3. t_tenants.evidence_retention_days / storage_quota_bytes
--   4. RLS on t_contract_event_assets  (currently DISABLED while anon holds GRANT ALL)
--   5. m_form_submissions policy WIDENED so a buyer / CNAK holder can read the
--      submission that proves their visit (today: strict tenant isolation)
--
-- DELIBERATELY NOT IN THIS MIGRATION — the drops.
-- t_contract_attachments / t_tenant_files / t_service_evidence / m_form_attachments
-- hold 0 rows but are referenced by 11 live functions, four of them on hot read
-- paths (get_contract_by_id, get_service_ticket_detail/_report/_list). PL/pgSQL
-- late-binds table names, so DROP succeeds silently and those functions fail at
-- CALL time. Drops move to their own batch, after the callers are rewritten.
--
-- Units note: storage_quota (integer, MB) is LEFT ALONE. get_admin_tenant_list
-- still reads it as MB. The new truth is storage_quota_bytes; the old column is
-- retired in the same later batch as the drops.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE MEMBERSHIP PREDICATE
-- ─────────────────────────────────────────────────────────────────────────────
-- One rule, expressed once. The API, the RLS policies and any future reporting
-- all call this and nothing else.
--
--   caller_tenant = t_contracts.tenant_id         -- seller / creator (pays)
--   caller_tenant = t_contracts.buyer_tenant_id   -- buyer, once onboarded
--   valid CNAK + secret for THIS contract         -- buyer not yet a tenant
--
-- Applies unchanged to record_type='rfq' rows: on an RFQ the buyer IS the
-- creator, so t_contracts.tenant_id is still "who pays".

CREATE OR REPLACE FUNCTION public.contract_membership(
    p_contract_id uuid,
    p_tenant_id   uuid,
    p_cnak        text,
    p_secret      text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        -- party by tenant
        EXISTS (
            SELECT 1
            FROM t_contracts c
            WHERE c.id = p_contract_id
              AND p_tenant_id IS NOT NULL
              AND (c.tenant_id = p_tenant_id OR c.buyer_tenant_id = p_tenant_id)
        )
        OR
        -- party by bearer key, scoped to this contract, active and unexpired
        EXISTS (
            SELECT 1
            FROM t_contract_access a
            WHERE a.contract_id = p_contract_id
              AND p_cnak   IS NOT NULL
              AND p_secret IS NOT NULL
              AND a.global_access_id = p_cnak
              AND a.secret_code      = p_secret
              AND a.is_active
              AND (a.expires_at IS NULL OR a.expires_at > now())
        );
$$;

COMMENT ON FUNCTION public.contract_membership(uuid, uuid, text, text) IS
  'THE access predicate for contract-scoped evidence: seller tenant, buyer tenant, '
  'or a live CNAK+secret grant for this contract. Used by RLS, the storage broker '
  'and any future reporting. Never duplicate this rule — call it.';

-- RLS convenience wrapper: the caller is whoever the JWT says. No CNAK branch —
-- a bearer-key reader has no JWT and is served by the API broker, which calls
-- the four-argument form directly.
CREATE OR REPLACE FUNCTION public.contract_membership_self(p_contract_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT public.contract_membership(
        p_contract_id,
        public.get_current_tenant_id(),
        NULL,
        NULL
    );
$$;

COMMENT ON FUNCTION public.contract_membership_self(uuid) IS
  'contract_membership() for the JWT caller. For RLS policies only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE EVIDENCE REGISTRY
-- ─────────────────────────────────────────────────────────────────────────────
-- Replaces four tables that never agreed on how to address a file
-- (file_path / storage_path / a full file_url). object_path is a Firebase
-- object path and NEVER a URL: a URL hard-codes the host into the row and
-- cannot be re-signed per viewer.
--
-- Two namespaces, one table, told apart by `scope`:
--   scope='contract' → contracts/{contract_id}/{event_id}/{uuid}.{ext}  METERED
--   scope='tenant'   → tenants/{tenant_id}/{kind}/{uuid}.{ext}          NOT metered
--                      (logo, avatar, block icon, integration QR)

CREATE TABLE IF NOT EXISTS public.t_contract_evidence (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- which namespace this object lives in
    scope               text NOT NULL DEFAULT 'contract',

    -- contract anchor (scope='contract'); the access anchor
    contract_id         uuid REFERENCES public.t_contracts(id) ON DELETE CASCADE,
    event_id            uuid,          -- nullable: contract-level documents
    form_submission_id  uuid,          -- nullable: SmartForms evidence

    -- identity-asset anchor (scope='tenant')
    asset_kind          text,          -- 'logo' | 'avatar' | 'block_icon' | 'integration_qr'

    -- WHO PAYS. Denormalised from t_contracts.tenant_id (the creating tenant —
    -- seller on a contract, buyer on an RFQ) so metering never joins to reach it.
    -- Written once at upload, never changes.
    owner_tenant_id     uuid NOT NULL,

    -- the object
    object_path         text NOT NULL,
    file_name           text NOT NULL,
    mime_type           text NOT NULL,
    size_bytes          bigint NOT NULL DEFAULT 0,   -- read back from Firebase on confirm,
                                                     -- NEVER trusted from the client
    checksum            text,

    -- capture fidelity. Compression is what makes 40 MB workable; recording the
    -- fact now is the only way to tell later which historical evidence is a
    -- reduction, if a per-contract "keep originals" flag ever ships.
    is_compressed       boolean NOT NULL DEFAULT false,
    original_size_bytes bigint,

    -- lifecycle: pending → active (object confirmed) → deleted (bytes to be
    -- reclaimed by the StorageCleanup sweeper; NEVER deleted inline, because a
    -- Firebase delete cannot participate in a Postgres transaction)
    status              text NOT NULL DEFAULT 'pending',

    -- one quota across both environments, but a test reset must be able to FIND
    -- its objects to free the space
    is_live             boolean NOT NULL DEFAULT true,

    uploaded_by         uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    confirmed_at        timestamptz,
    deleted_at          timestamptz,

    CONSTRAINT chk_evidence_scope  CHECK (scope  IN ('contract', 'tenant')),
    CONSTRAINT chk_evidence_status CHECK (status IN ('pending', 'active', 'deleted')),

    -- a row is anchored to exactly one thing
    CONSTRAINT chk_evidence_anchor CHECK (
        (scope = 'contract' AND contract_id IS NOT NULL AND asset_kind IS NULL)
     OR (scope = 'tenant'   AND contract_id IS NULL     AND asset_kind IS NOT NULL)
    )
);

-- one registry row per object, always
CREATE UNIQUE INDEX IF NOT EXISTS ux_contract_evidence_object_path
    ON public.t_contract_evidence (object_path);

-- metering: sum(size_bytes) WHERE owner_tenant_id = $1 AND scope='contract' AND status='active'
CREATE INDEX IF NOT EXISTS ix_contract_evidence_metering
    ON public.t_contract_evidence (owner_tenant_id, status)
    WHERE scope = 'contract' AND status = 'active';

CREATE INDEX IF NOT EXISTS ix_contract_evidence_contract
    ON public.t_contract_evidence (contract_id) WHERE contract_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_contract_evidence_event
    ON public.t_contract_evidence (event_id) WHERE event_id IS NOT NULL;

-- sweeper work queues
CREATE INDEX IF NOT EXISTS ix_contract_evidence_pending
    ON public.t_contract_evidence (created_at) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS ix_contract_evidence_deleted
    ON public.t_contract_evidence (deleted_at) WHERE status = 'deleted';

-- test-reset sweep
CREATE INDEX IF NOT EXISTS ix_contract_evidence_env
    ON public.t_contract_evidence (owner_tenant_id, is_live);

COMMENT ON TABLE  public.t_contract_evidence IS
  'File registry for the whole product. Source of truth for what exists, who owns '
  'it and what it costs. Firebase holds bytes and nothing else.';
COMMENT ON COLUMN public.t_contract_evidence.object_path IS
  'Full Firebase object path. NEVER a URL — URLs hard-code the host and cannot be '
  're-signed per viewer.';
COMMENT ON COLUMN public.t_contract_evidence.owner_tenant_id IS
  'The creating tenant of the parent record (seller on a contract, buyer on an RFQ). '
  'Denormalised deliberately: metering sums this column and must not join to reach it.';
COMMENT ON COLUMN public.t_contract_evidence.size_bytes IS
  'Read back from Firebase at confirm time. The size a client declares at slot '
  'request is a claim, not a fact.';

ALTER TABLE public.t_contract_evidence ENABLE ROW LEVEL SECURITY;

-- Read: contract evidence follows the membership predicate; identity assets
-- follow plain tenant ownership.
DROP POLICY IF EXISTS t_contract_evidence_read ON public.t_contract_evidence;
CREATE POLICY t_contract_evidence_read
    ON public.t_contract_evidence
    FOR SELECT
    USING (
        (scope = 'contract' AND public.contract_membership_self(contract_id))
     OR (scope = 'tenant'   AND owner_tenant_id = public.get_current_tenant_id())
    );

-- Write: narrower than read, and that is the only asymmetry. Only the owning
-- (paying) tenant writes. The broker runs as service_role and bypasses this.
DROP POLICY IF EXISTS t_contract_evidence_write ON public.t_contract_evidence;
CREATE POLICY t_contract_evidence_write
    ON public.t_contract_evidence
    FOR ALL
    USING      (owner_tenant_id = public.get_current_tenant_id())
    WITH CHECK (owner_tenant_id = public.get_current_tenant_id());

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. TENANT-LEVEL STORAGE FACTS
-- ─────────────────────────────────────────────────────────────────────────────
-- 40 MB is the only free thing, live or closed. Retention says when the clock
-- starts after close; it never buys free space.

ALTER TABLE public.t_tenants
    ADD COLUMN IF NOT EXISTS storage_quota_bytes bigint NOT NULL DEFAULT 41943040;  -- 40 MB

ALTER TABLE public.t_tenants
    ADD COLUMN IF NOT EXISTS evidence_retention_days integer DEFAULT 90;

DO $retention$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_tenant_evidence_retention'
          AND conrelid = 'public.t_tenants'::regclass
    ) THEN
        ALTER TABLE public.t_tenants
            ADD CONSTRAINT chk_tenant_evidence_retention
            CHECK (evidence_retention_days IS NULL OR evidence_retention_days IN (90, 120, 150));
    END IF;
END
$retention$;

COMMENT ON COLUMN public.t_tenants.storage_quota_bytes IS
  'Current allowance in BYTES including top-ups. 40 MB by default. The old '
  'storage_quota (integer MB) is retired with the drops batch.';
COMMENT ON COLUMN public.t_tenants.evidence_retention_days IS
  'How long contract evidence survives after the tenant closes. NULL = permanent. '
  'Subordinate to storage_quota_bytes — retention never buys free space. Evidence on '
  'a contract whose counterparty is still an active tenant is never collected.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. t_contract_event_assets — RLS
-- ─────────────────────────────────────────────────────────────────────────────
-- This table carries evidence_id and form_submission_id, has RLS DISABLED, and
-- anon holds SELECT/INSERT/UPDATE/DELETE on it. Any holder of the public anon
-- key can currently read and modify all rows across every tenant. Enabling RLS
-- closes that and, with the membership predicate, gives the buyer the visibility
-- the product promises.
--
-- The tenant clause is kept alongside the predicate so this can only WIDEN
-- access relative to the isolation that was intended, never narrow it.

ALTER TABLE public.t_contract_event_assets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS t_contract_event_assets_read ON public.t_contract_event_assets;
CREATE POLICY t_contract_event_assets_read
    ON public.t_contract_event_assets
    FOR SELECT
    USING (
        tenant_id = public.get_current_tenant_id()
        OR public.contract_membership_self(contract_id)
    );

DROP POLICY IF EXISTS t_contract_event_assets_write ON public.t_contract_event_assets;
CREATE POLICY t_contract_event_assets_write
    ON public.t_contract_event_assets
    FOR ALL
    USING      (tenant_id = public.get_current_tenant_id())
    WITH CHECK (tenant_id = public.get_current_tenant_id());

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. m_form_submissions — the 85-90% case
-- ─────────────────────────────────────────────────────────────────────────────
-- Most contracts prove themselves with a smart report, not a photo — and a form
-- submission is contract-anchored evidence (contract_id and service_event_id are
-- both NOT NULL). Its policy was strict tenant isolation, so the buyer tenant
-- got nothing and a CNAK holder got nothing: the two stories that justify
-- contract-scoping in the first place failed for the common case.
--
-- The old clause is kept as the first branch, so this is strictly wider.

DROP POLICY IF EXISTS m_form_submissions_tenant_isolation ON public.m_form_submissions;
DROP POLICY IF EXISTS m_form_submissions_read  ON public.m_form_submissions;
DROP POLICY IF EXISTS m_form_submissions_write ON public.m_form_submissions;

CREATE POLICY m_form_submissions_read
    ON public.m_form_submissions
    FOR SELECT
    USING (
        tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id'
        OR public.contract_membership_self(contract_id)
    );

CREATE POLICY m_form_submissions_write
    ON public.m_form_submissions
    FOR ALL
    USING      (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id')
    WITH CHECK (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

COMMIT;
