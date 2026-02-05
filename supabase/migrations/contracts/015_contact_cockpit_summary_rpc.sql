-- =============================================================
-- CONTACT COCKPIT SUMMARY RPC
-- Migration: contracts/015_contact_cockpit_summary_rpc.sql
--
-- Returns comprehensive dashboard data for a contact:
--   - Contracts by status
--   - Events summary (total, by status, overdue, upcoming)
--   - LTV (lifetime value)
--   - Health score
-- =============================================================

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- get_contact_cockpit_summary
--   Aggregates all cockpit data in a single RPC call.
--   Optimized for dashboard rendering - single round trip.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION get_contact_cockpit_summary(
    p_contact_id    UUID,
    p_tenant_id     UUID,
    p_is_live       BOOLEAN DEFAULT true,
    p_days_ahead    INT DEFAULT 7           -- Default: next 7 days for upcoming events
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contracts_summary     JSONB;
    v_events_summary        JSONB;
    v_overdue_events        JSONB;
    v_upcoming_events       JSONB;
    v_ltv                   NUMERIC;
    v_outstanding           NUMERIC;
    v_health_score          NUMERIC;
    v_total_events          INT;
    v_completed_events      INT;
    v_overdue_count         INT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_contact_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'contact_id is required');
    END IF;
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Contracts Summary by Status
    --   Aggregates contracts where buyer_id = contact_id
    -- ═══════════════════════════════════════════
    SELECT jsonb_build_object(
        'total', COUNT(*),
        'by_status', jsonb_object_agg(
            COALESCE(status, 'unknown'),
            status_count
        ),
        'contracts', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', id,
                'contract_number', contract_number,
                'name', name,
                'status', status,
                'grand_total', grand_total,
                'currency', currency,
                'created_at', created_at,
                'acceptance_method', acceptance_method,
                'duration_value', duration_value,
                'duration_unit', duration_unit
            ) ORDER BY created_at DESC
        ) FILTER (WHERE id IS NOT NULL), '[]'::JSONB)
    )
    INTO v_contracts_summary
    FROM (
        SELECT
            c.id,
            c.contract_number,
            c.name,
            c.status,
            c.grand_total,
            c.currency,
            c.created_at,
            c.acceptance_method,
            c.duration_value,
            c.duration_unit,
            COUNT(*) OVER (PARTITION BY c.status) as status_count
        FROM t_contracts c
        WHERE c.buyer_id = p_contact_id
          AND c.tenant_id = p_tenant_id
          AND c.is_live = p_is_live
          AND c.is_active = true
          AND c.record_type = 'contract'
    ) sub;

    -- Handle NULL case (no contracts)
    IF v_contracts_summary IS NULL THEN
        v_contracts_summary := jsonb_build_object(
            'total', 0,
            'by_status', '{}'::JSONB,
            'contracts', '[]'::JSONB
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Events Summary
    --   Aggregates events from all contracts for this contact
    -- ═══════════════════════════════════════════
    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE status = 'completed'),
        COUNT(*) FILTER (WHERE status != 'completed' AND status != 'cancelled' AND scheduled_date < NOW())
    INTO v_total_events, v_completed_events, v_overdue_count
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    WHERE c.buyer_id = p_contact_id
      AND ce.tenant_id = p_tenant_id
      AND ce.is_live = p_is_live
      AND ce.is_active = true;

    SELECT jsonb_build_object(
        'total', COALESCE(v_total_events, 0),
        'completed', COALESCE(v_completed_events, 0),
        'overdue', COALESCE(v_overdue_count, 0),
        'by_status', COALESCE((
            SELECT jsonb_object_agg(status, cnt)
            FROM (
                SELECT ce.status, COUNT(*) as cnt
                FROM t_contract_events ce
                JOIN t_contracts c ON ce.contract_id = c.id
                WHERE c.buyer_id = p_contact_id
                  AND ce.tenant_id = p_tenant_id
                  AND ce.is_live = p_is_live
                  AND ce.is_active = true
                GROUP BY ce.status
            ) s
        ), '{}'::JSONB),
        'by_type', COALESCE((
            SELECT jsonb_object_agg(event_type, cnt)
            FROM (
                SELECT ce.event_type, COUNT(*) as cnt
                FROM t_contract_events ce
                JOIN t_contracts c ON ce.contract_id = c.id
                WHERE c.buyer_id = p_contact_id
                  AND ce.tenant_id = p_tenant_id
                  AND ce.is_live = p_is_live
                  AND ce.is_active = true
                GROUP BY ce.event_type
            ) s
        ), '{}'::JSONB)
    )
    INTO v_events_summary;

    -- ═══════════════════════════════════════════
    -- STEP 3: Overdue Events (detailed list)
    --   Events where scheduled_date < NOW() and not completed/cancelled
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', ce.id,
            'contract_id', ce.contract_id,
            'contract_number', c.contract_number,
            'contract_name', c.name,
            'event_type', ce.event_type,
            'block_name', ce.block_name,
            'scheduled_date', ce.scheduled_date,
            'days_overdue', EXTRACT(DAY FROM NOW() - ce.scheduled_date)::INT,
            'status', ce.status,
            'amount', ce.amount,
            'currency', ce.currency,
            'assigned_to', ce.assigned_to,
            'assigned_to_name', ce.assigned_to_name
        ) ORDER BY ce.scheduled_date ASC
    ), '[]'::JSONB)
    INTO v_overdue_events
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    WHERE c.buyer_id = p_contact_id
      AND ce.tenant_id = p_tenant_id
      AND ce.is_live = p_is_live
      AND ce.is_active = true
      AND ce.status NOT IN ('completed', 'cancelled')
      AND ce.scheduled_date < NOW();

    -- ═══════════════════════════════════════════
    -- STEP 4: Upcoming Events (next N days)
    --   Events where scheduled_date >= NOW() and <= NOW() + p_days_ahead
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', ce.id,
            'contract_id', ce.contract_id,
            'contract_number', c.contract_number,
            'contract_name', c.name,
            'event_type', ce.event_type,
            'block_name', ce.block_name,
            'scheduled_date', ce.scheduled_date,
            'days_until', EXTRACT(DAY FROM ce.scheduled_date - NOW())::INT,
            'is_today', DATE(ce.scheduled_date) = CURRENT_DATE,
            'status', ce.status,
            'amount', ce.amount,
            'currency', ce.currency,
            'assigned_to', ce.assigned_to,
            'assigned_to_name', ce.assigned_to_name,
            'sequence_number', ce.sequence_number,
            'total_occurrences', ce.total_occurrences
        ) ORDER BY ce.scheduled_date ASC
    ), '[]'::JSONB)
    INTO v_upcoming_events
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    WHERE c.buyer_id = p_contact_id
      AND ce.tenant_id = p_tenant_id
      AND ce.is_live = p_is_live
      AND ce.is_active = true
      AND ce.status NOT IN ('completed', 'cancelled')
      AND ce.scheduled_date >= NOW()
      AND ce.scheduled_date <= NOW() + (p_days_ahead || ' days')::INTERVAL;

    -- ═══════════════════════════════════════════
    -- STEP 5: Calculate LTV (Lifetime Value)
    --   Sum of grand_total from all contracts
    -- ═══════════════════════════════════════════
    SELECT COALESCE(SUM(grand_total), 0)
    INTO v_ltv
    FROM t_contracts
    WHERE buyer_id = p_contact_id
      AND tenant_id = p_tenant_id
      AND is_live = p_is_live
      AND is_active = true
      AND record_type = 'contract';

    -- ═══════════════════════════════════════════
    -- STEP 6: Outstanding Balance (from invoices if table exists)
    --   For now, set to 0 - will integrate with billing later
    -- ═══════════════════════════════════════════
    -- TODO: Integrate with t_invoices when billing module is ready
    v_outstanding := 0;

    -- ═══════════════════════════════════════════
    -- STEP 7: Calculate Health Score
    --   Based on: events completion rate, overdue ratio
    --   Formula: (completed / total) * 100 - (overdue * 10)
    -- ═══════════════════════════════════════════
    IF v_total_events > 0 THEN
        v_health_score := GREATEST(0, LEAST(100,
            (v_completed_events::NUMERIC / v_total_events * 100) - (v_overdue_count * 10)
        ));
    ELSE
        v_health_score := 100; -- No events = healthy (nothing to do)
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 8: Build and return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contact_id', p_contact_id,
            'contracts', v_contracts_summary,
            'events', v_events_summary,
            'overdue_events', v_overdue_events,
            'upcoming_events', v_upcoming_events,
            'ltv', v_ltv,
            'outstanding', v_outstanding,
            'health_score', ROUND(v_health_score, 1),
            'days_ahead', p_days_ahead
        ),
        'generated_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to generate cockpit summary',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contact_cockpit_summary(UUID, UUID, BOOLEAN, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contact_cockpit_summary(UUID, UUID, BOOLEAN, INT) TO service_role;

COMMENT ON FUNCTION get_contact_cockpit_summary IS 'Returns comprehensive dashboard data for a contact including contracts, events, LTV, and health score';
