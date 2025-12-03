# Sequence Numbers Feature - Database Migrations

## Overview

This folder contains SQL migrations for the **Sequence Numbers** feature in ContractNest.

The feature provides:
- Dynamic, configurable sequence number generation (CT-0001, INV-10001, etc.)
- Per-tenant, per-environment (live/test) sequence tracking
- Automatic resets (yearly, monthly, quarterly, or never)
- Integration with existing Category (ProductMasterdata) system

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DATA ARCHITECTURE                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  t_category_master                                                  │
│  ├── category_name: 'sequence_numbers'                              │
│  └── display_name: 'Sequence Numbers'                               │
│                                                                     │
│  t_category_details (linked to above)                               │
│  ├── sub_cat_name: 'CONTACT', 'INVOICE', 'CONTRACT', etc.          │
│  └── form_settings: { prefix, separator, padding_length, ... }      │
│                                                                     │
│  t_sequence_counters (NEW TABLE)                                    │
│  ├── sequence_type_id: FK to t_category_details                     │
│  ├── current_value: Runtime counter                                 │
│  └── last_reset_date: For yearly/monthly resets                     │
│                                                                     │
│  t_contacts (ALTERED)                                               │
│  └── contact_number: 'CT-1001' (auto-generated)                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Migration Files

| File | Description |
|------|-------------|
| `001_create_t_sequence_counters.sql` | Creates the runtime counters table with RLS |
| `002_seed_sequence_numbers_category.sql` | Seeds category_master and category_details |
| `003_alter_t_contacts_add_contact_number.sql` | Adds contact_number column to t_contacts |
| `004_sequence_reset_functions.sql` | Functions for automatic/manual sequence resets |

## Execution Order

**IMPORTANT**: Run migrations in order!

```bash
# Connect to your Supabase database
psql "postgresql://postgres:[password]@[host]:5432/postgres"

# Run migrations in order
\i 001_create_t_sequence_counters.sql
\i 002_seed_sequence_numbers_category.sql
\i 003_alter_t_contacts_add_contact_number.sql
\i 004_sequence_reset_functions.sql
```

## Post-Migration Steps

### 1. Seed sequences for existing tenants

```sql
-- For each existing tenant, run:
SELECT public.seed_sequence_numbers_for_tenant(
    'YOUR_TENANT_UUID'::uuid
);
```

### 2. Backfill contact_numbers for existing contacts

```sql
-- For each tenant with existing contacts:
SELECT public.backfill_contact_numbers(
    'YOUR_TENANT_UUID'::uuid,
    true  -- is_live
);
```

### 3. Verify setup

```sql
-- Check sequence status for a tenant:
SELECT public.get_sequence_status(
    'YOUR_TENANT_UUID'::uuid,
    true
);

-- Test sequence generation:
SELECT public.get_next_formatted_sequence(
    'CONTACT',
    'YOUR_TENANT_UUID'::uuid,
    true
);
```

## Key Functions

### `get_next_formatted_sequence(code, tenant_id, is_live)`

Gets the next sequence number and formats it.

```sql
SELECT public.get_next_formatted_sequence('CONTACT', 'tenant-uuid', true);
-- Returns: {"formatted": "CT-1001", "sequence": 1001, "prefix": "CT", ...}
```

### `manual_reset_sequence(code, tenant_id, is_live, new_start_value)`

Manually resets a sequence.

```sql
SELECT public.manual_reset_sequence('INVOICE', 'tenant-uuid', true);
-- Resets to start_value from config

SELECT public.manual_reset_sequence('INVOICE', 'tenant-uuid', true, 50001);
-- Resets to custom value 50001
```

### `get_sequence_status(tenant_id, is_live)`

Gets status of all sequences for a tenant.

```sql
SELECT public.get_sequence_status('tenant-uuid', true);
-- Returns array of all sequence configs with current values
```

### `seed_sequence_numbers_for_tenant(tenant_id)`

Seeds default sequences for a new tenant (call during onboarding).

```sql
SELECT public.seed_sequence_numbers_for_tenant('new-tenant-uuid');
```

## RLS Policies

The `t_sequence_counters` table has Row Level Security enabled:

- **SELECT**: `tenant_id = current_setting('app.current_tenant_id')::uuid`
- **INSERT**: `tenant_id = current_setting('app.current_tenant_id')::uuid`
- **UPDATE**: `tenant_id = current_setting('app.current_tenant_id')::uuid`
- **DELETE**: `tenant_id = current_setting('app.current_tenant_id')::uuid`

## form_settings Schema

The `form_settings` JSONB in `t_category_details` contains:

```json
{
  "prefix": "CT",           // Prefix for the ID
  "separator": "-",         // Separator between prefix and number
  "suffix": "",             // Optional suffix
  "padding_length": 4,      // Zero-padding length (4 = 0001)
  "start_value": 1001,      // Initial/reset value
  "reset_frequency": "NEVER", // NEVER, YEARLY, MONTHLY, QUARTERLY
  "increment_by": 1         // Increment step (usually 1)
}
```

## Default Sequence Types

| Code | Display Name | Prefix | Padding | Reset |
|------|-------------|--------|---------|-------|
| CONTACT | Contact Number | CT | 4 | NEVER |
| CONTRACT | Contract Number | CN | 4 | YEARLY |
| INVOICE | Invoice Number | INV | 5 | YEARLY |
| QUOTATION | Quotation Number | QT | 4 | YEARLY |
| RECEIPT | Receipt Number | RCP | 5 | YEARLY |
| PROJECT | Project Number | PRJ | 4 | YEARLY |
| TASK | Task Number | TSK | 5 | NEVER |
| TICKET | Support Ticket | TKT | 5 | YEARLY |

## Troubleshooting

### Sequence not found error

```sql
-- Verify sequence exists for tenant:
SELECT * FROM public.t_category_details cd
JOIN public.t_category_master cm ON cd.category_id = cm.id
WHERE cm.category_name = 'sequence_numbers'
  AND cd.tenant_id = 'YOUR_TENANT_UUID';

-- If empty, seed sequences:
SELECT public.seed_sequence_numbers_for_tenant('YOUR_TENANT_UUID');
```

### Contact numbers not generating

```sql
-- Check trigger exists:
SELECT * FROM pg_trigger WHERE tgname = 'trg_auto_contact_number';

-- Check sequence counter exists:
SELECT * FROM public.t_sequence_counters
WHERE tenant_id = 'YOUR_TENANT_UUID';
```

### Reset not working

```sql
-- Check last_reset_date:
SELECT last_reset_date, current_value
FROM public.t_sequence_counters
WHERE tenant_id = 'YOUR_TENANT_UUID';

-- Manual reset:
SELECT public.manual_reset_sequence('INVOICE', 'YOUR_TENANT_UUID', true);
```
