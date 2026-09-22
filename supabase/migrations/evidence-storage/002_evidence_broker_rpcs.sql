-- 002_evidence_broker_rpcs.sql
-- Evidence Storage Redesign — batch B (the broker's half in the database)
--
-- The permission rule stays in Postgres beside the contract that defines it.
-- The API mints signed URLs; it never decides who may have one. Every RPC here
-- calls contract_membership() (migration 001) and nothing re-implements it.
--
--   evidence_request_slot   — may this caller upload here, and is there room?
--   evidence_confirm        — the object exists; record its TRUE size
--   evidence_resolve_read   — may this caller read this file? (tenant OR CNAK)
--   evidence_mark_deleted   — queue bytes for the sweeper; never delete inline
--   evidence_usage          — derived usage, quota, warn level
--   revoke_contract_access  — turn a CNAK off
--
-- Refusals are machine-readable { success:false, reason:'…' } so the controller
-- can map them to an HTTP status and the UI to copy. Nothing raises for a
-- caller mistake.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- Shared: the mime allowlist, in ONE place
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.evidence_mime_allowed(p_mime text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT p_mime = ANY (ARRAY[
        'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/gif',
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'text/plain',
        'image/svg+xml'
    ]);
$$;

COMMENT ON FUNCTION public.evidence_mime_allowed(text) IS
  'The single mime allowlist for uploads. The UI may show a narrower set; this is the wall.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_usage — DERIVED, never a counter
-- ─────────────────────────────────────────────────────────────────────────────
-- The old storage_consumed drifted into meaninglessness precisely because it
-- was an incremented counter with no way to recompute it. This sums the
-- registry every time. Identity assets (scope='tenant') are never counted:
-- a logo does not eat a technician's evidence allowance.

CREATE OR REPLACE FUNCTION public.evidence_usage(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_used  bigint;
    v_quota bigint;
    v_pct   numeric;
BEGIN
    SELECT COALESCE(storage_quota_bytes, 41943040) INTO v_quota
    FROM t_tenants WHERE id = p_tenant_id;

    IF v_quota IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'tenant_not_found');
    END IF;

    SELECT COALESCE(sum(size_bytes), 0) INTO v_used
    FROM t_contract_evidence
    WHERE owner_tenant_id = p_tenant_id
      AND scope  = 'contract'
      AND status = 'active';

    v_pct := CASE WHEN v_quota > 0 THEN round((v_used::numeric / v_quota) * 100, 1) ELSE 0 END;

    RETURN jsonb_build_object(
        'success',     true,
        'used_bytes',  v_used,
        'quota_bytes', v_quota,
        'free_bytes',  GREATEST(v_quota - v_used, 0),
        'pct',         v_pct,
        -- "Warn early and visibly": 80% notifies, 95% escalates and names top-up.
        'warn_level',  CASE WHEN v_used >= v_quota      THEN 'full'
                            WHEN v_pct  >= 95           THEN 'critical'
                            WHEN v_pct  >= 80           THEN 'warning'
                            ELSE 'ok' END
    );
END;
$$;

COMMENT ON FUNCTION public.evidence_usage(uuid) IS
  'Derived storage usage for a tenant. Sums the registry — never a stored counter. '
  'Identity assets (scope=tenant) are excluded: only contract evidence is metered.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_request_slot — the gate, BEFORE the work
-- ─────────────────────────────────────────────────────────────────────────────
-- "Check before the work, not after." The slot is requested at the start of the
-- evidence step, so a technician learns about a cap before committing effort.
--
-- Write access is narrower than read: only the CONTRACT CREATOR's tenant may
-- upload (they are also who pays). A buyer tenant reading the contract cannot
-- put bytes on the seller's bill.
--
-- The cap is a soft wall by design: an upload is refused only once usage has
-- ALREADY reached the quota. A tenant sitting under the line may always finish
-- the upload in hand, then is locked out until they top up — which turns a
-- field emergency into an office task.

CREATE OR REPLACE FUNCTION public.evidence_request_slot(
    p_tenant_id          uuid,
    p_user_id            uuid,
    p_scope              text,
    p_contract_id        uuid,
    p_event_id           uuid,
    p_form_submission_id uuid,
    p_asset_kind         text,
    p_file_name          text,
    p_mime_type          text,
    p_declared_size      bigint,
    p_is_compressed      boolean,
    p_original_size      bigint,
    p_is_live            boolean
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_creator   uuid;
    v_usage     jsonb;
    v_id        uuid := gen_random_uuid();
    v_ext       text;
    v_path      text;
    v_scope     text := COALESCE(p_scope, 'contract');
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'actor_required');
    END IF;
    IF p_file_name IS NULL OR btrim(p_file_name) = '' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'file_name_required');
    END IF;
    IF NOT evidence_mime_allowed(p_mime_type) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'mime_not_allowed',
                                  'detail', p_mime_type);
    END IF;
    IF COALESCE(p_declared_size, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'size_required');
    END IF;

    -- file extension, sanitised; unknown is fine (the mime is the real check)
    v_ext := lower(NULLIF(regexp_replace(
                 COALESCE(substring(p_file_name from '\.([A-Za-z0-9]+)$'), ''),
                 '[^a-z0-9]', '', 'gi'), ''));

    IF v_scope = 'tenant' THEN
        -- Identity assets: tenant's own namespace, not metered, no contract.
        IF p_asset_kind IS NULL OR p_asset_kind NOT IN ('logo','avatar','block_icon','integration_qr') THEN
            RETURN jsonb_build_object('success', false, 'reason', 'bad_asset_kind');
        END IF;

        v_path := format('tenants/%s/%s/%s%s', p_tenant_id, p_asset_kind, v_id,
                         CASE WHEN v_ext IS NULL THEN '' ELSE '.' || v_ext END);

        INSERT INTO t_contract_evidence
            (id, scope, asset_kind, owner_tenant_id, object_path, file_name, mime_type,
             size_bytes, is_compressed, original_size_bytes, status, is_live, uploaded_by)
        VALUES
            (v_id, 'tenant', p_asset_kind, p_tenant_id, v_path, p_file_name, p_mime_type,
             0, COALESCE(p_is_compressed, false), p_original_size, 'pending',
             COALESCE(p_is_live, true), p_user_id);

        RETURN jsonb_build_object('success', true, 'evidence_id', v_id,
                                  'object_path', v_path, 'metered', false);
    END IF;

    -- ── contract-scoped evidence ────────────────────────────────────────────
    IF v_scope <> 'contract' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'bad_scope');
    END IF;
    IF p_contract_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'contract_required');
    END IF;

    SELECT c.tenant_id INTO v_creator FROM t_contracts c WHERE c.id = p_contract_id;
    IF v_creator IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'contract_not_found');
    END IF;

    -- WRITE is creator-only. A buyer tenant may read every proof and upload none.
    IF v_creator <> p_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_contract_creator');
    END IF;

    -- the cap, evaluated BEFORE the work
    v_usage := evidence_usage(p_tenant_id);
    IF (v_usage->>'success')::boolean IS NOT TRUE THEN
        RETURN v_usage;
    END IF;
    IF (v_usage->>'used_bytes')::bigint >= (v_usage->>'quota_bytes')::bigint THEN
        RETURN jsonb_build_object('success', false, 'reason', 'cap_reached', 'usage', v_usage);
    END IF;

    v_path := format('contracts/%s/%s/%s%s',
                     p_contract_id,
                     COALESCE(p_event_id::text, 'contract'),
                     v_id,
                     CASE WHEN v_ext IS NULL THEN '' ELSE '.' || v_ext END);

    INSERT INTO t_contract_evidence
        (id, scope, contract_id, event_id, form_submission_id, owner_tenant_id,
         object_path, file_name, mime_type, size_bytes, is_compressed,
         original_size_bytes, status, is_live, uploaded_by)
    VALUES
        (v_id, 'contract', p_contract_id, p_event_id, p_form_submission_id, v_creator,
         v_path, p_file_name, p_mime_type, 0, COALESCE(p_is_compressed, false),
         p_original_size, 'pending', COALESCE(p_is_live, true), p_user_id);

    RETURN jsonb_build_object('success', true, 'evidence_id', v_id,
                              'object_path', v_path, 'metered', true, 'usage', v_usage);
END;
$$;

COMMENT ON FUNCTION public.evidence_request_slot IS
  'Gate for an upload: membership (creator only for writes), mime allowlist and the '
  'cap, all evaluated BEFORE the client uploads. Inserts a pending registry row and '
  'returns the reserved object path.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_confirm — record what Firebase ACTUALLY holds
-- ─────────────────────────────────────────────────────────────────────────────
-- The size declared at slot request is a client claim. This records the size the
-- API read back from the object. An unconfirmed row is an orphan the sweeper
-- reclaims.

CREATE OR REPLACE FUNCTION public.evidence_confirm(
    p_evidence_id uuid,
    p_tenant_id   uuid,
    p_size_bytes  bigint,
    p_checksum    text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_row t_contract_evidence%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM t_contract_evidence WHERE id = p_evidence_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'evidence_not_found');
    END IF;
    IF v_row.owner_tenant_id <> p_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_owner');
    END IF;
    IF v_row.status = 'active' THEN
        -- idempotent: a retried confirm is not an error
        RETURN jsonb_build_object('success', true, 'evidence_id', p_evidence_id,
                                  'already_confirmed', true,
                                  'usage', evidence_usage(p_tenant_id));
    END IF;
    IF v_row.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_pending');
    END IF;
    IF COALESCE(p_size_bytes, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'size_required');
    END IF;

    UPDATE t_contract_evidence
       SET size_bytes   = p_size_bytes,
           checksum     = COALESCE(p_checksum, checksum),
           status       = 'active',
           confirmed_at = now()
     WHERE id = p_evidence_id;

    RETURN jsonb_build_object('success', true, 'evidence_id', p_evidence_id,
                              'size_bytes', p_size_bytes,
                              'usage', evidence_usage(p_tenant_id));
END;
$$;

COMMENT ON FUNCTION public.evidence_confirm IS
  'Marks a pending registry row active with the size read back from Firebase. '
  'Idempotent — a retried confirm returns success.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_resolve_read — one predicate, both doors
-- ─────────────────────────────────────────────────────────────────────────────
-- Buyers reach the SAME object as sellers. Nothing is copied, nothing is
-- re-uploaded, and revoking a party's access revokes it for files already
-- delivered, because no durable URL was ever handed out.
--
-- A successful CNAK read also pushes that grant's expiry out: an active
-- relationship never expires, an abandoned link does.

CREATE OR REPLACE FUNCTION public.evidence_resolve_read(
    p_evidence_id uuid,
    p_tenant_id   uuid,
    p_cnak        text,
    p_secret      text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_row t_contract_evidence%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM t_contract_evidence WHERE id = p_evidence_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'evidence_not_found');
    END IF;
    IF v_row.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_available');
    END IF;

    IF v_row.scope = 'tenant' THEN
        IF p_tenant_id IS NULL OR v_row.owner_tenant_id <> p_tenant_id THEN
            RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
        END IF;
    ELSE
        IF NOT contract_membership(v_row.contract_id, p_tenant_id, p_cnak, p_secret) THEN
            RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
        END IF;

        -- reading with a key keeps the key alive
        IF p_tenant_id IS NULL AND p_cnak IS NOT NULL THEN
            UPDATE t_contract_access
               SET expires_at     = GREATEST(COALESCE(expires_at, now()), now() + interval '90 days'),
                   link_clicked_at = now()
             WHERE contract_id = v_row.contract_id
               AND global_access_id = p_cnak
               AND secret_code = p_secret
               AND is_active
               AND expires_at IS NOT NULL;   -- a permanent grant stays permanent
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success',     true,
        'evidence_id', v_row.id,
        'object_path', v_row.object_path,
        'file_name',   v_row.file_name,
        'mime_type',   v_row.mime_type,
        'size_bytes',  v_row.size_bytes
    );
END;
$$;

COMMENT ON FUNCTION public.evidence_resolve_read IS
  'Evaluates contract_membership() for a read and returns the object path for the '
  'API to sign. A CNAK read refreshes that grant''s expiry — an active relationship '
  'never expires, an abandoned link does.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_mark_deleted — queue, never delete inline
-- ─────────────────────────────────────────────────────────────────────────────
-- A Firebase delete cannot participate in a Postgres transaction. The row is
-- marked and the StorageCleanup sweeper removes the bytes, then the row.

CREATE OR REPLACE FUNCTION public.evidence_mark_deleted(
    p_evidence_id uuid,
    p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_row t_contract_evidence%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM t_contract_evidence WHERE id = p_evidence_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'evidence_not_found');
    END IF;
    IF v_row.owner_tenant_id <> p_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_owner');
    END IF;
    IF v_row.status = 'deleted' THEN
        RETURN jsonb_build_object('success', true, 'already_deleted', true);
    END IF;

    UPDATE t_contract_evidence
       SET status = 'deleted', deleted_at = now()
     WHERE id = p_evidence_id;

    RETURN jsonb_build_object('success', true, 'evidence_id', p_evidence_id,
                              'usage', evidence_usage(p_tenant_id));
END;
$$;

COMMENT ON FUNCTION public.evidence_mark_deleted IS
  'Marks a registry row deleted so the sweeper can reclaim the bytes. Never deletes '
  'the object inline — a Firebase delete cannot roll back with the transaction.';

-- ─────────────────────────────────────────────────────────────────────────────
-- CNAK lifetime and revocation
-- ─────────────────────────────────────────────────────────────────────────────
-- t_contract_access already HAS expires_at and is_active, and
-- validate_contract_access already enforces both — but nothing ever set an
-- expiry, so all 159 live grants are indefinite bearer tokens.
--
-- New grants now get 90 days by default. EXISTING rows are left alone: they
-- keep NULL (permanent) until someone decides to backfill, because expiring
-- live contract-review links retroactively would break real links in flight.

ALTER TABLE public.t_contract_access
    ALTER COLUMN expires_at SET DEFAULT (now() + interval '90 days');

COMMENT ON COLUMN public.t_contract_access.expires_at IS
  'Grant expiry, enforced by validate_contract_access and contract_membership. '
  'Defaults to 90 days from creation; refreshed on each successful CNAK read. '
  'NULL = never expires (all grants created before 2026-09-20).';

CREATE OR REPLACE FUNCTION public.revoke_contract_access(
    p_contract_id uuid,
    p_tenant_id   uuid,
    p_cnak        text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_owner uuid;
    v_n     int;
BEGIN
    SELECT c.tenant_id INTO v_owner FROM t_contracts c WHERE c.id = p_contract_id;
    IF v_owner IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'contract_not_found');
    END IF;
    IF v_owner <> p_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_contract_creator');
    END IF;

    UPDATE t_contract_access
       SET is_active = false, updated_at = now()
     WHERE contract_id = p_contract_id
       AND is_active
       AND (p_cnak IS NULL OR global_access_id = p_cnak);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'revoked', v_n);
END;
$$;

COMMENT ON FUNCTION public.revoke_contract_access IS
  'Turns a CNAK grant off. Only the contract creator may revoke. Revocation takes '
  'effect for files already delivered, because signed URLs are short-lived and no '
  'durable URL was ever handed out.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_pending_path — the owner's own row, at any status
-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_resolve_read deliberately refuses a pending row, so confirm() needs
-- a separate, owner-only way to learn where it reserved the object.

CREATE OR REPLACE FUNCTION public.evidence_pending_path(
    p_evidence_id uuid,
    p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_row t_contract_evidence%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM t_contract_evidence WHERE id = p_evidence_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'evidence_not_found');
    END IF;
    IF v_row.owner_tenant_id <> p_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'reason', 'not_owner');
    END IF;
    RETURN jsonb_build_object('success', true, 'object_path', v_row.object_path,
                              'status', v_row.status, 'mime_type', v_row.mime_type);
END;
$$;

COMMENT ON FUNCTION public.evidence_pending_path IS
  'Owner-only lookup of a reserved object path, at any status. Used by the broker''s '
  'confirm step, which must address a row that is not yet readable.';

-- ─────────────────────────────────────────────────────────────────────────────
-- evidence_list_for_contract — what the buyer and the CNAK holder see
-- ─────────────────────────────────────────────────────────────────────────────
-- One predicate, so the seller, the buyer tenant and a bearer-key holder all
-- get the same list. Never returns object paths: a caller gets ids, and asks
-- for a signed URL one file at a time.

CREATE OR REPLACE FUNCTION public.evidence_list_for_contract(
    p_contract_id uuid,
    p_tenant_id   uuid,
    p_cnak        text,
    p_secret      text,
    p_is_live     boolean
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_rows jsonb;
BEGIN
    IF NOT contract_membership(p_contract_id, p_tenant_id, p_cnak, p_secret) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
    END IF;

    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'created_at'), '[]'::jsonb) INTO v_rows
    FROM (
        SELECT jsonb_build_object(
                 'evidence_id',        e.id,
                 'event_id',           e.event_id,
                 'form_submission_id', e.form_submission_id,
                 'file_name',          e.file_name,
                 'mime_type',          e.mime_type,
                 'size_bytes',         e.size_bytes,
                 'is_compressed',      e.is_compressed,
                 'uploaded_by',        e.uploaded_by,
                 'created_at',         e.created_at,
                 'confirmed_at',       e.confirmed_at
               ) AS x
        FROM t_contract_evidence e
        WHERE e.contract_id = p_contract_id
          AND e.scope  = 'contract'
          AND e.status = 'active'
          AND e.is_live = COALESCE(p_is_live, true)
    ) s;

    RETURN jsonb_build_object('success', true, 'evidence', v_rows,
                              'count', jsonb_array_length(v_rows));
END;
$$;

COMMENT ON FUNCTION public.evidence_list_for_contract IS
  'Evidence on one contract, for anyone the membership predicate allows. Returns ids, '
  'never object paths — a URL is minted per file, per viewer, per request.';

COMMIT;
