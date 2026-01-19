-- ============================================================================
-- Business Model Step 1: Seed X-Product Category
-- ============================================================================
-- Purpose: Create X-Product category in m_category_master with platform products
-- Values match exactly with x-product header values used in API calls
-- ============================================================================

-- Step 1: Insert the X-Product category into m_category_master
-- Using ON CONFLICT to make this idempotent (safe to run multiple times)
INSERT INTO m_category_master (
    category_name,
    description,
    sequence_no,
    is_active,
    created_at,
    updated_at
)
VALUES (
    'X-Product',
    'Platform products - values match x-product header for API calls',
    100,
    true,
    NOW(),
    NOW()
)
ON CONFLICT (category_name) DO UPDATE SET
    description = EXCLUDED.description,
    updated_at = NOW();

-- Step 2: Insert product entries into m_category_details
-- detail_value MUST match exactly with x-product header values (lowercase)
-- detail_name is the display name shown in dropdowns

-- ContractNest
INSERT INTO m_category_details (
    category_id,
    detail_name,
    detail_value,
    description,
    sequence_no,
    is_active,
    created_at,
    updated_at
)
SELECT
    cm.id,
    'ContractNest',
    'contractnest',
    'Contract lifecycle management platform for SMBs and enterprises',
    1,
    true,
    NOW(),
    NOW()
FROM m_category_master cm
WHERE cm.category_name = 'X-Product'
ON CONFLICT (category_id, detail_value) DO UPDATE SET
    detail_name = EXCLUDED.detail_name,
    description = EXCLUDED.description,
    sequence_no = EXCLUDED.sequence_no,
    updated_at = NOW();

-- FamilyKnows
INSERT INTO m_category_details (
    category_id,
    detail_name,
    detail_value,
    description,
    sequence_no,
    is_active,
    created_at,
    updated_at
)
SELECT
    cm.id,
    'FamilyKnows',
    'familyknows',
    'Family asset and document management platform',
    2,
    true,
    NOW(),
    NOW()
FROM m_category_master cm
WHERE cm.category_name = 'X-Product'
ON CONFLICT (category_id, detail_value) DO UPDATE SET
    detail_name = EXCLUDED.detail_name,
    description = EXCLUDED.description,
    sequence_no = EXCLUDED.sequence_no,
    updated_at = NOW();

-- Kaladristi
INSERT INTO m_category_details (
    category_id,
    detail_name,
    detail_value,
    description,
    sequence_no,
    is_active,
    created_at,
    updated_at
)
SELECT
    cm.id,
    'Kaladristi',
    'kaladristi',
    'AI-powered stock research platform for individual investors',
    3,
    true,
    NOW(),
    NOW()
FROM m_category_master cm
WHERE cm.category_name = 'X-Product'
ON CONFLICT (category_id, detail_value) DO UPDATE SET
    detail_name = EXCLUDED.detail_name,
    description = EXCLUDED.description,
    sequence_no = EXCLUDED.sequence_no,
    updated_at = NOW();

-- ============================================================================
-- Verification Query (run after migration to confirm)
-- ============================================================================
-- SELECT
--     cm.category_name,
--     cd.detail_name,
--     cd.detail_value,
--     cd.description,
--     cd.sequence_no,
--     cd.is_active
-- FROM m_category_master cm
-- JOIN m_category_details cd ON cd.category_id = cm.id
-- WHERE cm.category_name = 'X-Product'
-- ORDER BY cd.sequence_no;
-- ============================================================================
