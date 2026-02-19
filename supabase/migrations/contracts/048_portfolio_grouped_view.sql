-- ═══════════════════════════════════════════════════════════════════
-- 048_portfolio_grouped_view.sql
-- Implements the p_group_by = 'buyer' branch in get_contracts_list.
-- When group_by is 'buyer', response returns grouped structure:
--   { groups: [...], pagination, filters }
-- Each group: { buyer_name, buyer_company, buyer_id, contracts: [...],
--              group_totals: { contract_count, total_value, total_collected,
--                              avg_health, total_overdue } }
-- Groups sorted by worst avg_health first.
-- Pagination applies to total contracts across all groups.
--
-- FIX: Restores buyer/accessor visibility from migration 043.
--      WHERE now checks tenant_id OR t_contract_access so claimed
--      contracts appear in buyer's expense/vendor view.
-- ═══════════════════════════════════════════════════════════════════

-- Drop both old overloads to avoid PostgREST ambiguity
DROP FUNCTION IF EXISTS get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR, VARCHAR);

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
    p_group_by VARCHAR DEFAULT NULL
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
    v_groups JSONB;
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
    -- Owner OR accessor (buyer who claimed via CNAK)
    -- ═══════════════════════════════════════════
    v_where := format(
        'WHERE c.is_live = %L AND c.is_active = true AND (
            c.tenant_id = %L
            OR EXISTS (
                SELECT 1 FROM t_contract_access ca
                WHERE ca.contract_id = c.id
                  AND ca.accessor_tenant_id = %L
                  AND ca.is_active = true
                  AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
            )
        )',
        p_is_live, p_tenant_id, p_tenant_id
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
    -- STEP 2: Health score expression
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
    -- STEP 5: BRANCH — grouped vs flat
    -- ═══════════════════════════════════════════

    IF p_group_by = 'buyer' THEN
        -- ═══════════════════════════════════════
        -- GROUPED MODE: group by buyer_name
        -- Returns all matching contracts (up to per_page),
        -- organized into groups with per-group totals.
        -- Groups sorted by worst avg_health first.
        -- ═══════════════════════════════════════

        v_query := format(
            'WITH enriched AS (
                SELECT
                    c.*,
                    COALESCE(ev.events_total, 0) AS events_total,
                    COALESCE(ev.events_completed, 0) AS events_completed,
                    COALESCE(ev.events_overdue, 0) AS events_overdue,
                    COALESCE(inv.total_invoiced, 0) AS total_invoiced,
                    COALESCE(inv.total_collected, 0) AS total_collected,
                    COALESCE(inv.outstanding, 0) AS outstanding,
                    ROUND(%s) AS health_score,
                    ROUND(
                        CASE
                            WHEN COALESCE(ev.events_total, 0) > 0 THEN
                                (COALESCE(ev.events_completed, 0)::NUMERIC / ev.events_total * 100)
                            ELSE 0
                        END
                    ) AS completion_pct
                FROM t_contracts c
                LEFT JOIN LATERAL (
                    SELECT
                        COUNT(*) AS events_total,
                        COUNT(*) FILTER (WHERE ce.status = ''completed'') AS events_completed,
                        COUNT(*) FILTER (
                            WHERE ce.status NOT IN (''completed'', ''cancelled'')
                            AND ce.scheduled_date < NOW()
                        ) AS events_overdue
                    FROM t_contract_events ce
                    WHERE ce.contract_id = c.id AND ce.is_active = true AND ce.is_live = %L
                ) ev ON true
                LEFT JOIN LATERAL (
                    SELECT
                        COALESCE(SUM(i.total_amount), 0) AS total_invoiced,
                        COALESCE(SUM(i.amount_paid), 0) AS total_collected,
                        COALESCE(SUM(i.balance), 0) AS outstanding
                    FROM t_invoices i
                    WHERE i.contract_id = c.id AND i.is_active = true AND i.is_live = %L AND i.status != ''cancelled''
                ) inv ON true
                %s
            ),
            group_agg AS (
                SELECT
                    COALESCE(e.buyer_name, ''Unknown'') AS group_buyer_name,
                    COALESCE(e.buyer_company, e.buyer_name, ''Unknown'') AS group_buyer_company,
                    e.buyer_id AS group_buyer_id,
                    COUNT(*) AS group_contract_count,
                    COALESCE(SUM(e.grand_total), 0) AS group_total_value,
                    COALESCE(SUM(e.total_collected), 0) AS group_total_collected,
                    ROUND(AVG(e.health_score)) AS group_avg_health,
                    COALESCE(SUM(e.events_overdue), 0) AS group_total_overdue,
                    jsonb_agg(
                        jsonb_build_object(
                            ''id'', e.id,
                            ''tenant_id'', e.tenant_id,
                            ''contract_number'', e.contract_number,
                            ''rfq_number'', e.rfq_number,
                            ''record_type'', e.record_type,
                            ''contract_type'', e.contract_type,
                            ''name'', e.name,
                            ''description'', e.description,
                            ''status'', e.status,
                            ''buyer_id'', e.buyer_id,
                            ''buyer_name'', e.buyer_name,
                            ''buyer_company'', e.buyer_company,
                            ''acceptance_method'', e.acceptance_method,
                            ''global_access_id'', e.global_access_id,
                            ''duration_value'', e.duration_value,
                            ''duration_unit'', e.duration_unit,
                            ''currency'', e.currency,
                            ''billing_cycle_type'', e.billing_cycle_type,
                            ''total_value'', e.total_value,
                            ''grand_total'', e.grand_total,
                            ''sent_at'', e.sent_at,
                            ''accepted_at'', e.accepted_at,
                            ''version'', e.version,
                            ''created_by'', e.created_by,
                            ''created_at'', e.created_at,
                            ''updated_at'', e.updated_at,
                            ''events_total'', e.events_total,
                            ''events_completed'', e.events_completed,
                            ''events_overdue'', e.events_overdue,
                            ''total_invoiced'', e.total_invoiced,
                            ''total_collected'', e.total_collected,
                            ''outstanding'', e.outstanding,
                            ''health_score'', e.health_score,
                            ''completion_pct'', e.completion_pct
                        )
                        ORDER BY %s
                    ) AS contracts
                FROM enriched e
                GROUP BY e.buyer_id, e.buyer_name, e.buyer_company
            )
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        ''buyer_name'', ga.group_buyer_name,
                        ''buyer_company'', ga.group_buyer_company,
                        ''buyer_id'', ga.group_buyer_id,
                        ''contracts'', ga.contracts,
                        ''group_totals'', jsonb_build_object(
                            ''contract_count'', ga.group_contract_count,
                            ''total_value'', ga.group_total_value,
                            ''total_collected'', ga.group_total_collected,
                            ''avg_health'', ga.group_avg_health,
                            ''total_overdue'', ga.group_total_overdue
                        )
                    )
                    ORDER BY ga.group_avg_health ASC NULLS LAST
                ),
                ''[]''::JSONB
            )
            FROM group_agg ga',
            v_health_expr,    -- health expression in enriched CTE
            p_is_live,        -- events filter
            p_is_live,        -- invoices filter
            v_where,          -- WHERE clause
            v_order           -- ORDER BY within each group's contracts
        );

        EXECUTE v_query INTO v_groups;

        RETURN jsonb_build_object(
            'success', true,
            'groups', COALESCE(v_groups, '[]'::JSONB),
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

    ELSE
        -- ═══════════════════════════════════════
        -- FLAT MODE (default) — same as Cycle 1
        -- ═══════════════════════════════════════

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
                             SELECT COUNT(*) FROM t_contract_blocks cb WHERE cb.contract_id = c.id
                         ),
                         ''vendors_count'', (
                             SELECT COUNT(*) FROM t_contract_vendors cv WHERE cv.contract_id = c.id
                         ),
                         ''events_total'', COALESCE(ev.events_total, 0),
                         ''events_completed'', COALESCE(ev.events_completed, 0),
                         ''events_overdue'', COALESCE(ev.events_overdue, 0),
                         ''total_invoiced'', COALESCE(inv.total_invoiced, 0),
                         ''total_collected'', COALESCE(inv.total_collected, 0),
                         ''outstanding'', COALESCE(inv.outstanding, 0),
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
                 LEFT JOIN LATERAL (
                     SELECT
                         COUNT(*) AS events_total,
                         COUNT(*) FILTER (WHERE ce.status = ''completed'') AS events_completed,
                         COUNT(*) FILTER (
                             WHERE ce.status NOT IN (''completed'', ''cancelled'')
                             AND ce.scheduled_date < NOW()
                         ) AS events_overdue
                     FROM t_contract_events ce
                     WHERE ce.contract_id = c.id AND ce.is_active = true AND ce.is_live = %L
                 ) ev ON true
                 LEFT JOIN LATERAL (
                     SELECT
                         COALESCE(SUM(i.total_amount), 0) AS total_invoiced,
                         COALESCE(SUM(i.amount_paid), 0) AS total_collected,
                         COALESCE(SUM(i.balance), 0) AS outstanding
                     FROM t_invoices i
                     WHERE i.contract_id = c.id AND i.is_active = true AND i.is_live = %L AND i.status != ''cancelled''
                 ) inv ON true
                 %s
                 ORDER BY %s
                 LIMIT %s OFFSET %s
             ) sub',
            v_order,
            v_health_expr,
            p_is_live,
            p_is_live,
            v_where,
            v_order,
            p_per_page,
            v_offset
        );

        EXECUTE v_query INTO v_contracts;

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

    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contracts',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR, VARCHAR) TO service_role;
