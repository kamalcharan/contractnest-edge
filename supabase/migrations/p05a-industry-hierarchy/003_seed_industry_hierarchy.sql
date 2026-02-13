-- ============================================================================
-- P0.5a Migration 003: Seed industry hierarchy data
-- ============================================================================
-- IDEMPOTENT: Safe to run multiple times.
-- Strategy: Clean up any partial data from previous migration attempts,
--           then insert fresh. Safe because no user data references these yet.
-- Total after migration: 21 parents + 47 sub-segments = 68 rows
-- Depends on: 001_alter_industries_add_hierarchy.sql
-- ============================================================================

-- ============================================================================
-- STEP 0: Clean up partial data from previous migration attempts
-- ============================================================================
-- Delete any sub-segments (rows with parent_id IS NOT NULL) from prior runs
-- Safe: t_tenant_industry_segments is new/empty, no user data references these
DELETE FROM public.m_catalog_industries WHERE parent_id IS NOT NULL;

-- Delete new parent industries if they were partially inserted before
DELETE FROM public.m_catalog_industries
WHERE id IN ('agriculture', 'legal_professional', 'arts_media', 'spiritual_religious', 'home_services', 'construction');

-- ============================================================================
-- STEP 1: Mark all existing industries as level=0 parents
-- ============================================================================
UPDATE public.m_catalog_industries
SET level = 0, segment_type = 'segment', parent_id = NULL
WHERE id IN (
  'healthcare', 'wellness', 'manufacturing', 'facility_management',
  'technology', 'education', 'financial_services', 'hospitality',
  'retail', 'automotive', 'real_estate', 'telecommunications',
  'logistics', 'government', 'other'
);

-- ============================================================================
-- STEP 2: Insert 6 new parent industries
-- ============================================================================
INSERT INTO public.m_catalog_industries
  (id, name, description, icon, common_pricing_rules, compliance_requirements, is_active, sort_order, level, segment_type)
VALUES
  ('agriculture', 'Agriculture', 'Farming, dairy, livestock, and agri-tech businesses', 'Sprout',
   '[{"name":"Seasonal Pricing","action":"+20%","condition":"season = harvest"},{"name":"Bulk Purchase","action":"-15%","condition":"quantity > 1000kg"}]',
   '["FSSAI Standards","Pesticide Regulations","Organic Certification"]',
   true, 16, 0, 'segment'),

  ('legal_professional', 'Legal & Professional Services', 'Law firms, accounting practices, and management consultancies', 'Scale',
   '[{"name":"Retainer Discount","action":"-10%","condition":"contract = retainer"},{"name":"Urgent Filing","action":"+30%","condition":"priority = urgent"}]',
   '["Bar Council Regulations","CA Institute Norms","Professional Ethics"]',
   true, 17, 0, 'segment'),

  ('arts_media', 'Arts & Media', 'Photography studios, design agencies, and media production houses', 'Palette',
   '[{"name":"Rush Delivery","action":"+40%","condition":"turnaround < 48h"},{"name":"Package Deal","action":"-15%","condition":"services > 3"}]',
   '["Copyright Laws","Broadcasting Standards","Content Guidelines"]',
   true, 18, 0, 'segment'),

  ('spiritual_religious', 'Spiritual & Religious Services', 'Temples, churches, spiritual retreats, and religious organizations', 'Church',
   '[{"name":"Festival Season","action":"+25%","condition":"season = festival"},{"name":"Community Discount","action":"-20%","condition":"group_size > 20"}]',
   '["Religious Trust Regulations","Charitable Trust Laws","Safety Standards"]',
   true, 19, 0, 'segment'),

  ('home_services', 'Home Services', 'Plumbing, electrical, cleaning, and interior design services', 'Hammer',
   '[{"name":"Emergency Callout","action":"+50%","condition":"service_type = emergency"},{"name":"Repeat Customer","action":"-10%","condition":"visits > 3"}]',
   '["Licensing Requirements","Safety Standards","Insurance Requirements"]',
   true, 20, 0, 'segment'),

  ('construction', 'Construction', 'Civil construction, renovation, architecture, and project management', 'HardHat',
   '[{"name":"Large Project","action":"-10%","condition":"value > 5000000"},{"name":"Expedited Timeline","action":"+25%","condition":"timeline < standard"}]',
   '["Building Codes","Environmental Clearances","Safety Regulations","RERA Compliance"]',
   true, 21, 0, 'segment');

-- Move "Other" to last sort position
UPDATE public.m_catalog_industries SET sort_order = 99 WHERE id = 'other';


-- ============================================================================
-- STEP 3: Insert sub-segments (47 total)
-- ============================================================================

-- Healthcare (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('dental_clinics', 'Dental Clinics', 'Dental practices, orthodontics, and oral care centers', 'Stethoscope', true, 1, 'healthcare', 1, 'sub_segment'),
  ('physiotherapy', 'Physiotherapy', 'Physical therapy, rehabilitation, and sports medicine', 'Stethoscope', true, 2, 'healthcare', 1, 'sub_segment'),
  ('general_practice', 'General Practice', 'Family medicine, general physicians, and primary care', 'Stethoscope', true, 3, 'healthcare', 1, 'sub_segment');

-- Wellness (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('yoga_studios', 'Yoga Studios', 'Yoga centers, meditation spaces, and mindfulness practices', 'Heart', true, 1, 'wellness', 1, 'sub_segment'),
  ('gyms_fitness', 'Gyms & Fitness Centers', 'Gymnasiums, CrossFit boxes, and fitness studios', 'Heart', true, 2, 'wellness', 1, 'sub_segment'),
  ('spas_salons', 'Spas & Salons', 'Day spas, beauty salons, and wellness retreats', 'Heart', true, 3, 'wellness', 1, 'sub_segment');

-- Manufacturing (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('food_processing', 'Food Processing', 'Food manufacturing, packaging, and processing plants', 'Factory', true, 1, 'manufacturing', 1, 'sub_segment'),
  ('textile_manufacturing', 'Textile & Apparel', 'Textile mills, garment factories, and apparel manufacturing', 'Factory', true, 2, 'manufacturing', 1, 'sub_segment'),
  ('pharmaceutical', 'Pharmaceutical', 'Drug manufacturing, biotech, and pharma research', 'Factory', true, 3, 'manufacturing', 1, 'sub_segment');

-- Facility Management (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('commercial_cleaning', 'Commercial Cleaning', 'Office cleaning, janitorial services, and sanitation', 'Building2', true, 1, 'facility_management', 1, 'sub_segment'),
  ('security_services', 'Security Services', 'Guard services, surveillance, and access control', 'Building2', true, 2, 'facility_management', 1, 'sub_segment');

-- Technology (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('saas_cloud', 'SaaS & Cloud Services', 'Cloud platforms, SaaS products, and hosted solutions', 'Cpu', true, 1, 'technology', 1, 'sub_segment'),
  ('it_consulting', 'IT Consulting', 'Technology advisory, digital transformation, and IT strategy', 'Cpu', true, 2, 'technology', 1, 'sub_segment'),
  ('cybersecurity', 'Cybersecurity', 'Security services, penetration testing, and compliance', 'Cpu', true, 3, 'technology', 1, 'sub_segment');

-- Education (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('k12_schools', 'K-12 Schools', 'Primary and secondary schools, international schools', 'GraduationCap', true, 1, 'education', 1, 'sub_segment'),
  ('coaching_centers', 'Coaching Centers', 'Tutoring, test prep, and competitive exam coaching', 'GraduationCap', true, 2, 'education', 1, 'sub_segment'),
  ('e_learning', 'E-Learning Platforms', 'Online courses, LMS platforms, and EdTech', 'GraduationCap', true, 3, 'education', 1, 'sub_segment');

-- Financial Services (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('banking', 'Banking', 'Commercial banks, cooperative banks, and NBFCs', 'DollarSign', true, 1, 'financial_services', 1, 'sub_segment'),
  ('insurance', 'Insurance', 'Life insurance, general insurance, and reinsurance', 'DollarSign', true, 2, 'financial_services', 1, 'sub_segment');

-- Hospitality (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('hotels_resorts', 'Hotels & Resorts', 'Hotels, resorts, boutique stays, and hospitality chains', 'UtensilsCrossed', true, 1, 'hospitality', 1, 'sub_segment'),
  ('restaurants_cafes', 'Restaurants & Cafes', 'Restaurants, cafes, cloud kitchens, and catering', 'UtensilsCrossed', true, 2, 'hospitality', 1, 'sub_segment'),
  ('event_venues', 'Event Venues', 'Banquet halls, conference centers, and wedding venues', 'UtensilsCrossed', true, 3, 'hospitality', 1, 'sub_segment');

-- Retail (3)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('grocery', 'Grocery & Supermarkets', 'Supermarkets, grocery chains, and convenience stores', 'ShoppingBag', true, 1, 'retail', 1, 'sub_segment'),
  ('fashion_retail', 'Fashion Retail', 'Clothing stores, fashion boutiques, and accessories', 'ShoppingBag', true, 2, 'retail', 1, 'sub_segment'),
  ('e_commerce', 'E-Commerce', 'Online retail, marketplaces, and D2C brands', 'ShoppingBag', true, 3, 'retail', 1, 'sub_segment');

-- Automotive (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('car_dealerships', 'Car Dealerships', 'New and used car sales, showrooms, and dealerships', 'Car', true, 1, 'automotive', 1, 'sub_segment'),
  ('auto_service', 'Auto Service Centers', 'Vehicle repair, maintenance, and detailing services', 'Car', true, 2, 'automotive', 1, 'sub_segment');

-- Real Estate (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('residential_realty', 'Residential Properties', 'Residential sales, apartments, and housing societies', 'Home', true, 1, 'real_estate', 1, 'sub_segment'),
  ('commercial_realty', 'Commercial Properties', 'Office spaces, commercial leasing, and retail spaces', 'Home', true, 2, 'real_estate', 1, 'sub_segment');

-- Telecommunications (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('isp', 'Internet Service Providers', 'Broadband, fiber, and wireless internet services', 'Phone', true, 1, 'telecommunications', 1, 'sub_segment'),
  ('mobile_operators', 'Mobile Operators', 'Cellular networks, MVNOs, and mobile services', 'Phone', true, 2, 'telecommunications', 1, 'sub_segment');

-- Logistics (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('courier_services', 'Courier Services', 'Package delivery, express shipping, and last-mile', 'Truck', true, 1, 'logistics', 1, 'sub_segment'),
  ('warehousing', 'Warehousing', 'Storage facilities, fulfillment centers, and distribution', 'Truck', true, 2, 'logistics', 1, 'sub_segment');

-- Government (2)
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('municipal', 'Municipal Services', 'City corporations, municipal bodies, and civic services', 'Landmark', true, 1, 'government', 1, 'sub_segment'),
  ('public_sector', 'Public Sector Enterprises', 'PSUs, government departments, and statutory bodies', 'Landmark', true, 2, 'government', 1, 'sub_segment');

-- Agriculture (2) — NEW PARENT
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('farming', 'Farming & Agriculture', 'Crop farming, horticulture, and plantation', 'Sprout', true, 1, 'agriculture', 1, 'sub_segment'),
  ('dairy_livestock', 'Dairy & Livestock', 'Dairy farms, poultry, and animal husbandry', 'Sprout', true, 2, 'agriculture', 1, 'sub_segment');

-- Legal & Professional Services (2) — NEW PARENT
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('law_firms', 'Law Firms', 'Legal practices, corporate law, and litigation', 'Scale', true, 1, 'legal_professional', 1, 'sub_segment'),
  ('accounting_tax', 'Accounting & Tax', 'CA firms, tax consultants, and audit practices', 'Scale', true, 2, 'legal_professional', 1, 'sub_segment');

-- Arts & Media (2) — NEW PARENT
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('photography', 'Photography & Videography', 'Photo studios, wedding photography, and videography', 'Palette', true, 1, 'arts_media', 1, 'sub_segment'),
  ('design_studios', 'Design Studios', 'Graphic design, UI/UX agencies, and creative studios', 'Palette', true, 2, 'arts_media', 1, 'sub_segment');

-- Spiritual & Religious Services (2) — NEW PARENT
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('temples_churches', 'Temples & Churches', 'Temples, churches, mosques, and gurdwaras', 'Church', true, 1, 'spiritual_religious', 1, 'sub_segment'),
  ('spiritual_retreats', 'Spiritual Retreats', 'Meditation retreats, ashrams, and spiritual centers', 'Church', true, 2, 'spiritual_religious', 1, 'sub_segment');

-- Home Services (3) — NEW PARENT
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('plumbing', 'Plumbing', 'Plumbing services, pipe fitting, and water systems', 'Hammer', true, 1, 'home_services', 1, 'sub_segment'),
  ('electrical_services', 'Electrical Services', 'Wiring, electrical repair, and installations', 'Hammer', true, 2, 'home_services', 1, 'sub_segment'),
  ('interior_design', 'Interior Design', 'Home interiors, decor consulting, and space planning', 'Hammer', true, 3, 'home_services', 1, 'sub_segment');

-- Construction (2) — NEW PARENT
INSERT INTO public.m_catalog_industries (id, name, description, icon, is_active, sort_order, parent_id, level, segment_type) VALUES
  ('civil_construction', 'Civil Construction', 'Building construction, infrastructure, and civil works', 'HardHat', true, 1, 'construction', 1, 'sub_segment'),
  ('renovation', 'Renovation & Remodeling', 'Home renovation, commercial remodeling, and restoration', 'HardHat', true, 2, 'construction', 1, 'sub_segment');

-- NOTE: "Other Industries" (id='other') has NO sub-segments.


-- ============================================================================
-- VERIFICATION (run after migration)
-- ============================================================================
-- SELECT COUNT(*) FROM m_catalog_industries WHERE level = 0;  -- Expect: 21
-- SELECT COUNT(*) FROM m_catalog_industries WHERE level = 1;  -- Expect: 47
-- SELECT parent_id, COUNT(*) FROM m_catalog_industries WHERE level = 1 GROUP BY parent_id ORDER BY parent_id;


-- ============================================================================
-- ROLLBACK (commented out — run manually if needed)
-- ============================================================================
-- DELETE FROM public.m_catalog_industries WHERE level = 1;
-- DELETE FROM public.m_catalog_industries WHERE id IN ('agriculture','legal_professional','arts_media','spiritual_religious','home_services','construction');
-- UPDATE public.m_catalog_industries SET sort_order = 15 WHERE id = 'other';
