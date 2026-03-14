-- =============================================================
-- Migration 054: end_date, prolongation columns + auto-expire job
-- =============================================================
-- Purpose:
--   1. Add end_date (computed from start_date + duration) as stored column
--   2. Add prolongation_value, prolongation_unit, prolongation_date columns
--   3. Backfill end_date for existing contracts
--   4. Update create_contract_transaction to compute end_date on insert
--   5. Create auto_expire_contracts() RPC for nightly cron
--   6. Schedule pg_cron job at 11:59 PM IST (18:29 UTC) daily
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. Add new columns to t_contracts
-- ─────────────────────────────────────────────────────────────

ALTER TABLE t_contracts
ADD COLUMN IF NOT EXISTS end_date TIMESTAMPTZ;

ALTER TABLE t_contracts
ADD COLUMN IF NOT EXISTS prolongation_value INTEGER DEFAULT 0;

ALTER TABLE t_contracts
ADD COLUMN IF NOT EXISTS prolongation_unit VARCHAR(20) DEFAULT 'days';

ALTER TABLE t_contracts
ADD COLUMN IF NOT EXISTS prolongation_date TIMESTAMPTZ;

COMMENT ON COLUMN t_contracts.end_date IS 'Computed: start_date + duration_value duration_unit. Stored for query performance.';
COMMENT ON COLUMN t_contracts.prolongation_value IS 'Extension period value (e.g., 30)';
COMMENT ON COLUMN t_contracts.prolongation_unit IS 'Extension period unit (days, weeks, months, years)';
COMMENT ON COLUMN t_contracts.prolongation_date IS 'Computed: end_date + prolongation_value prolongation_unit. The actual final date of the contract.';


-- ─────────────────────────────────────────────────────────────
-- 2. Helper: compute end_date from start_date + duration
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION compute_contract_end_date(
    p_start_date TIMESTAMPTZ,
    p_duration_value INTEGER,
    p_duration_unit VARCHAR
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_start_date IS NULL OR p_duration_value IS NULL OR p_duration_value <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN CASE p_duration_unit
        WHEN 'days'   THEN p_start_date + (p_duration_value || ' days')::INTERVAL
        WHEN 'weeks'  THEN p_start_date + (p_duration_value || ' weeks')::INTERVAL
        WHEN 'months' THEN p_start_date + (p_duration_value || ' months')::INTERVAL
        WHEN 'years'  THEN p_start_date + (p_duration_value || ' years')::INTERVAL
        ELSE p_start_date + (p_duration_value || ' months')::INTERVAL  -- default to months
    END;
END;
$$;

CREATE OR REPLACE FUNCTION compute_contract_prolongation_date(
    p_end_date TIMESTAMPTZ,
    p_prolongation_value INTEGER,
    p_prolongation_unit VARCHAR
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_end_date IS NULL OR p_prolongation_value IS NULL OR p_prolongation_value <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN CASE p_prolongation_unit
        WHEN 'days'   THEN p_end_date + (p_prolongation_value || ' days')::INTERVAL
        WHEN 'weeks'  THEN p_end_date + (p_prolongation_value || ' weeks')::INTERVAL
        WHEN 'months' THEN p_end_date + (p_prolongation_value || ' months')::INTERVAL
        WHEN 'years'  THEN p_end_date + (p_prolongation_value || ' years')::INTERVAL
        ELSE p_end_date + (p_prolongation_value || ' days')::INTERVAL  -- default to days
    END;
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3. Backfill end_date for existing contracts
-- ─────────────────────────────────────────────────────────────

UPDATE t_contracts
SET end_date = compute_contract_end_date(start_date, duration_value, duration_unit)
WHERE end_date IS NULL
  AND start_date IS NOT NULL
  AND duration_value IS NOT NULL
  AND duration_value > 0;


-- ─────────────────────────────────────────────────────────────
-- 4. Index for the nightly auto-expire query
-- ─────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_contracts_active_end_date
ON t_contracts (end_date)
WHERE status = 'active' AND is_active = true AND end_date IS NOT NULL;


-- ─────────────────────────────────────────────────────────────
-- 5. Trigger: auto-compute end_date on INSERT/UPDATE
--    Keeps end_date and prolongation_date in sync whenever
--    start_date, duration, or prolongation fields change.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_compute_contract_dates()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Compute end_date if inputs are available
    IF NEW.start_date IS NOT NULL AND NEW.duration_value IS NOT NULL AND NEW.duration_value > 0 THEN
        NEW.end_date := compute_contract_end_date(NEW.start_date, NEW.duration_value, NEW.duration_unit);
    END IF;

    -- Compute prolongation_date if prolongation is set
    IF NEW.end_date IS NOT NULL AND NEW.prolongation_value IS NOT NULL AND NEW.prolongation_value > 0 THEN
        NEW.prolongation_date := compute_contract_prolongation_date(NEW.end_date, NEW.prolongation_value, NEW.prolongation_unit);
    ELSE
        NEW.prolongation_date := NULL;
    END IF;

    RETURN NEW;
END;
$$;

-- Drop if exists to avoid duplicate
DROP TRIGGER IF EXISTS trg_contracts_compute_dates ON t_contracts;

CREATE TRIGGER trg_contracts_compute_dates
BEFORE INSERT OR UPDATE OF start_date, duration_value, duration_unit, prolongation_value, prolongation_unit
ON t_contracts
FOR EACH ROW
EXECUTE FUNCTION trg_compute_contract_dates();


-- ─────────────────────────────────────────────────────────────
-- 6. RPC: auto_expire_contracts()
--    Called by nightly cron job.
--    Finds active contracts past their effective end date
--    and transitions them to 'expired'.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION auto_expire_contracts()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_expired_count INTEGER := 0;
    v_contract RECORD;
    v_effective_end TIMESTAMPTZ;
BEGIN
    -- Find all active contracts past their effective end date
    FOR v_contract IN
        SELECT id, tenant_id, name, status, end_date, prolongation_date,
               version, global_access_id
        FROM t_contracts
        WHERE status = 'active'
          AND is_active = true
          AND end_date IS NOT NULL
          AND COALESCE(prolongation_date, end_date) < NOW()
        ORDER BY end_date ASC
        FOR UPDATE SKIP LOCKED  -- Skip locked rows to avoid contention
    LOOP
        v_effective_end := COALESCE(v_contract.prolongation_date, v_contract.end_date);

        -- Update status to expired
        UPDATE t_contracts
        SET status       = 'expired',
            completed_at = NOW(),
            version      = version + 1,
            updated_by   = '00000000-0000-0000-0000-000000000000'::UUID  -- system user
        WHERE id = v_contract.id
          AND tenant_id = v_contract.tenant_id;

        -- Record in contract history
        INSERT INTO t_contract_history (
            contract_id, tenant_id,
            action, from_status, to_status,
            changes,
            performed_by_type, performed_by_id, performed_by_name,
            note
        )
        VALUES (
            v_contract.id, v_contract.tenant_id,
            'status_changed',
            'active',
            'expired',
            jsonb_build_object(
                'trigger', 'auto_expire_cron',
                'effective_end_date', v_effective_end,
                'had_prolongation', v_contract.prolongation_date IS NOT NULL
            ),
            'system',
            '00000000-0000-0000-0000-000000000000'::UUID,
            'System Auto-Expire',
            format('Contract auto-expired. Effective end date: %s', v_effective_end::DATE)
        );

        v_expired_count := v_expired_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'expired_count', v_expired_count,
        'run_at', NOW()
    );
END;
$$;

-- Grant to service_role only (cron job uses service_role)
GRANT EXECUTE ON FUNCTION auto_expire_contracts() TO service_role;

COMMENT ON FUNCTION auto_expire_contracts IS 'Nightly cron: auto-expires active contracts past their end_date/prolongation_date. Logs to contract history with system performer.';


-- ─────────────────────────────────────────────────────────────
-- 7. pg_cron job: run at 11:59 PM IST (18:29 UTC) daily
-- ─────────────────────────────────────────────────────────────

-- Helper function to invoke auto_expire via pg_net (same pattern as JTD worker)
CREATE OR REPLACE FUNCTION invoke_auto_expire_contracts()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_url TEXT;
    v_service_key TEXT;
BEGIN
    -- Get secrets from vault (same pattern as invoke_jtd_worker)
    SELECT decrypted_secret INTO v_url
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_URL'
    LIMIT 1;

    SELECT decrypted_secret INTO v_service_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY'
    LIMIT 1;

    IF v_url IS NULL OR v_service_key IS NULL THEN
        RAISE WARNING 'auto_expire: Missing vault secrets (SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY)';
        RETURN;
    END IF;

    -- Call the edge function endpoint
    PERFORM net.http_post(
        url := v_url || '/rest/v1/rpc/auto_expire_contracts',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'apikey', v_service_key,
            'Authorization', 'Bearer ' || v_service_key
        ),
        body := '{}'::JSONB
    );
END;
$$;

-- Schedule the cron job (11:59 PM IST = 18:29 UTC)
SELECT cron.schedule(
    'auto-expire-contracts-nightly',
    '29 18 * * *',
    $$SELECT invoke_auto_expire_contracts()$$
);

COMMENT ON FUNCTION invoke_auto_expire_contracts IS 'pg_cron helper: invokes auto_expire_contracts() via pg_net HTTP call using vault secrets.';
