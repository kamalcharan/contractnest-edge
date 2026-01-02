-- ============================================================================
-- CATALOG STUDIO: Master Data Seed
-- ============================================================================
-- Purpose: Seed m_category_master and m_category_details for Catalog Studio
-- Uses existing productMasterdata pattern
-- ============================================================================

-- ============================================================================
-- 1. BLOCK TYPES (cat_block_type)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_block_type',
    'Block Types',
    'Types of blocks available in Catalog Studio',
    'Blocks',
    1,
    true
) ON CONFLICT (category_name) DO NOTHING;

-- Get the category_id for cat_block_type
DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_block_type';

    -- Insert block type details
    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'service', 'Service', 'Deliverable work with SLA, duration, and evidence requirements', 'Briefcase', '#4F46E5', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'spare', 'Spare Part', 'Physical products with SKU, inventory, and warranty', 'Package', '#059669', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'billing', 'Billing', 'Payment structures - EMI, milestone, advance, postpaid', 'CreditCard', '#D97706', 3, true, false),
        (uuid_generate_v4(), v_category_id, 'text', 'Text', 'Terms, policies, and text content', 'FileText', '#6B7280', 4, true, false),
        (uuid_generate_v4(), v_category_id, 'video', 'Video', 'Embedded video content', 'Video', '#DC2626', 5, true, false),
        (uuid_generate_v4(), v_category_id, 'image', 'Image', 'Photos, diagrams, and visual content', 'Image', '#7C3AED', 6, true, false),
        (uuid_generate_v4(), v_category_id, 'checklist', 'Checklist', 'Task verification with optional photo per item', 'CheckSquare', '#0891B2', 7, true, false),
        (uuid_generate_v4(), v_category_id, 'document', 'Document', 'File attachments and uploads', 'Paperclip', '#64748B', 8, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 2. PRICING MODES (cat_pricing_mode)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_pricing_mode',
    'Pricing Modes',
    'How block pricing is determined',
    'DollarSign',
    2,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_pricing_mode';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'independent', 'Independent', 'Fixed price, same for all', 'CircleDollarSign', '#4F46E5', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'resource_based', 'Resource Based', 'Price varies by person or equipment', 'Users', '#059669', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'variant_based', 'Variant Based', 'Price varies by property type or model', 'Layers', '#D97706', 3, true, false),
        (uuid_generate_v4(), v_category_id, 'multi_resource', 'Multi Resource', 'Price from multiple dimensions (base + addons)', 'Grid3X3', '#7C3AED', 4, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 3. PRICE TYPES (cat_price_type)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_price_type',
    'Price Types',
    'Unit of pricing for blocks',
    'Tag',
    3,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_price_type';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'per_session', 'Per Session', 'Price per session/visit', 'Calendar', '#4F46E5', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'per_hour', 'Per Hour', 'Hourly rate', 'Clock', '#059669', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'per_day', 'Per Day', 'Daily rate', 'CalendarDays', '#D97706', 3, true, false),
        (uuid_generate_v4(), v_category_id, 'per_unit', 'Per Unit', 'Price per unit/piece', 'Package', '#7C3AED', 4, true, false),
        (uuid_generate_v4(), v_category_id, 'fixed', 'Fixed', 'Fixed price regardless of quantity', 'Lock', '#6B7280', 5, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 4. BLOCK STATUS (cat_block_status)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_block_status',
    'Block Status',
    'Status of blocks in the catalog',
    'Activity',
    4,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_block_status';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'active', 'Active', 'Block is active and available', 'CheckCircle', '#059669', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'draft', 'Draft', 'Block is in draft mode', 'FileEdit', '#D97706', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'archived', 'Archived', 'Block is archived and hidden', 'Archive', '#6B7280', 3, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 5. TEMPLATE STATUS (cat_template_status)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_template_status',
    'Template Status',
    'Status of templates in Catalog Studio',
    'FileStack',
    5,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_template_status';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'active', 'Active', 'Template is active and available', 'CheckCircle', '#059669', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'draft', 'Draft', 'Template is in draft mode', 'FileEdit', '#D97706', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'archived', 'Archived', 'Template is archived', 'Archive', '#6B7280', 3, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 6. EVIDENCE TYPES (cat_evidence_type)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_evidence_type',
    'Evidence Types',
    'Types of evidence that can be captured for service completion',
    'Camera',
    6,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_evidence_type';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'photo', 'Photo', 'Before/during/after photos', 'Camera', '#4F46E5', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'gps', 'GPS', 'Location verification (check-in/out)', 'MapPin', '#059669', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'signature', 'Signature', 'Client digital signature', 'PenTool', '#D97706', 3, true, false),
        (uuid_generate_v4(), v_category_id, 'notes', 'Notes', 'Session notes and summary', 'FileText', '#6B7280', 4, true, false),
        (uuid_generate_v4(), v_category_id, 'document', 'Document', 'Report or certificate upload', 'FileUp', '#7C3AED', 5, true, false),
        (uuid_generate_v4(), v_category_id, 'video', 'Video', 'Session recording (virtual)', 'Video', '#DC2626', 6, true, false),
        (uuid_generate_v4(), v_category_id, 'rating', 'Rating', 'Client feedback and rating', 'Star', '#F59E0B', 7, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 7. LOCATION TYPES (cat_location_type)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_location_type',
    'Location Types',
    'Service delivery location types',
    'MapPin',
    7,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_location_type';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'onsite', 'On-site', 'Service delivered at client location', 'Home', '#4F46E5', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'virtual', 'Virtual', 'Service delivered online/video call', 'Video', '#059669', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'hybrid', 'Hybrid', 'Can be delivered on-site or virtual', 'Layers', '#D97706', 3, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 8. CURRENCIES (cat_currency)
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_currency',
    'Currencies',
    'Supported currencies for pricing',
    'DollarSign',
    8,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_currency';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable, tags)
    VALUES
        (uuid_generate_v4(), v_category_id, 'INR', 'Indian Rupee', '₹', 'IndianRupee', '#4F46E5', 1, true, false, '{"symbol": "₹", "locale": "en-IN"}'),
        (uuid_generate_v4(), v_category_id, 'USD', 'US Dollar', '$', 'DollarSign', '#059669', 2, true, false, '{"symbol": "$", "locale": "en-US"}'),
        (uuid_generate_v4(), v_category_id, 'EUR', 'Euro', '€', 'Euro', '#D97706', 3, true, false, '{"symbol": "€", "locale": "de-DE"}'),
        (uuid_generate_v4(), v_category_id, 'GBP', 'British Pound', '£', 'PoundSterling', '#7C3AED', 4, true, false, '{"symbol": "£", "locale": "en-GB"}'),
        (uuid_generate_v4(), v_category_id, 'AED', 'UAE Dirham', 'د.إ', 'Coins', '#0891B2', 5, true, false, '{"symbol": "د.إ", "locale": "ar-AE"}'),
        (uuid_generate_v4(), v_category_id, 'SGD', 'Singapore Dollar', 'S$', 'DollarSign', '#64748B', 6, true, false, '{"symbol": "S$", "locale": "en-SG"}')
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- 9. PAYMENT TYPES (cat_payment_type) - for billing blocks
-- ============================================================================

INSERT INTO m_category_master (id, category_name, display_name, description, icon_name, sequence_no, is_active)
VALUES (
    uuid_generate_v4(),
    'cat_payment_type',
    'Payment Types',
    'Payment structure types for billing blocks',
    'Wallet',
    9,
    true
) ON CONFLICT (category_name) DO NOTHING;

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id FROM m_category_master WHERE category_name = 'cat_payment_type';

    INSERT INTO m_category_details (id, category_id, sub_cat_name, display_name, description, icon_name, hexcolor, sequence_no, is_active, is_deletable)
    VALUES
        (uuid_generate_v4(), v_category_id, 'emi', 'EMI', 'Split into monthly installments', 'CalendarClock', '#4F46E5', 1, true, false),
        (uuid_generate_v4(), v_category_id, 'advance', 'Advance', 'Full or partial payment upfront', 'CircleDollarSign', '#059669', 2, true, false),
        (uuid_generate_v4(), v_category_id, 'milestone', 'Milestone', 'Payment at project milestones', 'Milestone', '#D97706', 3, true, false),
        (uuid_generate_v4(), v_category_id, 'postpaid', 'Postpaid', 'Payment after service completion', 'Clock', '#7C3AED', 4, true, false),
        (uuid_generate_v4(), v_category_id, 'subscription', 'Subscription', 'Recurring payment', 'RefreshCw', '#0891B2', 5, true, false)
    ON CONFLICT DO NOTHING;
END $$;

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================

-- Run this to verify seed data:
-- SELECT m.category_name, m.display_name, COUNT(d.id) as details_count
-- FROM m_category_master m
-- LEFT JOIN m_category_details d ON d.category_id = m.id
-- WHERE m.category_name LIKE 'cat_%'
-- GROUP BY m.id, m.category_name, m.display_name
-- ORDER BY m.sequence_no;
