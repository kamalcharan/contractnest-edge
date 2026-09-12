-- ═══════════════════════════════════════════════════════════════════
-- service-execution/003_b2_default_form_and_mapping_columns.sql
-- B2.1 + B2.2 — APPLIED LIVE 2026-09-12. Source-of-record — do not re-run
-- (B2.1 guard RAISEs if the form already exists).
--
-- B2.1: seeds the platform-default form "General Service Completion" —
-- the LAST rung of the D9 resolver ladder (block form → KT form →
-- contract fallback → platform default). Deterministic id
-- f0000000-0000-4000-a000-000000000001; also discoverable via
-- source='platform_default' AND status='approved'.
-- Content decisions (owner gate = review):
--   · deliberately SHORT — 2 required selects + 2 optional textareas.
--     It is the fallback for ANY service on ANY asset type.
--   · NO identification section (unlike KT-composed forms): per D10,
--     asset/visit identity is prefilled from the job's event×asset row,
--     never typed by the technician.
--   · schema shape matches the KT-composed forms exactly
--     (sections/fields/options/validation) so the existing renderer and
--     catalog-studio builder open it unchanged.
--
-- B2.2: additive columns on m_form_template_mappings (table was EMPTY,
-- verified pre-migration) + unique index:
--   contract_block_id     uuid  — block-level binding (NULL = contract-level)
--   resource_template_id  uuid  — KT rung provenance
--   require_upload        bool  — D4 combo (form AND photo both required)
--   resolved_via          varchar — which D9 rung produced the row
--   ux_form_mappings_contract_block_form UNIQUE
--     (contract_id, COALESCE(contract_block_id, zero-uuid), form_template_id)
--
-- Rollback: DELETE FROM m_form_templates WHERE id='f0000000-0000-4000-a000-000000000001';
--           ALTER TABLE m_form_template_mappings DROP COLUMN ... (4 cols);
--           DROP INDEX ux_form_mappings_contract_block_form;
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_form_id uuid := 'f0000000-0000-4000-a000-000000000001';
    v_vani    uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
    IF EXISTS (SELECT 1 FROM m_form_templates WHERE id = v_form_id) THEN
        RAISE EXCEPTION 'B2.1 abort: platform default form already exists';
    END IF;

    INSERT INTO m_form_templates
        (id, name, description, category, form_type, tags, schema, version,
         status, source, created_by, approved_by, approved_at)
    VALUES
        (v_form_id,
         'General Service Completion',
         'Platform default service-completion form. Used automatically when a service block, its equipment type, and the contract all specify no smart form (decision D9). Asset and visit identity are prefilled from the job — never typed (decision D10).',
         'general',
         'during_service',
         ARRAY['platform_default','fallback','service_completion'],
         '{
            "id": "platform_default_service_completion",
            "title": "General Service Completion",
            "version": 1,
            "sections": [
              {
                "id": "outcome",
                "title": "Service Outcome",
                "fields": [
                  {
                    "id": "work_status",
                    "type": "select",
                    "label": "Was the work completed?",
                    "options": [
                      {"label": "Completed in full", "value": "completed"},
                      {"label": "Partially completed - follow-up needed", "value": "partial"},
                      {"label": "Could not be carried out", "value": "not_done"}
                    ],
                    "validation": {"required": true}
                  },
                  {
                    "id": "work_summary",
                    "type": "textarea",
                    "label": "What was done",
                    "help_text": "Brief summary in your own words (optional)"
                  }
                ]
              },
              {
                "id": "condition",
                "title": "Asset Condition",
                "fields": [
                  {
                    "id": "asset_condition",
                    "type": "select",
                    "label": "Condition of the asset after service",
                    "options": [
                      {"label": "Good - no issues", "value": "good"},
                      {"label": "Needs attention - minor issues noted", "value": "needs_attention"},
                      {"label": "Critical - immediate action required", "value": "critical"}
                    ],
                    "validation": {"required": true}
                  },
                  {
                    "id": "notes",
                    "type": "textarea",
                    "label": "Issues observed / notes",
                    "help_text": "Anything the customer or office should know (optional)"
                  }
                ]
              }
            ],
            "settings": {"allow_draft": false, "show_progress": false, "require_all_sections": false},
            "description": "Platform default - 2 required selections, 2 optional notes"
         }'::jsonb,
         1, 'approved', 'platform_default', v_vani, v_vani, now());

    ALTER TABLE m_form_template_mappings
        ADD COLUMN IF NOT EXISTS contract_block_id uuid NULL,
        ADD COLUMN IF NOT EXISTS resource_template_id uuid NULL,
        ADD COLUMN IF NOT EXISTS require_upload boolean NOT NULL DEFAULT false,
        ADD COLUMN IF NOT EXISTS resolved_via varchar(30) NULL;

    COMMENT ON COLUMN m_form_template_mappings.contract_block_id IS
      'Service block this mapping binds to (NULL = contract-level). service-execution/003 (B2.2).';
    COMMENT ON COLUMN m_form_template_mappings.resource_template_id IS
      'Equipment/resource type the form was resolved from, when the KT rung matched (B2.2).';
    COMMENT ON COLUMN m_form_template_mappings.require_upload IS
      'D4: form AND photo/document upload both required to prove a visit.';
    COMMENT ON COLUMN m_form_template_mappings.resolved_via IS
      'Which D9 ladder rung produced this row: block_config | kt_type | contract_fallback | platform_default.';

    CREATE UNIQUE INDEX IF NOT EXISTS ux_form_mappings_contract_block_form
      ON m_form_template_mappings
      (contract_id, COALESCE(contract_block_id, '00000000-0000-0000-0000-000000000000'::uuid), form_template_id);

    RAISE NOTICE 'B2.1+B2.2 OK: default form seeded (id %), mapping columns + unique index in place', v_form_id;
END
$do$;
