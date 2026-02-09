-- ============================================================================
-- Migration 018: Event Status Configuration System
-- ============================================================================
-- Purpose: Tenant-overridable status definitions and transition rules
--          per event type (service, spare_part, billing)
--
-- Tables:
--   m_event_status_config      - Status definitions
--   m_event_status_transitions - Valid from->to pairs
--
-- RPCs:
--   get_event_status_config        - Fetch statuses for an event type
--   upsert_event_status_config     - Create/update a status definition
--   delete_event_status_config     - Soft-delete a status
--   get_event_status_transitions   - Fetch transitions for an event type
--   upsert_event_status_transition - Create/update a transition
--   delete_event_status_transition - Remove a transition
--   seed_event_status_defaults     - Seed system defaults for a tenant
-- ============================================================================

-- ============================================================================
-- TABLE: m_event_status_config
-- ============================================================================
CREATE TABLE IF NOT EXISTS m_event_status_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID,                   -- NULL = system default, UUID = tenant override
    event_type      TEXT NOT NULL,           -- e.g. 'service', 'spare_part', 'billing' (open-ended, validated at app layer)
    status_code     TEXT NOT NULL,           -- machine name: 'in_progress', 'payment_pending'
    display_name    TEXT NOT NULL,           -- UI label: 'In Progress', 'Payment Pending'
    description     TEXT,                    -- tooltip/help text
    hex_color       TEXT DEFAULT '#6B7280',  -- badge color
    icon_name       TEXT,                    -- Lucide icon name
    display_order   INT NOT NULL DEFAULT 0,  -- ordering in UI
    is_initial      BOOLEAN DEFAULT false,   -- starting status (one per event_type per tenant)
    is_terminal     BOOLEAN DEFAULT false,   -- no transitions out (completed, cancelled, paid)
    is_active       BOOLEAN DEFAULT true,    -- soft toggle
    source          TEXT DEFAULT 'system',   -- 'system' | 'tenant' | 'vani' (handover-ready)
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now(),

    -- Unique: one status_code per event_type per tenant scope
    CONSTRAINT uq_event_status_tenant UNIQUE (tenant_id, event_type, status_code)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_esc_tenant_type
    ON m_event_status_config (tenant_id, event_type)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_esc_system_defaults
    ON m_event_status_config (event_type)
    WHERE tenant_id IS NULL AND is_active = true;

-- ============================================================================
-- TABLE: m_event_status_transitions
-- ============================================================================
CREATE TABLE IF NOT EXISTS m_event_status_transitions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID,                   -- NULL = system default
    event_type          TEXT NOT NULL,
    from_status         TEXT NOT NULL,
    to_status           TEXT NOT NULL,
    requires_reason     BOOLEAN DEFAULT false,   -- must provide reason for this move
    requires_evidence   BOOLEAN DEFAULT false,   -- handover-ready: VaNi/Cycle 3
    is_active           BOOLEAN DEFAULT true,
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- No duplicate transitions per scope
    CONSTRAINT uq_event_transition_tenant UNIQUE (tenant_id, event_type, from_status, to_status),

    -- Cannot transition to self
    CONSTRAINT chk_no_self_transition CHECK (from_status <> to_status)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_est_lookup
    ON m_event_status_transitions (tenant_id, event_type, from_status)
    WHERE is_active = true;

-- ============================================================================
-- RPC: get_event_status_config
-- Returns tenant-specific statuses if they exist, otherwise system defaults
-- ============================================================================
CREATE OR REPLACE FUNCTION get_event_status_config(
    p_tenant_id UUID,
    p_event_type TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result JSONB;
    v_has_tenant_config BOOLEAN;
BEGIN
    -- Check if tenant has overrides for this event_type
    SELECT EXISTS(
        SELECT 1 FROM m_event_status_config
        WHERE tenant_id = p_tenant_id
          AND event_type = p_event_type
          AND is_active = true
    ) INTO v_has_tenant_config;

    -- Fetch statuses: tenant override if exists, else system defaults
    SELECT jsonb_build_object(
        'success', true,
        'event_type', p_event_type,
        'is_tenant_override', v_has_tenant_config,
        'statuses', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', sc.id,
                'status_code', sc.status_code,
                'display_name', sc.display_name,
                'description', sc.description,
                'hex_color', sc.hex_color,
                'icon_name', sc.icon_name,
                'display_order', sc.display_order,
                'is_initial', sc.is_initial,
                'is_terminal', sc.is_terminal,
                'source', sc.source
            ) ORDER BY sc.display_order
        ), '[]'::jsonb)
    ) INTO v_result
    FROM m_event_status_config sc
    WHERE sc.event_type = p_event_type
      AND sc.is_active = true
      AND sc.tenant_id IS NOT DISTINCT FROM
          CASE WHEN v_has_tenant_config THEN p_tenant_id ELSE NULL END;

    RETURN v_result;
END;
$$;

-- ============================================================================
-- RPC: get_event_status_transitions
-- Returns valid transitions for an event_type (tenant or system defaults)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_event_status_transitions(
    p_tenant_id UUID,
    p_event_type TEXT,
    p_from_status TEXT DEFAULT NULL   -- optional: filter to specific source status
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result JSONB;
    v_has_tenant_config BOOLEAN;
BEGIN
    -- Check tenant overrides
    SELECT EXISTS(
        SELECT 1 FROM m_event_status_transitions
        WHERE tenant_id = p_tenant_id
          AND event_type = p_event_type
          AND is_active = true
    ) INTO v_has_tenant_config;

    SELECT jsonb_build_object(
        'success', true,
        'event_type', p_event_type,
        'is_tenant_override', v_has_tenant_config,
        'transitions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', st.id,
                'from_status', st.from_status,
                'to_status', st.to_status,
                'requires_reason', st.requires_reason,
                'requires_evidence', st.requires_evidence
            )
        ), '[]'::jsonb)
    ) INTO v_result
    FROM m_event_status_transitions st
    WHERE st.event_type = p_event_type
      AND st.is_active = true
      AND st.tenant_id IS NOT DISTINCT FROM
          CASE WHEN v_has_tenant_config THEN p_tenant_id ELSE NULL END
      AND (p_from_status IS NULL OR st.from_status = p_from_status);

    RETURN v_result;
END;
$$;

-- ============================================================================
-- RPC: upsert_event_status_config
-- Create or update a status definition
-- ============================================================================
CREATE OR REPLACE FUNCTION upsert_event_status_config(
    p_tenant_id UUID,
    p_event_type TEXT,
    p_status_code TEXT,
    p_display_name TEXT,
    p_description TEXT DEFAULT NULL,
    p_hex_color TEXT DEFAULT '#6B7280',
    p_icon_name TEXT DEFAULT NULL,
    p_display_order INT DEFAULT 0,
    p_is_initial BOOLEAN DEFAULT false,
    p_is_terminal BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id UUID;
BEGIN
    -- If marking as initial, unset any existing initial for this event_type + tenant
    IF p_is_initial THEN
        UPDATE m_event_status_config
        SET is_initial = false, updated_at = now()
        WHERE tenant_id IS NOT DISTINCT FROM p_tenant_id
          AND event_type = p_event_type
          AND is_initial = true;
    END IF;

    INSERT INTO m_event_status_config (
        tenant_id, event_type, status_code, display_name, description,
        hex_color, icon_name, display_order, is_initial, is_terminal,
        source, updated_at
    ) VALUES (
        p_tenant_id, p_event_type, p_status_code, p_display_name, p_description,
        p_hex_color, p_icon_name, p_display_order, p_is_initial, p_is_terminal,
        CASE WHEN p_tenant_id IS NULL THEN 'system' ELSE 'tenant' END,
        now()
    )
    ON CONFLICT (tenant_id, event_type, status_code)
    DO UPDATE SET
        display_name = EXCLUDED.display_name,
        description = EXCLUDED.description,
        hex_color = EXCLUDED.hex_color,
        icon_name = EXCLUDED.icon_name,
        display_order = EXCLUDED.display_order,
        is_initial = EXCLUDED.is_initial,
        is_terminal = EXCLUDED.is_terminal,
        is_active = true,
        updated_at = now()
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'id', v_id);
END;
$$;

-- ============================================================================
-- RPC: delete_event_status_config
-- Soft-delete a status (set is_active = false)
-- ============================================================================
CREATE OR REPLACE FUNCTION delete_event_status_config(
    p_tenant_id UUID,
    p_event_type TEXT,
    p_status_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count INT;
BEGIN
    -- Cannot delete system defaults (tenant_id IS NULL) via tenant request
    UPDATE m_event_status_config
    SET is_active = false, updated_at = now()
    WHERE tenant_id IS NOT DISTINCT FROM p_tenant_id
      AND event_type = p_event_type
      AND status_code = p_status_code
      AND is_active = true;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Status not found or already deleted');
    END IF;

    -- Also deactivate transitions involving this status
    UPDATE m_event_status_transitions
    SET is_active = false
    WHERE tenant_id IS NOT DISTINCT FROM p_tenant_id
      AND event_type = p_event_type
      AND (from_status = p_status_code OR to_status = p_status_code);

    RETURN jsonb_build_object('success', true, 'deactivated_transitions', v_count);
END;
$$;

-- ============================================================================
-- RPC: upsert_event_status_transition
-- ============================================================================
CREATE OR REPLACE FUNCTION upsert_event_status_transition(
    p_tenant_id UUID,
    p_event_type TEXT,
    p_from_status TEXT,
    p_to_status TEXT,
    p_requires_reason BOOLEAN DEFAULT false,
    p_requires_evidence BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO m_event_status_transitions (
        tenant_id, event_type, from_status, to_status,
        requires_reason, requires_evidence
    ) VALUES (
        p_tenant_id, p_event_type, p_from_status, p_to_status,
        p_requires_reason, p_requires_evidence
    )
    ON CONFLICT (tenant_id, event_type, from_status, to_status)
    DO UPDATE SET
        requires_reason = EXCLUDED.requires_reason,
        requires_evidence = EXCLUDED.requires_evidence,
        is_active = true
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'id', v_id);
END;
$$;

-- ============================================================================
-- RPC: delete_event_status_transition
-- ============================================================================
CREATE OR REPLACE FUNCTION delete_event_status_transition(
    p_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM m_event_status_transitions WHERE id = p_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

-- ============================================================================
-- RPC: seed_event_status_defaults
-- Copies system defaults (tenant_id IS NULL) into tenant-specific rows
-- Called during onboarding or "Reset to Defaults" action
-- ============================================================================
CREATE OR REPLACE FUNCTION seed_event_status_defaults(
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_status_count INT := 0;
    v_transition_count INT := 0;
BEGIN
    -- Insert status definitions (skip if tenant already has overrides)
    INSERT INTO m_event_status_config (
        tenant_id, event_type, status_code, display_name, description,
        hex_color, icon_name, display_order, is_initial, is_terminal, source
    )
    SELECT
        p_tenant_id, event_type, status_code, display_name, description,
        hex_color, icon_name, display_order, is_initial, is_terminal, 'system'
    FROM m_event_status_config
    WHERE tenant_id IS NULL AND is_active = true
    ON CONFLICT (tenant_id, event_type, status_code) DO NOTHING;

    GET DIAGNOSTICS v_status_count = ROW_COUNT;

    -- Insert transitions
    INSERT INTO m_event_status_transitions (
        tenant_id, event_type, from_status, to_status,
        requires_reason, requires_evidence
    )
    SELECT
        p_tenant_id, event_type, from_status, to_status,
        requires_reason, requires_evidence
    FROM m_event_status_transitions
    WHERE tenant_id IS NULL AND is_active = true
    ON CONFLICT (tenant_id, event_type, from_status, to_status) DO NOTHING;

    GET DIAGNOSTICS v_transition_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'statuses_seeded', v_status_count,
        'transitions_seeded', v_transition_count
    );
END;
$$;

-- ============================================================================
-- SEED: System Default Statuses (tenant_id = NULL)
-- ============================================================================

-- ========================
-- SERVICE statuses
-- ========================
INSERT INTO m_event_status_config (tenant_id, event_type, status_code, display_name, description, hex_color, icon_name, display_order, is_initial, is_terminal, source) VALUES
(NULL, 'service', 'scheduled',    'Scheduled',    'Event is planned and awaiting assignment',       '#6B7280', 'Clock',        1, true,  false, 'system'),
(NULL, 'service', 'assigned',     'Assigned',     'Assigned to a team member',                      '#3B82F6', 'UserCheck',    2, false, false, 'system'),
(NULL, 'service', 'in_progress',  'In Progress',  'Work is actively being performed',               '#8B5CF6', 'Play',         3, false, false, 'system'),
(NULL, 'service', 'on_hold',      'On Hold',      'Temporarily paused',                             '#F59E0B', 'Pause',        4, false, false, 'system'),
(NULL, 'service', 'completed',    'Completed',    'Work finished successfully',                     '#10B981', 'CheckCircle',  5, false, true,  'system'),
(NULL, 'service', 'cancelled',    'Cancelled',    'Event was cancelled',                            '#EF4444', 'XCircle',      6, false, true,  'system'),
(NULL, 'service', 'overdue',      'Overdue',      'Past scheduled date without completion',         '#DC2626', 'AlertTriangle',7, false, false, 'system'),
(NULL, 'service', 'reopened',     'Reopened',     'Previously completed, reopened for rework',      '#F97316', 'RotateCcw',    8, false, false, 'system')
ON CONFLICT (tenant_id, event_type, status_code) DO NOTHING;

-- ========================
-- SPARE_PART statuses
-- ========================
INSERT INTO m_event_status_config (tenant_id, event_type, status_code, display_name, description, hex_color, icon_name, display_order, is_initial, is_terminal, source) VALUES
(NULL, 'spare_part', 'scheduled',            'Scheduled',            'Spare part delivery is planned',          '#6B7280', 'Clock',          1, true,  false, 'system'),
(NULL, 'spare_part', 'procurement_pending',  'Procurement Pending',  'Awaiting procurement action',             '#F59E0B', 'ShoppingCart',   2, false, false, 'system'),
(NULL, 'spare_part', 'ordered',              'Ordered',              'Purchase order placed',                   '#3B82F6', 'Package',        3, false, false, 'system'),
(NULL, 'spare_part', 'shipped',              'Shipped',              'Part is in transit',                      '#8B5CF6', 'Truck',          4, false, false, 'system'),
(NULL, 'spare_part', 'delivered',            'Delivered',            'Part received at destination',            '#06B6D4', 'PackageCheck',   5, false, false, 'system'),
(NULL, 'spare_part', 'installed',            'Installed',            'Part installed and verified',             '#10B981', 'CheckCircle',    6, false, true,  'system'),
(NULL, 'spare_part', 'cancelled',            'Cancelled',            'Spare part delivery cancelled',           '#EF4444', 'XCircle',        7, false, true,  'system'),
(NULL, 'spare_part', 'return_requested',     'Return Requested',     'Part return initiated',                   '#F97316', 'RotateCcw',      8, false, false, 'system'),
(NULL, 'spare_part', 'overdue',              'Overdue',              'Past scheduled date without delivery',    '#DC2626', 'AlertTriangle',  9, false, false, 'system')
ON CONFLICT (tenant_id, event_type, status_code) DO NOTHING;

-- ========================
-- BILLING statuses
-- ========================
INSERT INTO m_event_status_config (tenant_id, event_type, status_code, display_name, description, hex_color, icon_name, display_order, is_initial, is_terminal, source) VALUES
(NULL, 'billing', 'scheduled',          'Scheduled',          'Billing event is planned',                  '#6B7280', 'Clock',          1, true,  false, 'system'),
(NULL, 'billing', 'invoice_generated',  'Invoice Generated',  'Invoice has been created',                  '#3B82F6', 'FileText',       2, false, false, 'system'),
(NULL, 'billing', 'sent',               'Sent',               'Invoice sent to customer',                  '#8B5CF6', 'Send',           3, false, false, 'system'),
(NULL, 'billing', 'payment_pending',    'Payment Pending',    'Awaiting payment from customer',            '#F59E0B', 'Clock',          4, false, false, 'system'),
(NULL, 'billing', 'partial_payment',    'Partial Payment',    'Partial amount received',                   '#F97316', 'CircleDot',      5, false, false, 'system'),
(NULL, 'billing', 'paid',               'Paid',               'Full payment received',                     '#10B981', 'CheckCircle',    6, false, true,  'system'),
(NULL, 'billing', 'overdue',            'Overdue',            'Payment past due date',                     '#DC2626', 'AlertTriangle',  7, false, false, 'system'),
(NULL, 'billing', 'waived',             'Waived',             'Payment requirement waived',                '#6B7280', 'MinusCircle',    8, false, true,  'system'),
(NULL, 'billing', 'cancelled',          'Cancelled',          'Billing event cancelled',                   '#EF4444', 'XCircle',        9, false, true,  'system')
ON CONFLICT (tenant_id, event_type, status_code) DO NOTHING;

-- ============================================================================
-- SEED: System Default Transitions (tenant_id = NULL)
-- ============================================================================

-- ========================
-- SERVICE transitions
-- ========================
INSERT INTO m_event_status_transitions (tenant_id, event_type, from_status, to_status, requires_reason) VALUES
-- Forward flow
(NULL, 'service', 'scheduled',   'assigned',     false),
(NULL, 'service', 'assigned',    'in_progress',  false),
(NULL, 'service', 'in_progress', 'completed',    false),
-- Hold
(NULL, 'service', 'assigned',    'on_hold',      true),
(NULL, 'service', 'in_progress', 'on_hold',      true),
(NULL, 'service', 'on_hold',     'assigned',     false),
-- Cancel (from non-terminal)
(NULL, 'service', 'scheduled',   'cancelled',    true),
(NULL, 'service', 'assigned',    'cancelled',    true),
(NULL, 'service', 'in_progress', 'cancelled',    true),
(NULL, 'service', 'on_hold',     'cancelled',    true),
-- Overdue recovery
(NULL, 'service', 'overdue',     'in_progress',  false),
(NULL, 'service', 'overdue',     'cancelled',    true),
-- Reopen
(NULL, 'service', 'completed',   'reopened',     true),
(NULL, 'service', 'reopened',    'in_progress',  false)
ON CONFLICT (tenant_id, event_type, from_status, to_status) DO NOTHING;

-- ========================
-- SPARE_PART transitions
-- ========================
INSERT INTO m_event_status_transitions (tenant_id, event_type, from_status, to_status, requires_reason) VALUES
-- Forward flow
(NULL, 'spare_part', 'scheduled',            'procurement_pending', false),
(NULL, 'spare_part', 'procurement_pending',  'ordered',             false),
(NULL, 'spare_part', 'ordered',              'shipped',             false),
(NULL, 'spare_part', 'shipped',              'delivered',           false),
(NULL, 'spare_part', 'delivered',            'installed',           false),
-- Return
(NULL, 'spare_part', 'installed',            'return_requested',    true),
(NULL, 'spare_part', 'delivered',            'return_requested',    true),
-- Cancel (from non-terminal)
(NULL, 'spare_part', 'scheduled',            'cancelled',           true),
(NULL, 'spare_part', 'procurement_pending',  'cancelled',           true),
(NULL, 'spare_part', 'ordered',              'cancelled',           true),
-- Overdue recovery
(NULL, 'spare_part', 'overdue',              'procurement_pending', false),
(NULL, 'spare_part', 'overdue',              'cancelled',           true)
ON CONFLICT (tenant_id, event_type, from_status, to_status) DO NOTHING;

-- ========================
-- BILLING transitions
-- ========================
INSERT INTO m_event_status_transitions (tenant_id, event_type, from_status, to_status, requires_reason) VALUES
-- Forward flow
(NULL, 'billing', 'scheduled',         'invoice_generated',  false),
(NULL, 'billing', 'invoice_generated', 'sent',               false),
(NULL, 'billing', 'sent',              'payment_pending',    false),
(NULL, 'billing', 'payment_pending',   'paid',               false),
(NULL, 'billing', 'payment_pending',   'partial_payment',    false),
(NULL, 'billing', 'partial_payment',   'paid',               false),
-- Overdue
(NULL, 'billing', 'overdue',           'payment_pending',    false),
(NULL, 'billing', 'overdue',           'waived',             true),
(NULL, 'billing', 'overdue',           'cancelled',          true),
-- Cancel (from non-terminal)
(NULL, 'billing', 'scheduled',         'cancelled',          true),
(NULL, 'billing', 'invoice_generated', 'cancelled',          true),
(NULL, 'billing', 'payment_pending',   'waived',             true)
ON CONFLICT (tenant_id, event_type, from_status, to_status) DO NOTHING;
