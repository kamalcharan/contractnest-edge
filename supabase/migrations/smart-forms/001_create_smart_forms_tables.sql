-- ============================================================================
-- SmartForms — Database Migration
-- ============================================================================
-- Module: Forms Builder & Renderer Engine
-- Version: 1.0
-- Date: February 2026
--
-- Creates:
--   1. m_form_templates          — Global form definitions (support team)
--   2. m_form_tenant_selections  — Tenant selects which forms to use
--   3. m_form_template_mappings  — Tenant maps forms to contracts/events
--   4. m_form_submissions        — Completed form responses
--   5. m_form_attachments        — File uploads linked to submissions
--   6. Storage bucket            — form-attachments (private)
-- ============================================================================

-- ============================================================================
-- 1. m_form_templates — Global Form Definitions
-- ============================================================================
-- No tenant_id. Managed exclusively by support team (admin).
-- Only 'approved' forms are visible to tenants for selection.
-- Status lifecycle: draft → in_review → approved → past
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.m_form_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  name VARCHAR(255) NOT NULL,
  description TEXT,
  category VARCHAR(100) NOT NULL,
  -- Categories: 'calibration', 'inspection', 'audit', 'maintenance',
  --             'clinical', 'pharma', 'compliance', 'onboarding', 'general'

  form_type VARCHAR(50) NOT NULL,
  -- Types: 'pre_service', 'post_service', 'during_service', 'standalone'

  tags TEXT[] DEFAULT '{}',
  -- Searchable tags: ['ventilator', 'biomedical', 'quarterly']

  -- Schema
  schema JSONB NOT NULL,
  -- The full form definition (sections, fields, visibility rules, settings)

  -- Versioning
  version INT NOT NULL DEFAULT 1,
  parent_template_id UUID REFERENCES public.m_form_templates(id),
  -- Links v2 → v1 for lineage tracking. NULL for first version.

  -- Workflow
  status VARCHAR(20) NOT NULL DEFAULT 'draft',
  -- Lifecycle: draft → in_review → approved → past

  thumbnail_url TEXT,

  -- Audit
  created_by UUID NOT NULL,
  approved_by UUID,
  approved_at TIMESTAMPTZ,
  review_notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_m_form_templates_status
  ON public.m_form_templates(status);

CREATE INDEX IF NOT EXISTS idx_m_form_templates_category
  ON public.m_form_templates(category);

CREATE INDEX IF NOT EXISTS idx_m_form_templates_parent
  ON public.m_form_templates(parent_template_id);

CREATE INDEX IF NOT EXISTS idx_m_form_templates_tags
  ON public.m_form_templates USING GIN(tags);

CREATE INDEX IF NOT EXISTS idx_m_form_templates_schema
  ON public.m_form_templates USING GIN(schema);


-- ============================================================================
-- 2. m_form_tenant_selections — Tenant Selects Which Forms to Use
-- ============================================================================
-- When admin publishes (approves) a form template, tenants can then
-- choose to activate it in their workspace via Settings.
-- Only selected forms appear in the tenant's workspace for mapping/use.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.m_form_tenant_selections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  form_template_id UUID NOT NULL REFERENCES public.m_form_templates(id),

  is_active BOOLEAN NOT NULL DEFAULT true,
  -- Tenant can deactivate without deleting (preserves history)

  selected_by UUID NOT NULL,
  -- The tenant_admin who activated this form

  selected_at TIMESTAMPTZ DEFAULT now(),
  deactivated_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  -- A tenant can only select a given template once
  UNIQUE(tenant_id, form_template_id)
);

-- RLS: Tenants can only see/manage their own selections
ALTER TABLE public.m_form_tenant_selections ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_m_form_tenant_selections_tenant
  ON public.m_form_tenant_selections(tenant_id);

CREATE INDEX IF NOT EXISTS idx_m_form_tenant_selections_template
  ON public.m_form_tenant_selections(form_template_id);

CREATE INDEX IF NOT EXISTS idx_m_form_tenant_selections_active
  ON public.m_form_tenant_selections(tenant_id, is_active)
  WHERE is_active = true;


-- ============================================================================
-- 3. m_form_template_mappings — Tenant Maps Forms to Contracts/Events
-- ============================================================================
-- After a tenant selects forms in Settings, they can map specific forms
-- to contracts and service events with timing (pre/post/during service).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.m_form_template_mappings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  form_template_id UUID NOT NULL REFERENCES public.m_form_templates(id),

  service_type VARCHAR(100),
  -- e.g., 'calibration', 'maintenance', 'inspection'

  timing VARCHAR(30) NOT NULL DEFAULT 'pre_service',
  -- 'pre_service', 'post_service', 'during_service'

  is_mandatory BOOLEAN DEFAULT true,
  -- Whether this form must be submitted for the service event to complete

  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to DATE,
  -- NULL = currently active. Set effective_to when replacing.

  status VARCHAR(20) DEFAULT 'active',
  -- 'active', 'inactive'

  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  UNIQUE(tenant_id, contract_id, form_template_id, timing, effective_from)
);

-- RLS: Tenants can only see/manage their own mappings
ALTER TABLE public.m_form_template_mappings ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_m_form_template_mappings_tenant
  ON public.m_form_template_mappings(tenant_id);

CREATE INDEX IF NOT EXISTS idx_m_form_template_mappings_contract
  ON public.m_form_template_mappings(contract_id);

CREATE INDEX IF NOT EXISTS idx_m_form_template_mappings_template
  ON public.m_form_template_mappings(form_template_id);


-- ============================================================================
-- 4. m_form_submissions — Completed Form Responses
-- ============================================================================
-- Each submission is tied to a service event, a contract, and a tenant.
-- Responses are stored as JSONB keyed by field ID.
-- Status: draft → submitted → reviewed → approved → rejected
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.m_form_submissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  form_template_id UUID NOT NULL REFERENCES public.m_form_templates(id),
  form_template_version INT NOT NULL,
  -- Snapshot of version at time of submission (immutable reference)

  service_event_id UUID NOT NULL,
  contract_id UUID NOT NULL,
  mapping_id UUID REFERENCES public.m_form_template_mappings(id),

  responses JSONB NOT NULL DEFAULT '{}',
  -- Captured form data keyed by field ID
  -- Example: { "equipment_name": "Drager V500", "pain_level": "3" }

  computed_values JSONB DEFAULT '{}',
  -- Auto-calculated fields stored separately
  -- Example: { "overall_score": 85, "pass_count": 12, "fail_count": 2 }

  status VARCHAR(20) NOT NULL DEFAULT 'draft',
  -- 'draft' → 'submitted' → 'reviewed' → 'approved' → 'rejected'

  submitted_by UUID,
  submitted_at TIMESTAMPTZ,
  reviewed_by UUID,
  reviewed_at TIMESTAMPTZ,
  review_comments TEXT,

  device_info JSONB DEFAULT '{}',
  -- { "device": "iPad Pro", "browser": "Safari", "screen_width": 1024 }

  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- RLS: Tenants can only see their own submissions
ALTER TABLE public.m_form_submissions ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_m_form_submissions_tenant
  ON public.m_form_submissions(tenant_id);

CREATE INDEX IF NOT EXISTS idx_m_form_submissions_event
  ON public.m_form_submissions(service_event_id);

CREATE INDEX IF NOT EXISTS idx_m_form_submissions_template
  ON public.m_form_submissions(form_template_id);

CREATE INDEX IF NOT EXISTS idx_m_form_submissions_status
  ON public.m_form_submissions(status);

CREATE INDEX IF NOT EXISTS idx_m_form_submissions_responses
  ON public.m_form_submissions USING GIN(responses);


-- ============================================================================
-- 5. m_form_attachments — File Uploads (Documents, Images, Video)
-- ============================================================================
-- Each attachment is linked to a submission and a specific field in the form.
-- Actual files stored in Supabase Storage bucket 'form-attachments'.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.m_form_attachments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  form_submission_id UUID REFERENCES public.m_form_submissions(id) ON DELETE CASCADE,
  field_id VARCHAR(100) NOT NULL,
  -- The field in the form schema this attachment belongs to

  file_name VARCHAR(500) NOT NULL,
  file_type VARCHAR(100) NOT NULL,
  -- MIME type: 'image/jpeg', 'application/pdf', etc.

  file_size BIGINT NOT NULL,
  -- Size in bytes

  storage_path TEXT NOT NULL,
  -- Supabase Storage path: 'form-attachments/{tenant_id}/{submission_id}/{field_id}/{filename}'

  thumbnail_path TEXT,
  -- For images/videos: auto-generated thumbnail path

  metadata JSONB DEFAULT '{}',
  -- Optional: { "width": 1920, "height": 1080, "gps_lat": ..., "gps_lon": ... }

  uploaded_by UUID NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RLS: Tenants can only see their own attachments
ALTER TABLE public.m_form_attachments ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_m_form_attachments_submission
  ON public.m_form_attachments(form_submission_id);

CREATE INDEX IF NOT EXISTS idx_m_form_attachments_field
  ON public.m_form_attachments(field_id);

CREATE INDEX IF NOT EXISTS idx_m_form_attachments_tenant
  ON public.m_form_attachments(tenant_id);


-- ============================================================================
-- 6. Storage Bucket — form-attachments (private)
-- ============================================================================
-- Private bucket for form file uploads. Accessed via signed URLs.
-- Max 100MB per file (for video). Tenant-folder-level RLS.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'form-attachments',
  'form-attachments',
  false,
  104857600,  -- 100MB max file size
  ARRAY[
    'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/heic',
    'video/mp4', 'video/quicktime', 'video/webm',
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
) ON CONFLICT (id) DO NOTHING;


-- ============================================================================
-- 7. RLS Policies
-- ============================================================================

-- m_form_tenant_selections: tenant isolation
CREATE POLICY "m_form_tenant_selections_tenant_isolation"
  ON public.m_form_tenant_selections
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

-- m_form_template_mappings: tenant isolation
CREATE POLICY "m_form_template_mappings_tenant_isolation"
  ON public.m_form_template_mappings
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

-- m_form_submissions: tenant isolation
CREATE POLICY "m_form_submissions_tenant_isolation"
  ON public.m_form_submissions
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

-- m_form_attachments: tenant isolation
CREATE POLICY "m_form_attachments_tenant_isolation"
  ON public.m_form_attachments
  FOR ALL
  USING (tenant_id::text = current_setting('request.jwt.claims', true)::json->>'tenant_id');

-- Storage RLS: tenant folder isolation
CREATE POLICY "form_attachments_storage_tenant_isolation"
  ON storage.objects
  FOR ALL
  USING (
    bucket_id = 'form-attachments'
    AND (storage.foldername(name))[1] = current_setting('request.jwt.claims', true)::json->>'tenant_id'
  );


-- ============================================================================
-- Done
-- ============================================================================
