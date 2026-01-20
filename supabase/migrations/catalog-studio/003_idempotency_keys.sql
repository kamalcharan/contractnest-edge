-- ============================================================================
-- Catalog Studio - Idempotency Keys Table
-- Migration: 003_idempotency_keys.sql
-- Purpose: Store idempotency keys to prevent duplicate requests
-- ============================================================================

-- Create idempotency keys table
CREATE TABLE IF NOT EXISTS t_idempotency_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Key identification
    idempotency_key VARCHAR(255) NOT NULL,
    tenant_id UUID NOT NULL,

    -- Request context
    endpoint VARCHAR(255) NOT NULL,           -- e.g., 'cat-blocks', 'cat-templates'
    method VARCHAR(10) NOT NULL,              -- POST, PATCH, DELETE
    request_hash VARCHAR(64),                 -- SHA-256 hash of request body

    -- Response caching
    response_status INTEGER NOT NULL,         -- HTTP status code
    response_body JSONB NOT NULL,             -- Full response for replay

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),

    -- Unique constraint on key + tenant + endpoint
    CONSTRAINT uq_idempotency_key_tenant_endpoint
        UNIQUE (idempotency_key, tenant_id, endpoint)
);

-- Index for lookup performance
CREATE INDEX IF NOT EXISTS idx_idempotency_key_lookup
ON t_idempotency_keys (idempotency_key, tenant_id, endpoint);

-- Index for cleanup job
CREATE INDEX IF NOT EXISTS idx_idempotency_expires_at
ON t_idempotency_keys (expires_at);

-- ============================================================================
-- RPC Function: Check and return existing idempotent response
-- ============================================================================
CREATE OR REPLACE FUNCTION check_idempotency(
    p_idempotency_key VARCHAR(255),
    p_tenant_id UUID,
    p_endpoint VARCHAR(255)
)
RETURNS TABLE (
    found BOOLEAN,
    response_status INTEGER,
    response_body JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        TRUE AS found,
        ik.response_status,
        ik.response_body
    FROM t_idempotency_keys ik
    WHERE ik.idempotency_key = p_idempotency_key
      AND ik.tenant_id = p_tenant_id
      AND ik.endpoint = p_endpoint
      AND ik.expires_at > NOW()
    LIMIT 1;

    -- If no rows returned, return not found
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::JSONB;
    END IF;
END;
$$;

-- ============================================================================
-- RPC Function: Store idempotent response
-- ============================================================================
CREATE OR REPLACE FUNCTION store_idempotency(
    p_idempotency_key VARCHAR(255),
    p_tenant_id UUID,
    p_endpoint VARCHAR(255),
    p_method VARCHAR(10),
    p_request_hash VARCHAR(64),
    p_response_status INTEGER,
    p_response_body JSONB,
    p_ttl_hours INTEGER DEFAULT 24
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO t_idempotency_keys (
        idempotency_key,
        tenant_id,
        endpoint,
        method,
        request_hash,
        response_status,
        response_body,
        expires_at
    ) VALUES (
        p_idempotency_key,
        p_tenant_id,
        p_endpoint,
        p_method,
        p_request_hash,
        p_response_status,
        p_response_body,
        NOW() + (p_ttl_hours || ' hours')::INTERVAL
    )
    ON CONFLICT (idempotency_key, tenant_id, endpoint)
    DO UPDATE SET
        response_status = EXCLUDED.response_status,
        response_body = EXCLUDED.response_body,
        expires_at = EXCLUDED.expires_at;
END;
$$;

-- ============================================================================
-- RPC Function: Cleanup expired idempotency keys
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_expired_idempotency_keys()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM t_idempotency_keys
    WHERE expires_at < NOW();

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

-- ============================================================================
-- Comments
-- ============================================================================
COMMENT ON TABLE t_idempotency_keys IS 'Stores idempotency keys for edge functions to prevent duplicate request processing';
COMMENT ON COLUMN t_idempotency_keys.idempotency_key IS 'Client-provided unique key for the request';
COMMENT ON COLUMN t_idempotency_keys.request_hash IS 'SHA-256 hash of request body for verification';
COMMENT ON COLUMN t_idempotency_keys.response_body IS 'Cached response to return on duplicate requests';
COMMENT ON COLUMN t_idempotency_keys.expires_at IS 'When this idempotency record expires (default 24h)';
