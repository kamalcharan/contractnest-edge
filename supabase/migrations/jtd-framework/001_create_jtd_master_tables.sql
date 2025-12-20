-- ============================================================
-- Migration: 001_create_jtd_master_tables
-- Description: Create JTD (Jobs To Do) framework master tables
-- Author: Claude
-- Date: 2025-12-17
-- Updated: Added is_live, audit fields (created_by, updated_by), is_active for soft delete
-- ============================================================

-- ============================================================
-- OVERVIEW
-- ============================================================
-- JTD is the core event/task framework for ContractNest.
-- It handles notifications, appointments, tasks, service visits, etc.
-- VaNi (AI Agent) executes JTD jobs automatically when enabled.
--
-- Key Design Decisions:
--   - is_live: Separates test mode (false) from production (true)
--   - is_active: Soft delete for master data
--   - Audit fields: created_by, created_at, updated_by, updated_at on ALL tables
--   - Status history: n_jtd_status_history for detailed status audit trail
--
-- Tables created:
--   1. n_system_actors           - System users (VaNi, System, Webhook)
--   2. n_jtd_event_types         - Master event types
--   3. n_jtd_channels            - Communication channels
--   4. n_jtd_statuses            - Status definitions (per event type)
--   5. n_jtd_status_flows        - Valid status transitions
--   6. n_jtd_source_types        - Event triggers/sources
--   7. n_jtd_tenant_config       - Per-tenant settings
--   8. n_jtd_tenant_source_config- Per-tenant source overrides
--   9. n_jtd_templates           - Message templates
--  10. n_jtd                     - Main JTD records
--  11. n_jtd_status_history      - Status change audit trail
--  12. n_jtd_history             - General audit trail
-- ============================================================

-- ============================================================
-- 1. SYSTEM ACTORS
-- Purpose: Well-known system users (VaNi, System, Webhook)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_system_actors (
    id              UUID PRIMARY KEY,
    code            VARCHAR(50) UNIQUE NOT NULL,
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    avatar_url      TEXT,

    -- Soft delete
    is_active       BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID
);

COMMENT ON TABLE public.n_system_actors IS 'System actors like VaNi (AI Agent), System, Webhook';
COMMENT ON COLUMN public.n_system_actors.code IS 'Unique code: vani, system, webhook';

-- ============================================================
-- 2. EVENT TYPES
-- Purpose: Master list of event types (notification, appointment, task, etc.)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_event_types (
    code                VARCHAR(50) PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,
    description         TEXT,
    category            VARCHAR(50) NOT NULL,
    icon                VARCHAR(50),
    color               VARCHAR(20),

    -- Behavior settings
    allowed_channels    TEXT[] DEFAULT '{}',
    supports_scheduling BOOLEAN DEFAULT false,
    supports_recurrence BOOLEAN DEFAULT false,
    supports_batch      BOOLEAN DEFAULT false,

    -- Payload schema (JSON Schema for validation)
    payload_schema      JSONB,

    -- Default settings
    default_priority    INT DEFAULT 5,
    default_max_retries INT DEFAULT 3,
    retry_delay_seconds INT DEFAULT 300,

    display_order       INT DEFAULT 0,

    -- Soft delete
    is_active           BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by          UUID,
    updated_by          UUID
);

COMMENT ON TABLE public.n_jtd_event_types IS 'Master list of JTD event types';
COMMENT ON COLUMN public.n_jtd_event_types.category IS 'Category: communication, scheduling, action';
COMMENT ON COLUMN public.n_jtd_event_types.allowed_channels IS 'Channels allowed for this event type';

-- ============================================================
-- 3. CHANNELS
-- Purpose: Communication channels (email, sms, whatsapp, push, inapp)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_channels (
    code                    VARCHAR(20) PRIMARY KEY,
    name                    VARCHAR(50) NOT NULL,
    description             TEXT,
    icon                    VARCHAR(50),
    color                   VARCHAR(20),

    -- Provider info
    default_provider        VARCHAR(50),

    -- Cost & limits
    default_cost_per_unit   DECIMAL(10,4) DEFAULT 0,
    rate_limit_per_minute   INT DEFAULT 100,

    -- Capabilities
    supports_templates      BOOLEAN DEFAULT true,
    supports_attachments    BOOLEAN DEFAULT false,
    supports_rich_content   BOOLEAN DEFAULT false,
    max_content_length      INT,

    -- Delivery tracking
    has_delivery_confirmation BOOLEAN DEFAULT true,
    has_read_receipt        BOOLEAN DEFAULT false,

    display_order           INT DEFAULT 0,

    -- Soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID
);

COMMENT ON TABLE public.n_jtd_channels IS 'Communication channels: email, sms, whatsapp, push, inapp';
COMMENT ON COLUMN public.n_jtd_channels.default_provider IS 'Default provider: msg91, sendgrid, gupshup, firebase';

-- ============================================================
-- 4. STATUSES
-- Purpose: Status definitions per event type
-- Note: Different event types have different valid statuses
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_statuses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Link to event type (NULL = global status usable by all)
    event_type_code VARCHAR(50) REFERENCES public.n_jtd_event_types(code),

    code            VARCHAR(30) NOT NULL,
    name            VARCHAR(50) NOT NULL,
    description     TEXT,

    -- Status classification
    status_type     VARCHAR(20) NOT NULL,

    -- UI properties
    icon            VARCHAR(50),
    color           VARCHAR(20),

    -- Behavior flags
    is_initial      BOOLEAN DEFAULT false,
    is_terminal     BOOLEAN DEFAULT false,
    is_success      BOOLEAN DEFAULT false,
    is_failure      BOOLEAN DEFAULT false,
    allows_retry    BOOLEAN DEFAULT false,

    display_order   INT DEFAULT 0,

    -- Soft delete
    is_active       BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID,

    -- Unique constraint: status code unique per event type
    CONSTRAINT uq_status_per_event_type UNIQUE(event_type_code, code)
);

COMMENT ON TABLE public.n_jtd_statuses IS 'Status definitions for JTD workflow (per event type)';
COMMENT ON COLUMN public.n_jtd_statuses.event_type_code IS 'NULL = global status, otherwise specific to event type';
COMMENT ON COLUMN public.n_jtd_statuses.status_type IS 'Type: initial, progress, success, failure, terminal';
COMMENT ON COLUMN public.n_jtd_statuses.is_terminal IS 'True if no further transitions allowed';
COMMENT ON COLUMN public.n_jtd_statuses.allows_retry IS 'True if retry is allowed from this status';
COMMENT ON COLUMN public.n_jtd_statuses.is_active IS 'Soft delete flag';

-- Index for status lookup
CREATE INDEX IF NOT EXISTS idx_statuses_event_type
    ON public.n_jtd_statuses(event_type_code, is_active);

-- ============================================================
-- 5. STATUS FLOWS
-- Purpose: Valid status transitions per event type (soft enforcement)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_status_flows (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type_code VARCHAR(50) NOT NULL REFERENCES public.n_jtd_event_types(code) ON DELETE CASCADE,
    from_status_id  UUID NOT NULL REFERENCES public.n_jtd_statuses(id),
    to_status_id    UUID NOT NULL REFERENCES public.n_jtd_statuses(id),

    -- Transition rules
    is_automatic    BOOLEAN DEFAULT false,
    requires_reason BOOLEAN DEFAULT false,

    -- Soft delete
    is_active       BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT uq_status_flow UNIQUE(event_type_code, from_status_id, to_status_id)
);

COMMENT ON TABLE public.n_jtd_status_flows IS 'Valid status transitions per event type';
COMMENT ON COLUMN public.n_jtd_status_flows.is_automatic IS 'True if system can auto-transition';

-- ============================================================
-- 6. SOURCE TYPES
-- Purpose: What triggers JTD creation (user_invite, contract_created, etc.)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_source_types (
    code                VARCHAR(50) PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,
    description         TEXT,

    -- Mapping to event type
    default_event_type  VARCHAR(50) REFERENCES public.n_jtd_event_types(code),

    -- Source reference
    source_table        VARCHAR(100),
    source_id_field     VARCHAR(100) DEFAULT 'id',

    -- Default channels for this source
    default_channels    TEXT[] DEFAULT '{}',

    -- Payload mapping (how to extract payload from source)
    payload_mapping     JSONB,

    -- Soft delete
    is_active           BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by          UUID,
    updated_by          UUID
);

COMMENT ON TABLE public.n_jtd_source_types IS 'What triggers JTD creation';
COMMENT ON COLUMN public.n_jtd_source_types.source_table IS 'Source table name: t_user_invitations, t_contracts';
COMMENT ON COLUMN public.n_jtd_source_types.payload_mapping IS 'JSON mapping to extract payload from source record';

-- ============================================================
-- 7. TENANT CONFIG
-- Purpose: Per-tenant JTD and VaNi settings
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_tenant_config (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL,

    -- VaNi settings
    vani_enabled            BOOLEAN DEFAULT false,
    vani_auto_execute_types TEXT[] DEFAULT '{}',

    -- Global channel settings
    channels_enabled        JSONB DEFAULT '{
        "email": true,
        "sms": false,
        "whatsapp": false,
        "push": false,
        "inapp": true
    }',

    -- Provider credentials (store reference, not actual creds)
    provider_config_refs    JSONB DEFAULT '{}',

    -- Limits
    daily_limit             INT,
    monthly_limit           INT,
    daily_used              INT DEFAULT 0,
    monthly_used            INT DEFAULT 0,
    last_reset_date         DATE DEFAULT CURRENT_DATE,

    -- Preferences
    default_priority        INT DEFAULT 5,
    timezone                VARCHAR(50) DEFAULT 'UTC',
    quiet_hours_start       TIME,
    quiet_hours_end         TIME,

    -- Environment (test/live mode)
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT uq_tenant_config UNIQUE(tenant_id, is_live)
);

COMMENT ON TABLE public.n_jtd_tenant_config IS 'Per-tenant JTD configuration';
COMMENT ON COLUMN public.n_jtd_tenant_config.vani_enabled IS 'Whether VaNi AI agent is enabled for this tenant';
COMMENT ON COLUMN public.n_jtd_tenant_config.vani_auto_execute_types IS 'Event types VaNi can auto-execute';
COMMENT ON COLUMN public.n_jtd_tenant_config.quiet_hours_start IS 'Start of quiet hours (no notifications)';
COMMENT ON COLUMN public.n_jtd_tenant_config.is_live IS 'true=production mode, false=test mode';

-- ============================================================
-- 8. TENANT SOURCE CONFIG
-- Purpose: Per-tenant, per-source type overrides
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_tenant_source_config (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL,
    source_type_code        VARCHAR(50) NOT NULL REFERENCES public.n_jtd_source_types(code),

    -- Override channels for this source
    channels_enabled        TEXT[],

    -- Override templates
    templates               JSONB DEFAULT '{}',

    -- Behavior
    is_enabled              BOOLEAN DEFAULT true,
    auto_execute            BOOLEAN DEFAULT false,
    priority_override       INT,

    -- Scheduling
    delay_seconds           INT DEFAULT 0,
    batch_window_seconds    INT,

    -- Environment (test/live mode)
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT uq_tenant_source_config UNIQUE(tenant_id, source_type_code, is_live)
);

COMMENT ON TABLE public.n_jtd_tenant_source_config IS 'Per-tenant overrides for each source type';
COMMENT ON COLUMN public.n_jtd_tenant_source_config.auto_execute IS 'VaNi auto-executes this source type';
COMMENT ON COLUMN public.n_jtd_tenant_source_config.delay_seconds IS 'Delay before execution (for batching)';

-- ============================================================
-- 9. TEMPLATES
-- Purpose: Message templates for different channels
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_templates (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID,

    template_key            VARCHAR(100) NOT NULL,
    name                    VARCHAR(200) NOT NULL,
    description             TEXT,

    -- Channel & type
    channel_code            VARCHAR(20) NOT NULL REFERENCES public.n_jtd_channels(code),
    source_type_code        VARCHAR(50) REFERENCES public.n_jtd_source_types(code),

    -- Content
    subject                 VARCHAR(500),
    content                 TEXT NOT NULL,
    content_html            TEXT,

    -- Variables definition
    variables               JSONB DEFAULT '[]',

    -- Provider-specific
    provider_template_id    VARCHAR(100),

    version                 INT DEFAULT 1,

    -- Environment (test/live mode) - NULL for system templates
    is_live                 BOOLEAN,

    -- Soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT uq_template UNIQUE(tenant_id, template_key, channel_code, is_live)
);

COMMENT ON TABLE public.n_jtd_templates IS 'Message templates for JTD notifications';
COMMENT ON COLUMN public.n_jtd_templates.tenant_id IS 'NULL for system templates, tenant_id for custom';
COMMENT ON COLUMN public.n_jtd_templates.variables IS 'Array of {name, type, required, default}';
COMMENT ON COLUMN public.n_jtd_templates.provider_template_id IS 'External template ID (MSG91, etc.)';

-- Index for template lookup
CREATE INDEX IF NOT EXISTS idx_templates_lookup
    ON public.n_jtd_templates(channel_code, source_type_code, is_active);

-- ============================================================
-- 10. MAIN JTD TABLE
-- Purpose: Core Jobs To Do records
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL,
    jtd_number              VARCHAR(30),

    -- Event classification
    event_type_code         VARCHAR(50) NOT NULL REFERENCES public.n_jtd_event_types(code),
    channel_code            VARCHAR(20) REFERENCES public.n_jtd_channels(code),

    -- Source (what triggered this)
    source_type_code        VARCHAR(50) NOT NULL REFERENCES public.n_jtd_source_types(code),
    source_id               UUID,
    source_ref              VARCHAR(255),

    -- Recipient (who this is for)
    recipient_type          VARCHAR(50),
    recipient_id            UUID,
    recipient_name          VARCHAR(255),
    recipient_contact       VARCHAR(255),

    -- Scheduling
    scheduled_at            TIMESTAMP WITH TIME ZONE,
    executed_at             TIMESTAMP WITH TIME ZONE,
    completed_at            TIMESTAMP WITH TIME ZONE,

    -- Status (reference to n_jtd_statuses)
    status_id               UUID REFERENCES public.n_jtd_statuses(id),
    status_code             VARCHAR(30) NOT NULL DEFAULT 'created',
    previous_status_code    VARCHAR(30),
    status_changed_at       TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_valid_transition     BOOLEAN DEFAULT true,
    transition_note         TEXT,

    -- Priority & retries
    priority                INT DEFAULT 5,
    retry_count             INT DEFAULT 0,
    max_retries             INT DEFAULT 3,
    last_retry_at           TIMESTAMP WITH TIME ZONE,
    next_retry_at           TIMESTAMP WITH TIME ZONE,

    -- Payload & template
    payload                 JSONB NOT NULL DEFAULT '{}',
    template_id             UUID REFERENCES public.n_jtd_templates(id),
    template_key            VARCHAR(100),
    template_variables      JSONB DEFAULT '{}',

    -- Execution result
    execution_result        JSONB,
    error_message           TEXT,
    error_code              VARCHAR(50),

    -- Provider tracking
    provider_code           VARCHAR(50),
    provider_message_id     VARCHAR(255),
    provider_response       JSONB,

    -- Cost
    cost                    DECIMAL(10,4) DEFAULT 0,

    -- Business context
    business_context        JSONB DEFAULT '{}',

    -- Actor (who performed this)
    performed_by_type       VARCHAR(20) NOT NULL DEFAULT 'user',
    performed_by_id         UUID,
    performed_by_name       VARCHAR(255),

    -- Metadata
    metadata                JSONB DEFAULT '{}',
    tags                    TEXT[] DEFAULT '{}',

    -- Environment (test/live mode)
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Timestamps & Audit
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    -- Soft constraint for performer validation
    CONSTRAINT chk_performer CHECK (
        (performed_by_type = 'user' AND performed_by_id IS NOT NULL) OR
        (performed_by_type IN ('vani', 'system', 'webhook'))
    )
);

COMMENT ON TABLE public.n_jtd IS 'Main Jobs To Do table - core of JTD framework';
COMMENT ON COLUMN public.n_jtd.performed_by_type IS 'Actor type: user, vani, system, webhook';
COMMENT ON COLUMN public.n_jtd.is_valid_transition IS 'False if status transition violated flow (soft enforcement)';
COMMENT ON COLUMN public.n_jtd.business_context IS 'Linked business data: contract_id, service_number, amount, etc.';
COMMENT ON COLUMN public.n_jtd.is_live IS 'true=production mode, false=test mode';

-- ============================================================
-- 11. STATUS HISTORY (Dedicated audit for status changes)
-- Purpose: Track every status change with full details
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_status_history (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    jtd_id                  UUID NOT NULL REFERENCES public.n_jtd(id) ON DELETE CASCADE,

    -- Status change details
    from_status_id          UUID REFERENCES public.n_jtd_statuses(id),
    from_status_code        VARCHAR(30),
    to_status_id            UUID REFERENCES public.n_jtd_statuses(id),
    to_status_code          VARCHAR(30) NOT NULL,

    -- Transition validation
    is_valid_transition     BOOLEAN DEFAULT true,
    transition_note         TEXT,

    -- Actor who made the change
    performed_by_type       VARCHAR(20) NOT NULL,
    performed_by_id         UUID,
    performed_by_name       VARCHAR(255),

    -- Additional context
    reason                  TEXT,
    details                 JSONB DEFAULT '{}',

    -- When the status was active (for duration tracking)
    status_started_at       TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    status_ended_at         TIMESTAMP WITH TIME ZONE,
    duration_seconds        INT,

    -- Environment
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Timestamp
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID
);

COMMENT ON TABLE public.n_jtd_status_history IS 'Audit trail for every JTD status change';
COMMENT ON COLUMN public.n_jtd_status_history.duration_seconds IS 'How long the JTD was in the previous status';
COMMENT ON COLUMN public.n_jtd_status_history.status_started_at IS 'When this status became active';
COMMENT ON COLUMN public.n_jtd_status_history.status_ended_at IS 'When this status ended (filled on next change)';

-- ============================================================
-- 12. GENERAL HISTORY (Other changes)
-- Purpose: Audit trail for non-status changes
-- ============================================================
CREATE TABLE IF NOT EXISTS public.n_jtd_history (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    jtd_id                  UUID NOT NULL REFERENCES public.n_jtd(id) ON DELETE CASCADE,

    -- Change info
    action                  VARCHAR(30) NOT NULL,

    -- Actor
    performed_by_type       VARCHAR(20) NOT NULL,
    performed_by_id         UUID,
    performed_by_name       VARCHAR(255),

    -- Change details
    field_name              VARCHAR(100),
    old_value               TEXT,
    new_value               TEXT,
    details                 JSONB DEFAULT '{}',
    note                    TEXT,

    -- Environment
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Timestamp
    created_at              TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by              UUID
);

COMMENT ON TABLE public.n_jtd_history IS 'General audit trail for JTD changes (non-status)';
COMMENT ON COLUMN public.n_jtd_history.action IS 'Action: created, updated, retry, cancelled, etc.';

-- ============================================================
-- INDEXES FOR n_jtd
-- ============================================================

-- Primary lookup indexes
CREATE INDEX IF NOT EXISTS idx_jtd_tenant_status
    ON public.n_jtd(tenant_id, status_code, is_live);

CREATE INDEX IF NOT EXISTS idx_jtd_tenant_event_type
    ON public.n_jtd(tenant_id, event_type_code, is_live);

CREATE INDEX IF NOT EXISTS idx_jtd_tenant_created
    ON public.n_jtd(tenant_id, created_at DESC, is_live);

-- Source lookup
CREATE INDEX IF NOT EXISTS idx_jtd_source
    ON public.n_jtd(source_type_code, source_id);

-- Scheduling indexes
CREATE INDEX IF NOT EXISTS idx_jtd_scheduled
    ON public.n_jtd(scheduled_at)
    WHERE status_code IN ('created', 'pending', 'scheduled');

CREATE INDEX IF NOT EXISTS idx_jtd_retry
    ON public.n_jtd(next_retry_at)
    WHERE status_code = 'failed' AND retry_count < max_retries;

-- Provider tracking
CREATE INDEX IF NOT EXISTS idx_jtd_provider
    ON public.n_jtd(provider_code, provider_message_id)
    WHERE provider_message_id IS NOT NULL;

-- Recipient lookup
CREATE INDEX IF NOT EXISTS idx_jtd_recipient
    ON public.n_jtd(recipient_id)
    WHERE recipient_id IS NOT NULL;

-- Performer lookup
CREATE INDEX IF NOT EXISTS idx_jtd_performer
    ON public.n_jtd(performed_by_type, performed_by_id);

-- Environment filter
CREATE INDEX IF NOT EXISTS idx_jtd_is_live
    ON public.n_jtd(is_live);

-- ============================================================
-- INDEXES FOR HISTORY TABLES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_jtd_status_history_jtd
    ON public.n_jtd_status_history(jtd_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_jtd_status_history_status
    ON public.n_jtd_status_history(to_status_code, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_jtd_history_jtd
    ON public.n_jtd_history(jtd_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_jtd_history_action
    ON public.n_jtd_history(action, created_at DESC);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

-- Enable RLS on main tables
ALTER TABLE public.n_jtd ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_tenant_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_tenant_source_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n_jtd_templates ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- TRIGGERS FOR updated_at
-- ============================================================

-- Function for updated_at trigger
CREATE OR REPLACE FUNCTION public.jtd_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to tables with updated_at
DO $$
BEGIN
    -- n_jtd
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_updated_at') THEN
        CREATE TRIGGER trg_jtd_updated_at
            BEFORE UPDATE ON public.n_jtd
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_tenant_config
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_tenant_config_updated_at') THEN
        CREATE TRIGGER trg_jtd_tenant_config_updated_at
            BEFORE UPDATE ON public.n_jtd_tenant_config
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_tenant_source_config
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_tenant_source_config_updated_at') THEN
        CREATE TRIGGER trg_jtd_tenant_source_config_updated_at
            BEFORE UPDATE ON public.n_jtd_tenant_source_config
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_templates
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_templates_updated_at') THEN
        CREATE TRIGGER trg_jtd_templates_updated_at
            BEFORE UPDATE ON public.n_jtd_templates
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_event_types
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_event_types_updated_at') THEN
        CREATE TRIGGER trg_jtd_event_types_updated_at
            BEFORE UPDATE ON public.n_jtd_event_types
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_channels
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_channels_updated_at') THEN
        CREATE TRIGGER trg_jtd_channels_updated_at
            BEFORE UPDATE ON public.n_jtd_channels
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_statuses
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_statuses_updated_at') THEN
        CREATE TRIGGER trg_jtd_statuses_updated_at
            BEFORE UPDATE ON public.n_jtd_statuses
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_status_flows
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_status_flows_updated_at') THEN
        CREATE TRIGGER trg_jtd_status_flows_updated_at
            BEFORE UPDATE ON public.n_jtd_status_flows
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_jtd_source_types
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_source_types_updated_at') THEN
        CREATE TRIGGER trg_jtd_source_types_updated_at
            BEFORE UPDATE ON public.n_jtd_source_types
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;

    -- n_system_actors
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_system_actors_updated_at') THEN
        CREATE TRIGGER trg_system_actors_updated_at
            BEFORE UPDATE ON public.n_system_actors
            FOR EACH ROW EXECUTE FUNCTION public.jtd_set_updated_at();
    END IF;
END $$;

-- ============================================================
-- TRIGGER FOR STATUS HISTORY (Auto-log status changes)
-- ============================================================

CREATE OR REPLACE FUNCTION public.jtd_log_status_change()
RETURNS TRIGGER AS $$
DECLARE
    v_previous_history_id UUID;
    v_duration_seconds INT;
BEGIN
    -- Only log if status actually changed
    IF OLD.status_code IS DISTINCT FROM NEW.status_code THEN

        -- Calculate duration of previous status
        SELECT EXTRACT(EPOCH FROM (NOW() - status_started_at))::INT
        INTO v_duration_seconds
        FROM public.n_jtd_status_history
        WHERE jtd_id = NEW.id
        ORDER BY created_at DESC
        LIMIT 1;

        -- Update the previous status history record with end time
        UPDATE public.n_jtd_status_history
        SET status_ended_at = NOW(),
            duration_seconds = v_duration_seconds
        WHERE jtd_id = NEW.id
          AND status_ended_at IS NULL;

        -- Insert new status history record
        INSERT INTO public.n_jtd_status_history (
            jtd_id,
            from_status_id,
            from_status_code,
            to_status_id,
            to_status_code,
            is_valid_transition,
            transition_note,
            performed_by_type,
            performed_by_id,
            performed_by_name,
            status_started_at,
            is_live,
            created_by
        ) VALUES (
            NEW.id,
            OLD.status_id,
            OLD.status_code,
            NEW.status_id,
            NEW.status_code,
            NEW.is_valid_transition,
            NEW.transition_note,
            NEW.performed_by_type,
            NEW.performed_by_id,
            NEW.performed_by_name,
            NOW(),
            NEW.is_live,
            NEW.updated_by
        );

        -- Update JTD tracking fields
        NEW.status_changed_at = NOW();
        NEW.previous_status_code = OLD.status_code;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_status_change') THEN
        CREATE TRIGGER trg_jtd_status_change
            BEFORE UPDATE ON public.n_jtd
            FOR EACH ROW EXECUTE FUNCTION public.jtd_log_status_change();
    END IF;
END $$;

-- ============================================================
-- TRIGGER FOR JTD CREATION (Initial history record)
-- ============================================================

CREATE OR REPLACE FUNCTION public.jtd_log_creation()
RETURNS TRIGGER AS $$
BEGIN
    -- Log creation in general history
    INSERT INTO public.n_jtd_history (
        jtd_id,
        action,
        performed_by_type,
        performed_by_id,
        performed_by_name,
        details,
        is_live,
        created_by
    ) VALUES (
        NEW.id,
        'created',
        NEW.performed_by_type,
        NEW.performed_by_id,
        NEW.performed_by_name,
        jsonb_build_object(
            'source_type', NEW.source_type_code,
            'source_id', NEW.source_id,
            'channel', NEW.channel_code,
            'recipient', NEW.recipient_contact,
            'event_type', NEW.event_type_code
        ),
        NEW.is_live,
        NEW.created_by
    );

    -- Log initial status in status history
    INSERT INTO public.n_jtd_status_history (
        jtd_id,
        from_status_code,
        to_status_id,
        to_status_code,
        is_valid_transition,
        performed_by_type,
        performed_by_id,
        performed_by_name,
        status_started_at,
        is_live,
        created_by
    ) VALUES (
        NEW.id,
        NULL,  -- No previous status
        NEW.status_id,
        NEW.status_code,
        true,
        NEW.performed_by_type,
        NEW.performed_by_id,
        NEW.performed_by_name,
        NOW(),
        NEW.is_live,
        NEW.created_by
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_jtd_creation') THEN
        CREATE TRIGGER trg_jtd_creation
            AFTER INSERT ON public.n_jtd
            FOR EACH ROW EXECUTE FUNCTION public.jtd_log_creation();
    END IF;
END $$;

-- ============================================================
-- HELPER FUNCTION: Validate Status Transition (Soft)
-- ============================================================

CREATE OR REPLACE FUNCTION public.jtd_validate_transition(
    p_event_type_code VARCHAR(50),
    p_from_status_code VARCHAR(30),
    p_to_status_code VARCHAR(30)
)
RETURNS BOOLEAN AS $$
DECLARE
    v_is_valid BOOLEAN;
BEGIN
    -- Check if transition exists in flow definition
    SELECT EXISTS (
        SELECT 1
        FROM public.n_jtd_status_flows sf
        JOIN public.n_jtd_statuses fs ON sf.from_status_id = fs.id
        JOIN public.n_jtd_statuses ts ON sf.to_status_id = ts.id
        WHERE sf.event_type_code = p_event_type_code
          AND fs.code = p_from_status_code
          AND ts.code = p_to_status_code
          AND sf.is_active = true
    ) INTO v_is_valid;

    RETURN v_is_valid;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.jtd_validate_transition IS 'Check if status transition is valid for event type (soft enforcement)';

-- ============================================================
-- HELPER FUNCTION: Get Status Duration Summary
-- ============================================================

CREATE OR REPLACE FUNCTION public.jtd_get_status_duration_summary(p_jtd_id UUID)
RETURNS TABLE (
    status_code VARCHAR(30),
    total_duration_seconds BIGINT,
    occurrence_count INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sh.to_status_code,
        SUM(COALESCE(sh.duration_seconds, 0))::BIGINT,
        COUNT(*)::INT
    FROM public.n_jtd_status_history sh
    WHERE sh.jtd_id = p_jtd_id
    GROUP BY sh.to_status_code
    ORDER BY MIN(sh.created_at);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.jtd_get_status_duration_summary IS 'Get summary of time spent in each status for a JTD';

-- ============================================================
-- END OF MIGRATION
-- ============================================================
