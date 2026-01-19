-- ============================================================================
-- Business Model - Seed Product Configs
-- ============================================================================
-- Purpose: Seed billing configurations for ContractNest and FamilyKnows
-- Depends on: 008_product_config_features.sql
-- ============================================================================

-- ============================================================================
-- 1. CONTRACTNEST PRODUCT CONFIG
-- ============================================================================
INSERT INTO t_bm_product_config (
    product_code,
    product_name,
    config_version,
    is_active,
    billing_config
)
VALUES (
    'contractnest',
    'ContractNest',
    '1.0',
    true,
    '{
        "plan_types": [
            {
                "code": "per_user",
                "label": "Per User",
                "metric": "users",
                "description": "Pricing based on number of users"
            },
            {
                "code": "per_contract",
                "label": "Per Contract",
                "metric": "contracts",
                "description": "Pricing based on number of contracts"
            }
        ],
        "features": [
            {
                "id": "contacts",
                "name": "Contacts",
                "description": "Number of contacts that can be created",
                "type": "limit",
                "default": 50,
                "trial": 5,
                "unit": "contacts"
            },
            {
                "id": "contracts",
                "name": "Contracts",
                "description": "Number of contracts that can be created",
                "type": "limit",
                "default": 25,
                "trial": 2,
                "unit": "contracts"
            },
            {
                "id": "appointments",
                "name": "Appointments",
                "description": "Number of appointments that can be scheduled",
                "type": "limit",
                "default": 30,
                "trial": 3,
                "unit": "appointments"
            },
            {
                "id": "documents",
                "name": "Document Storage",
                "description": "Document storage space in GB",
                "type": "limit",
                "default": 5,
                "trial": 1,
                "unit": "GB"
            },
            {
                "id": "users",
                "name": "User Accounts",
                "description": "Number of user accounts",
                "type": "limit",
                "default": 10,
                "trial": 2,
                "unit": "users"
            },
            {
                "id": "vani",
                "name": "VaNi AI",
                "description": "AI-powered virtual assistant",
                "type": "addon",
                "default": 1,
                "trial": 1,
                "base_price": 5000,
                "currency": "INR"
            },
            {
                "id": "marketplace",
                "name": "Marketplace",
                "description": "Access to integrated marketplace features",
                "type": "addon",
                "default": 1,
                "trial": 1,
                "base_price": 2000,
                "currency": "INR"
            },
            {
                "id": "finance",
                "name": "Finance",
                "description": "Financial management and reporting tools",
                "type": "addon",
                "default": 1,
                "trial": 1,
                "base_price": 3000,
                "currency": "INR"
            }
        ],
        "tier_templates": {
            "per_user": [
                {"min": 1, "max": 10, "label": "1-10 users"},
                {"min": 11, "max": 20, "label": "11-20 users"},
                {"min": 21, "max": 50, "label": "21-50 users"},
                {"min": 51, "max": 100, "label": "51-100 users"},
                {"min": 101, "max": null, "label": "101+ users"}
            ],
            "per_contract": [
                {"min": 1, "max": 25, "label": "1-25 contracts"},
                {"min": 26, "max": 50, "label": "26-50 contracts"},
                {"min": 51, "max": 100, "label": "51-100 contracts"},
                {"min": 101, "max": 250, "label": "101-250 contracts"},
                {"min": 251, "max": null, "label": "251+ contracts"}
            ]
        },
        "notifications": [
            {
                "channel": "inapp",
                "name": "In-App Notifications",
                "description": "Notifications within the application",
                "unit_price": 0.1,
                "default_credits": 100,
                "currency": "INR"
            },
            {
                "channel": "sms",
                "name": "SMS Notifications",
                "description": "Text message notifications",
                "unit_price": 1.0,
                "default_credits": 10,
                "currency": "INR"
            },
            {
                "channel": "email",
                "name": "Email Notifications",
                "description": "Email message notifications",
                "unit_price": 0.5,
                "default_credits": 25,
                "currency": "INR"
            },
            {
                "channel": "whatsapp",
                "name": "WhatsApp Notifications",
                "description": "WhatsApp message notifications",
                "unit_price": 2.0,
                "default_credits": 5,
                "currency": "INR"
            }
        ],
        "trial_options": [5, 7, 10, 14, 30],
        "billing_cycles": ["monthly", "quarterly", "annual"],
        "default_trial_days": 14,
        "default_billing_cycle": "quarterly"
    }'::jsonb
)
ON CONFLICT (product_code)
DO UPDATE SET
    product_name = EXCLUDED.product_name,
    billing_config = EXCLUDED.billing_config,
    config_version = EXCLUDED.config_version,
    updated_at = NOW();

-- ============================================================================
-- 2. FAMILYKNOWS PRODUCT CONFIG
-- ============================================================================
INSERT INTO t_bm_product_config (
    product_code,
    product_name,
    config_version,
    is_active,
    billing_config
)
VALUES (
    'familyknows',
    'FamilyKnows',
    '1.0',
    true,
    '{
        "plan_types": [
            {
                "code": "per_family",
                "label": "Per Family",
                "metric": "family_members",
                "description": "Pricing based on family size"
            }
        ],
        "features": [
            {
                "id": "assets",
                "name": "Assets",
                "description": "Number of assets that can be tracked",
                "type": "limit",
                "default": 100,
                "trial": 25,
                "unit": "assets"
            },
            {
                "id": "family_members",
                "name": "Family Members",
                "description": "Number of family members that can be added",
                "type": "limit",
                "default": 4,
                "trial": 1,
                "unit": "members"
            },
            {
                "id": "nominees",
                "name": "Nominees",
                "description": "Number of nominees per asset",
                "type": "limit",
                "default": 5,
                "trial": 1,
                "unit": "nominees"
            },
            {
                "id": "documents",
                "name": "Documents",
                "description": "Number of documents that can be stored",
                "type": "limit",
                "default": 50,
                "trial": 5,
                "unit": "documents"
            },
            {
                "id": "ai_insights",
                "name": "AI Insights",
                "description": "AI-powered family insights and recommendations",
                "type": "addon",
                "default": 1,
                "trial": 0,
                "base_price": 100,
                "currency": "INR"
            }
        ],
        "tier_templates": {
            "per_family": [
                {"min": 1, "max": 1, "label": "Free (1 member)"},
                {"min": 2, "max": 4, "label": "Family of 4"},
                {"min": 5, "max": 8, "label": "Family of 8"},
                {"min": 9, "max": null, "label": "Large Family (9+)"}
            ]
        },
        "notifications": [
            {
                "channel": "email",
                "name": "Email Notifications",
                "description": "Email message notifications",
                "unit_price": 0.5,
                "default_credits": 50,
                "currency": "INR"
            },
            {
                "channel": "whatsapp",
                "name": "WhatsApp Notifications",
                "description": "WhatsApp message notifications",
                "unit_price": 2.0,
                "default_credits": 10,
                "currency": "INR"
            }
        ],
        "trial_options": [14, 30],
        "billing_cycles": ["monthly", "annual"],
        "default_trial_days": 14,
        "default_billing_cycle": "monthly",
        "free_tier": {
            "enabled": true,
            "limits": {
                "family_members": 1,
                "assets": 25,
                "documents": 5,
                "nominees": 1
            }
        }
    }'::jsonb
)
ON CONFLICT (product_code)
DO UPDATE SET
    product_name = EXCLUDED.product_name,
    billing_config = EXCLUDED.billing_config,
    config_version = EXCLUDED.config_version,
    updated_at = NOW();

-- ============================================================================
-- 3. KALADRISTI PRODUCT CONFIG (Placeholder for Day 60-70)
-- ============================================================================
INSERT INTO t_bm_product_config (
    product_code,
    product_name,
    config_version,
    is_active,
    billing_config
)
VALUES (
    'kaladristi',
    'Kaladristi',
    '1.0',
    false,  -- Not active yet
    '{
        "plan_types": [
            {
                "code": "subscription_usage",
                "label": "Subscription + Usage",
                "metric": "reports",
                "description": "Base subscription plus per-report charges"
            }
        ],
        "features": [
            {
                "id": "reports",
                "name": "AI Reports",
                "description": "Number of AI research reports",
                "type": "usage",
                "default": 10,
                "trial": 2,
                "unit_price": 50,
                "currency": "INR"
            },
            {
                "id": "watchlists",
                "name": "Watchlists",
                "description": "Number of stock watchlists",
                "type": "limit",
                "default": 5,
                "trial": 1,
                "unit": "watchlists"
            },
            {
                "id": "alerts",
                "name": "Price Alerts",
                "description": "Number of active price alerts",
                "type": "limit",
                "default": 20,
                "trial": 5,
                "unit": "alerts"
            },
            {
                "id": "portfolio_tracking",
                "name": "Portfolio Tracking",
                "description": "Track investment portfolio",
                "type": "boolean",
                "default": true,
                "trial": true
            }
        ],
        "tier_templates": {
            "subscription_usage": [
                {"min": 1, "max": 1, "label": "Basic", "base_price": 100},
                {"min": 2, "max": 2, "label": "Pro", "base_price": 500},
                {"min": 3, "max": 3, "label": "Premium", "base_price": 1000}
            ]
        },
        "notifications": [
            {
                "channel": "email",
                "name": "Email Alerts",
                "description": "Email notifications for price alerts",
                "unit_price": 0.5,
                "default_credits": 100,
                "currency": "INR"
            }
        ],
        "trial_options": [7, 14],
        "billing_cycles": ["monthly"],
        "default_trial_days": 7,
        "default_billing_cycle": "monthly"
    }'::jsonb
)
ON CONFLICT (product_code)
DO UPDATE SET
    product_name = EXCLUDED.product_name,
    billing_config = EXCLUDED.billing_config,
    config_version = EXCLUDED.config_version,
    is_active = EXCLUDED.is_active,
    updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERIES (Run after migration)
-- ============================================================================
-- SELECT product_code, product_name, config_version, is_active,
--        jsonb_array_length(billing_config->'features') as feature_count,
--        billing_config->'plan_types' as plan_types
-- FROM t_bm_product_config;

-- Expected output:
-- product_code  | product_name  | config_version | is_active | feature_count | plan_types
-- -------------+---------------+----------------+-----------+---------------+------------
-- contractnest | ContractNest  | 1.0            | true      | 8             | [per_user, per_contract]
-- familyknows  | FamilyKnows   | 1.0            | true      | 5             | [per_family]
-- kaladristi   | Kaladristi    | 1.0            | false     | 4             | [subscription_usage]
