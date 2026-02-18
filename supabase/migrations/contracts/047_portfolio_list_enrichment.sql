-- ═══════════════════════════════════════════════════════════════════
-- 047_portfolio_list_enrichment.sql
-- Extends get_contracts_list with per-row event/invoice summaries
-- and health_score for the Contract Portfolio list view.
-- Also extends get_contract_stats with portfolio-level aggregates.
--
-- Health formula (same as cockpit):
--   (completed / total * 100) - (overdue * 10), clamped 0-100
--   Defaults to 100 when no events exist.
--
-- New sort options: 'health_score', 'completion'
-- New param: p_group_by (reserved for Cycle 3)
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. REPLACE get_contracts_list with enriched version
--    Adds: events_total, events_completed, events_overdue,
--          total_invoiced, total_collected, outstanding,
--          health_score, completion_pct
--    New sort: health_score, completion
--    New param: p_group_by (no-op for now, wired for Cycle 3)
-- ─────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR);

CREATE OR REPLACE FUNCTION get_contracts_list(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true,
    p_record_type VARCHAR DEFAULT NULL,
    p_contract_type VARCHAR DEFAULT NULL,
    p_status VARCHAR DEFAULT NULL,
    p_search VARCHAR DEFAULT NULL,
    p_page INTEGER DEFAULT 1,
    p_per_page INTEGER DEFAULT 20,
    p_sort_by VARCHAR DEFAULT 'created_at',
    p_sort_order VARCHAR DEFAULT 'desc',
    p_group_by VARCHAR DEFAULT NULL          -- 'buyer' | NULL (reserved for Cycle 3)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total INTEGER;
    v_total_pages INTEGER;
    v_offset INTEGER;
    v_contracts JSONB;
    v_query TEXT;
    v_count_query TEXT;
    v_where TEXT := '';
    v_order TEXT;
    v_health_expr TEXT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- Clamp pagination
    p_page := GREATEST(p_page, 1);
    p_per_page := LEAST(GREATEST(p_per_page, 1), 100);
    v_offset := (p_page - 1) * p_per_page;

    -- ═══════════════════════════════════════════
    -- STEP 1: Build WHERE clause
    -- ═══════════════════════════════════════════
    v_where := format(
        'WHERE c.tenant_id = %L AND c.is_live = %L AND c.is_active = true',
        p_tenant_id, p_is_live
    );

    IF p_record_type IS NOT NULL THEN
        v_where := v_where || format(' AND c.record_type = %L', p_record_type);
    END IF;

    IF p_contract_type IS NOT NULL THEN
        v_where := v_where || format(' AND c.contract_type = %L', p_contract_type);
    END IF;

    IF p_status IS NOT NULL THEN
        v_where := v_where || format(' AND c.status = %L', p_status);
    END IF;

    IF p_search IS NOT NULL AND TRIM(p_search) <> '' THEN
        v_where := v_where || format(
            ' AND (c.name ILIKE %L OR c.contract_number ILIKE %L OR c.rfq_number ILIKE %L OR c.buyer_name ILIKE %L)',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Health score expression (reusable)
    -- Same formula as cockpit RPC:
    --   IF events_total > 0: (completed / total * 100) - (overdue * 10)
    --   ELSE: 100
    -- ═══════════════════════════════════════════
    v_health_expr := '
        CASE
            WHEN COALESCE(ev.events_total, 0) > 0 THEN
                GREATEST(0, LEAST(100,
                    (COALESCE(ev.events_completed, 0)::NUMERIC / ev.events_total * 100)
                    - (COALESCE(ev.events_overdue, 0) * 10)
                ))
            ELSE 100
        END';

    -- ═══════════════════════════════════════════
    -- STEP 3: Build ORDER BY
    -- Extended with health_score and completion
    -- ═══════════════════════════════════════════
    v_order := CASE p_sort_by
        WHEN 'name' THEN 'c.name'
        WHEN 'status' THEN 'c.status'
        WHEN 'total_value' THEN 'c.total_value'
        WHEN 'grand_total' THEN 'c.grand_total'
        WHEN 'health_score' THEN '(' || v_health_expr || ')'
        WHEN 'completion' THEN '
            CASE
                WHEN COALESCE(ev.events_total, 0) > 0 THEN
                    (COALESCE(ev.events_completed, 0)::NUMERIC / ev.events_total * 100)
                ELSE 100
            END'
        ELSE 'c.created_at'
    END;

    v_order := v_order || CASE WHEN LOWER(p_sort_order) = 'asc' THEN ' ASC' ELSE ' DESC' END;

    -- ═══════════════════════════════════════════
    -- STEP 4: Get total count
    -- ═══════════════════════════════════════════
    v_count_query := 'SELECT COUNT(*) FROM t_contracts c ' || v_where;
    EXECUTE v_count_query INTO v_total;

    v_total_pages := CEIL(v_total::NUMERIC / p_per_page);

    -- ═══════════════════════════════════════════
    -- STEP 5: Fetch paginated contracts with
    --         enriched event + invoice data
    -- ═══════════════════════════════════════════
    v_query := format(
        'SELECT COALESCE(jsonb_agg(row_data ORDER BY rn), ''[]''::JSONB)
         FROM (
             SELECT
                 ROW_NUMBER() OVER (ORDER BY %s) as rn,
                 jsonb_build_object(
                     ''id'', c.id,
                     ''tenant_id'', c.tenant_id,
                     ''contract_number'', c.contract_number,
                     ''rfq_number'', c.rfq_number,
                     ''record_type'', c.record_type,
                     ''contract_type'', c.contract_type,
                     ''name'', c.name,
                     ''description'', c.description,
                     ''status'', c.status,
                     ''buyer_id'', c.buyer_id,
                     ''buyer_name'', c.buyer_name,
                     ''buyer_company'', c.buyer_company,
                     ''acceptance_method'', c.acceptance_method,
                     ''global_access_id'', c.global_access_id,
                     ''duration_value'', c.duration_value,
                     ''duration_unit'', c.duration_unit,
                     ''currency'', c.currency,
                     ''billing_cycle_type'', c.billing_cycle_type,
                     ''total_value'', c.total_value,
                     ''grand_total'', c.grand_total,
                     ''sent_at'', c.sent_at,
                     ''accepted_at'', c.accepted_at,
                     ''version'', c.version,
                     ''created_by'', c.created_by,
                     ''created_at'', c.created_at,
                     ''updated_at'', c.updated_at,
                     ''blocks_count'', (
                         SELECT COUNT(*)
                         FROM t_contract_blocks cb
                         WHERE cb.contract_id = c.id
                     ),
                     ''vendors_count'', (
                         SELECT COUNT(*)
                         FROM t_contract_vendors cv
                         WHERE cv.contract_id = c.id
                     ),
                     -- ═══ NEW: Event summary per contract ═══
                     ''events_total'', COALESCE(ev.events_total, 0),
                     ''events_completed'', COALESCE(ev.events_completed, 0),
                     ''events_overdue'', COALESCE(ev.events_overdue, 0),
                     -- ═══ NEW: Invoice summary per contract ═══
                     ''total_invoiced'', COALESCE(inv.total_invoiced, 0),
                     ''total_collected'', COALESCE(inv.total_collected, 0),
                     ''outstanding'', COALESCE(inv.outstanding, 0),
                     -- ═══ NEW: Computed health & completion ═══
                     ''health_score'', ROUND(%s),
                     ''completion_pct'', ROUND(
                         CASE
                             WHEN COALESCE(ev.events_total, 0) > 0 THEN
                                 (COALESCE(ev.events_completed, 0)::NUMERIC / ev.events_total * 100)
                             ELSE 0
                         END
                     )
                 ) AS row_data
             FROM t_contracts c
             -- ═══ LEFT JOIN: Event counts per contract ═══
             LEFT JOIN LATERAL (
                 SELECT
                     COUNT(*) AS events_total,
                     COUNT(*) FILTER (WHERE ce.status = ''completed'') AS events_completed,
                     COUNT(*) FILTER (
                         WHERE ce.status NOT IN (''completed'', ''cancelled'')
                         AND ce.scheduled_date < NOW()
                     ) AS events_overdue
                 FROM t_contract_events ce
                 WHERE ce.contract_id = c.id
                   AND ce.is_active = true
                   AND ce.is_live = %L
             ) ev ON true
             -- ═══ LEFT JOIN: Invoice totals per contract ═══
             LEFT JOIN LATERAL (
                 SELECT
                     COALESCE(SUM(i.total_amount), 0) AS total_invoiced,
                     COALESCE(SUM(i.amount_paid), 0) AS total_collected,
                     COALESCE(SUM(i.balance), 0) AS outstanding
                 FROM t_invoices i
                 WHERE i.contract_id = c.id
                   AND i.is_active = true
                   AND i.is_live = %L
                   AND i.status != ''cancelled''
             ) inv ON true
             %s
             ORDER BY %s
             LIMIT %s OFFSET %s
         ) sub',
        v_order,                -- ROW_NUMBER() ORDER BY
        v_health_expr,          -- health_score expression
        p_is_live,              -- events is_live filter
        p_is_live,              -- invoices is_live filter
        v_where,                -- WHERE clause
        v_order,                -- main ORDER BY
        p_per_page,
        v_offset
    );

    EXECUTE v_query INTO v_contracts;

    -- ═══════════════════════════════════════════
    -- STEP 6: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', COALESCE(v_contracts, '[]'::JSONB),
        'pagination', jsonb_build_object(
            'page', p_page,
            'per_page', p_per_page,
            'total', v_total,
            'total_pages', v_total_pages
        ),
        'filters', jsonb_build_object(
            'record_type', p_record_type,
            'contract_type', p_contract_type,
            'status', p_status,
            'search', p_search,
            'sort_by', p_sort_by,
            'sort_order', p_sort_order,
            'group_by', p_group_by
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contracts',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

-- Grant same permissions as the original
GRANT EXECUTE ON FUNCTION get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR, VARCHAR) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 2. REPLACE get_contract_stats with portfolio-enriched version
--    Adds: total_overdue_events, total_invoiced, total_collected,
--          avg_health_score, needs_attention_count
-- ─────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_contract_stats(UUID, BOOLEAN);

CREATE OR REPLACE FUNCTION get_contract_stats(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_by_status JSONB;
    v_by_record_type JSONB;
    v_by_contract_type JSONB;
    v_totals RECORD;
    -- Portfolio aggregates
    v_total_overdue_events INTEGER;
    v_total_invoiced NUMERIC;
    v_total_collected NUMERIC;
    v_avg_health NUMERIC;
    v_needs_attention INTEGER;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Counts by status (unchanged)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_object_agg(status, cnt),
        '{}'::JSONB
    )
    INTO v_by_status
    FROM (
        SELECT status, COUNT(*) AS cnt
        FROM t_contracts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND is_active = true
        GROUP BY status
    ) sub;

    -- ═══════════════════════════════════════════
    -- STEP 2: Counts by record_type (unchanged)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_object_agg(record_type, cnt),
        '{}'::JSONB
    )
    INTO v_by_record_type
    FROM (
        SELECT record_type, COUNT(*) AS cnt
        FROM t_contracts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND is_active = true
        GROUP BY record_type
    ) sub;

    -- ═══════════════════════════════════════════
    -- STEP 3: Counts by contract_type (unchanged)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_object_agg(contract_type, cnt),
        '{}'::JSONB
    )
    INTO v_by_contract_type
    FROM (
        SELECT contract_type, COUNT(*) AS cnt
        FROM t_contracts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND is_active = true
        GROUP BY contract_type
    ) sub;

    -- ═══════════════════════════════════════════
    -- STEP 4: Financial totals (unchanged)
    -- ═══════════════════════════════════════════
    SELECT
        COUNT(*) AS total_count,
        COALESCE(SUM(total_value), 0) AS sum_total_value,
        COALESCE(SUM(grand_total), 0) AS sum_grand_total,
        COALESCE(SUM(CASE WHEN status = 'active' THEN grand_total ELSE 0 END), 0) AS active_value,
        COALESCE(SUM(CASE WHEN status = 'draft' THEN grand_total ELSE 0 END), 0) AS draft_value
    INTO v_totals
    FROM t_contracts
    WHERE tenant_id = p_tenant_id
      AND is_live = p_is_live
      AND is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 5 (NEW): Portfolio aggregates
    -- ═══════════════════════════════════════════

    -- 5a. Total overdue events across all contracts
    SELECT COUNT(*)
    INTO v_total_overdue_events
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    WHERE c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND ce.is_active = true
      AND ce.is_live = p_is_live
      AND ce.status NOT IN ('completed', 'cancelled')
      AND ce.scheduled_date < NOW();

    -- 5b. Total invoiced and collected across all contracts
    SELECT
        COALESCE(SUM(i.total_amount), 0),
        COALESCE(SUM(i.amount_paid), 0)
    INTO v_total_invoiced, v_total_collected
    FROM t_invoices i
    JOIN t_contracts c ON i.contract_id = c.id
    WHERE c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND i.is_active = true
      AND i.is_live = p_is_live
      AND i.status != 'cancelled';

    -- 5c. Average health score across all contracts (with events)
    SELECT COALESCE(ROUND(AVG(health)), 0)
    INTO v_avg_health
    FROM (
        SELECT
            GREATEST(0, LEAST(100,
                (COUNT(*) FILTER (WHERE ce.status = 'completed')::NUMERIC
                 / NULLIF(COUNT(*), 0) * 100)
                - (COUNT(*) FILTER (
                    WHERE ce.status NOT IN ('completed', 'cancelled')
                    AND ce.scheduled_date < NOW()
                   ) * 10)
            )) AS health
        FROM t_contract_events ce
        JOIN t_contracts c ON ce.contract_id = c.id
        WHERE c.tenant_id = p_tenant_id
          AND c.is_live = p_is_live
          AND c.is_active = true
          AND ce.is_active = true
          AND ce.is_live = p_is_live
        GROUP BY c.id
        HAVING COUNT(*) > 0
    ) sub;

    -- 5d. Contracts that need attention (health < 50 OR has overdue events)
    SELECT COUNT(DISTINCT c.id)
    INTO v_needs_attention
    FROM t_contracts c
    LEFT JOIN LATERAL (
        SELECT
            COUNT(*) AS total_ev,
            COUNT(*) FILTER (WHERE ce.status = 'completed') AS completed_ev,
            COUNT(*) FILTER (
                WHERE ce.status NOT IN ('completed', 'cancelled')
                AND ce.scheduled_date < NOW()
            ) AS overdue_ev
        FROM t_contract_events ce
        WHERE ce.contract_id = c.id
          AND ce.is_active = true
          AND ce.is_live = p_is_live
    ) ev ON true
    WHERE c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND (
          -- Has overdue events
          COALESCE(ev.overdue_ev, 0) > 0
          OR (
              -- Health < 50 (only for contracts with events)
              COALESCE(ev.total_ev, 0) > 0
              AND GREATEST(0, LEAST(100,
                  (COALESCE(ev.completed_ev, 0)::NUMERIC / ev.total_ev * 100)
                  - (COALESCE(ev.overdue_ev, 0) * 10)
              )) < 50
          )
      );

    -- ═══════════════════════════════════════════
    -- STEP 6: Return response (extended)
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'total_count', v_totals.total_count,
            'by_status', v_by_status,
            'by_record_type', v_by_record_type,
            'by_contract_type', v_by_contract_type,
            'financials', jsonb_build_object(
                'total_value', v_totals.sum_total_value,
                'grand_total', v_totals.sum_grand_total,
                'active_value', v_totals.active_value,
                'draft_value', v_totals.draft_value
            ),
            -- ═══ NEW: Portfolio aggregates ═══
            'portfolio', jsonb_build_object(
                'total_overdue_events', COALESCE(v_total_overdue_events, 0),
                'total_invoiced', COALESCE(v_total_invoiced, 0),
                'total_collected', COALESCE(v_total_collected, 0),
                'outstanding', COALESCE(v_total_invoiced - v_total_collected, 0),
                'avg_health_score', COALESCE(v_avg_health, 0),
                'needs_attention_count', COALESCE(v_needs_attention, 0)
            )
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contract stats',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_stats(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_stats(UUID, BOOLEAN) TO service_role;
