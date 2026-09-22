-- 004_storage_cleanup.sql
-- Evidence Storage Redesign — batch G: StorageCleanup
--
-- Closes the loop. Rows are marked 'deleted' by a replaced identity asset
-- (003), by a user removing a file, by a test reset or by a tenant closing —
-- and until now nothing collected them. This is the collector.
--
-- WHY THE API RUNS IT, NOT THE JTD WORKER
-- The plan was a `system` channel on the worker. Implementation found the
-- edge runtime holds no Firebase service account — only the API does — so the
-- worker could not delete an object itself, only call the API to do it. That
-- hop buys nothing for a daily idempotent sweep, so the API runs the sweep and
-- the database keeps what it is good at: the work queue, the locking and the
-- record. The JTD row is still written, so a run is visible in history exactly
-- as an owner asked for.
--
--   API (every 30 min) → storage_cleanup_due()
--                      → storage_cleanup_claim()   locks + returns object paths
--                      → Firebase Admin delete     the only place bytes go
--                      → storage_cleanup_settle()  removes the settled rows
--                      → storage_cleanup_record()  one n_jtd row per run
--
-- Nothing here deletes an object. Postgres cannot, and a Firebase delete
-- cannot roll back with a transaction — which is the whole reason for the
-- mark-then-sweep split.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. JTD vocabulary for a job that executes instead of sending
-- ─────────────────────────────────────────────────────────────────────────────
-- category is NOT NULL; the existing vocabulary is action / communication /
-- scheduling. A maintenance job is an action, not a message.
INSERT INTO public.n_jtd_event_types (code, name, category, description, is_active)
VALUES ('system_job', 'System Job', 'action', 'Maintenance work the platform performs on itself. Carries no recipient and no template.', true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.n_jtd_channels (code, name, description, is_active)
VALUES ('system', 'System', 'Executed by the platform, never delivered to anyone. Exempt from credits, templates and the test-environment guard.', true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.n_jtd_source_types (code, name, description, is_active)
VALUES ('storage_cleanup', 'Storage Cleanup', 'Reclaims Firebase objects whose registry row was marked deleted, and orphans from uploads that never confirmed.', true)
ON CONFLICT (code) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. What is reclaimable
-- ─────────────────────────────────────────────────────────────────────────────
-- Two kinds, and both are safe to remove:
--   status='deleted'  the row was retired on purpose — a replaced avatar, a
--                     removed file, a test reset, a closed tenant.
--   status='pending'  a slot was reserved and the upload never confirmed.
--                     Aged, because a slow phone on a bad line may still be
--                     mid-PUT; 24h is far beyond the 10-minute signed url.
--
-- An 'active' row is NEVER touched. That is the whole safety property: the
-- sweeper can only remove what something else already decided was dead.

CREATE OR REPLACE FUNCTION public.storage_cleanup_claim(
    p_limit        int DEFAULT 200,
    p_orphan_hours int DEFAULT 24
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_rows jsonb;
BEGIN
    -- NO LOCK, deliberately. An advisory lock was tried first and removed: it
    -- is session-scoped and re-entrant, so a pooled connection can take it
    -- twice while a single unlock releases it once — leaking the lock and
    -- blocking every future sweep. That failure is worse than the one it
    -- prevents.
    --
    -- The sweep does not need a lock because every step is idempotent:
    --   · deleting an object that is already gone succeeds (ignoreNotFound)
    --   · settle removes only the ids it was handed, so a second sweeper
    --     removing the same ids deletes 0 rows and reports 0
    --   · an 'active' row can never be claimed, and never settled even if named
    -- Two sweepers racing therefore duplicate work and change nothing else.
    SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_rows
    FROM (
        SELECT jsonb_build_object(
                 'evidence_id', e.id,
                 'tenant_id',   e.owner_tenant_id,
                 'object_path', e.object_path,
                 'size_bytes',  e.size_bytes,
                 'reason',      CASE WHEN e.status = 'deleted' THEN 'retired' ELSE 'orphan' END
               ) AS x
        FROM t_contract_evidence e
        WHERE e.status = 'deleted'
           OR (e.status = 'pending' AND e.created_at < now() - make_interval(hours => p_orphan_hours))
        ORDER BY e.deleted_at NULLS LAST, e.created_at
        LIMIT GREATEST(p_limit, 1)
    ) s;

    RETURN jsonb_build_object('success', true,
                              'items', v_rows, 'count', jsonb_array_length(v_rows));
END;
$$;

COMMENT ON FUNCTION public.storage_cleanup_claim IS
  'Object paths the sweeper may reclaim: rows already marked deleted, plus pending rows whose upload never confirmed. Never returns an active row. Unlocked by design - every step of the sweep is idempotent, so a race duplicates work and nothing else.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Settling — the row goes only after the bytes are gone
-- ─────────────────────────────────────────────────────────────────────────────
-- The registry is the only index of what Firebase holds, so a row is removed
-- only once its object is confirmed gone. A path that failed to delete keeps
-- its row and is retried on the next run — losing the row would strand the
-- bytes forever with nothing pointing at them.

CREATE OR REPLACE FUNCTION public.storage_cleanup_settle(
    p_done   uuid[],
    p_failed uuid[] DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_removed int := 0;
BEGIN
    IF p_done IS NOT NULL AND array_length(p_done, 1) > 0 THEN
        DELETE FROM t_contract_evidence
         WHERE id = ANY(p_done)
           AND status IN ('deleted', 'pending');   -- never an active row
        GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object('success', true, 'removed', v_removed,
                              'retained', COALESCE(array_length(p_failed, 1), 0));
END;
$$;

COMMENT ON FUNCTION public.storage_cleanup_settle IS
  'Removes registry rows whose objects were reclaimed, and leaves failed paths in place so the next run retries them. Never removes an active row, even if one is named.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The record — one n_jtd row per run
-- ─────────────────────────────────────────────────────────────────────────────
-- Inserted at 'completed', NEVER at 'created': the BEFORE INSERT trigger
-- enqueues anything created, and the worker would then look for a template
-- that does not exist and dead-letter it.

CREATE OR REPLACE FUNCTION public.storage_cleanup_record(
    p_tenant_id uuid,
    p_counts    jsonb,
    p_is_live   boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code,
        status_code, performed_by_type, is_live,
        executed_at, completed_at, business_context, payload
    ) VALUES (
        p_tenant_id, 'system_job', 'system', 'storage_cleanup',
        'completed', 'system', COALESCE(p_is_live, true),
        now(), now(),
        COALESCE(p_counts, '{}'::jsonb),
        jsonb_build_object('job', 'storage_cleanup')
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.storage_cleanup_record IS
  'Writes the history row for one sweep. Inserted at completed, never created — the enqueue trigger would otherwise queue it as a message with no template.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Is a sweep due?
-- ─────────────────────────────────────────────────────────────────────────────
-- The API asks this on a short timer rather than holding a daily schedule in
-- memory, so a restart or a redeploy cannot silently skip a day.

CREATE OR REPLACE FUNCTION public.storage_cleanup_due(p_min_hours int DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_last   timestamptz;
    v_wait   bigint;
    v_orphan bigint;
BEGIN
    SELECT max(completed_at) INTO v_last
    FROM n_jtd WHERE source_type_code = 'storage_cleanup';

    SELECT count(*) FILTER (WHERE status = 'deleted'),
           count(*) FILTER (WHERE status = 'pending' AND created_at < now() - interval '24 hours')
      INTO v_wait, v_orphan
    FROM t_contract_evidence;

    RETURN jsonb_build_object(
        'due',       (v_last IS NULL OR v_last < now() - make_interval(hours => p_min_hours))
                     AND (v_wait + v_orphan) > 0,
        'last_run',  v_last,
        'retired_waiting', v_wait,
        'orphans_waiting', v_orphan
    );
END;
$$;

COMMENT ON FUNCTION public.storage_cleanup_due IS
  'Whether a sweep is worth running: enough time has passed AND there is something to collect. Asked on a short timer so a restart cannot skip a day.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Test reset must free real space
-- ─────────────────────────────────────────────────────────────────────────────
-- "Space is space" — one quota across live and test. Clearing test data has to
-- give the bytes back, and until now every reset deleted rows and orphaned its
-- objects forever. This marks them instead, so the sweeper reclaims them.

CREATE OR REPLACE FUNCTION public.storage_cleanup_mark_environment(
    p_tenant_id uuid,
    p_is_live   boolean
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_marked int;
BEGIN
    UPDATE t_contract_evidence
       SET status = 'deleted', deleted_at = now()
     WHERE owner_tenant_id = p_tenant_id
       AND is_live = p_is_live
       AND status IN ('active', 'pending');
    GET DIAGNOSTICS v_marked = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'marked', v_marked);
END;
$$;

COMMENT ON FUNCTION public.storage_cleanup_mark_environment IS
  'Marks every file a tenant holds in one environment for reclamation. Called by the test-data reset so clearing test data actually frees the quota.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Tenant close
-- ─────────────────────────────────────────────────────────────────────────────
-- Identity assets go immediately — they are the tenant's own and nobody else's.
-- Contract evidence is NOT swept here: it is the shared artefact, and the
-- counterparty may still need it. That decision belongs to a retention pass
-- that reads t_tenants.evidence_retention_days and checks whether the other
-- party is still an active tenant, which is its own piece of work.

CREATE OR REPLACE FUNCTION public.storage_cleanup_mark_tenant_closed(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_marked int;
BEGIN
    UPDATE t_contract_evidence
       SET status = 'deleted', deleted_at = now()
     WHERE owner_tenant_id = p_tenant_id
       AND scope = 'tenant'
       AND status IN ('active', 'pending');
    GET DIAGNOSTICS v_marked = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'identity_assets_marked', v_marked,
                              'note', 'contract evidence left for the retention pass');
END;
$$;

COMMENT ON FUNCTION public.storage_cleanup_mark_tenant_closed IS
  'On tenant close, marks the tenants own identity assets for reclamation. Contract evidence is deliberately left: it is shared with a counterparty who may still need it, and retention is decided separately.';

COMMIT;
