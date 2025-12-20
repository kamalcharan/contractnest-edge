# JTD Framework Migrations

## Overview

JTD (Jobs To Do) is the core event/task framework for ContractNest. It handles:
- **Notifications**: Email, SMS, WhatsApp, Push, In-App
- **Appointments**: Scheduling, reminders, confirmations
- **Tasks**: Action items and to-dos
- **Service Visits**: Scheduled maintenance/repair visits
- **Reminders**: Automated reminders for various events

## VaNi Integration

VaNi is the AI Agent that can automatically execute JTD jobs when enabled for a tenant.

- **Without VaNi**: Users see standard screens (Appointments, Tasks) and manually act on items
- **With VaNi**: VaNi auto-executes jobs based on configuration, showing what it has done/will do

## Migration Files

| File | Description |
|------|-------------|
| `001_create_jtd_master_tables.sql` | Creates all JTD tables, indexes, triggers |
| `002_seed_jtd_master_data.sql` | Seeds master data (event types, channels, statuses, templates) |

## Tables Created

### Master Tables (Global)

| Table | Description |
|-------|-------------|
| `n_system_actors` | System users: VaNi, System, Webhook |
| `n_jtd_event_types` | Event types: notification, appointment, task, etc. |
| `n_jtd_channels` | Channels: email, sms, whatsapp, push, inapp |
| `n_jtd_statuses` | Status definitions with classification |
| `n_jtd_status_flows` | Valid status transitions per event type |
| `n_jtd_source_types` | What triggers JTD creation |
| `n_jtd_templates` | Message templates (system + tenant-specific) |

### Tenant Tables

| Table | Description |
|-------|-------------|
| `n_jtd_tenant_config` | Per-tenant settings (VaNi enabled, channels, limits) |
| `n_jtd_tenant_source_config` | Per-tenant overrides per source type |

### Transactional Tables

| Table | Description |
|-------|-------------|
| `n_jtd` | Main JTD records |
| `n_jtd_history` | Audit trail for changes |

## System Actor IDs

| Actor | UUID | Code |
|-------|------|------|
| VaNi | `00000000-0000-0000-0000-000000000001` | `vani` |
| System | `00000000-0000-0000-0000-000000000002` | `system` |
| Webhook | `00000000-0000-0000-0000-000000000003` | `webhook` |

## Status Flow

Status transitions are **soft-enforced**:
- Valid transitions are defined in `n_jtd_status_flows`
- Invalid transitions are allowed but flagged (`is_valid_transition = false`)
- All status changes are logged in `n_jtd_history`

### Notification Flow
```
created → pending → queued → executing → sent → delivered → read
                                            ↓
                                          failed → pending (retry)
```

### Appointment Flow
```
created → scheduled → reminded → confirmed → in_progress → completed
                   ↓                    ↓
              rescheduled           no_show
```

## Running Migrations

```bash
# Via Supabase CLI
supabase db push

# Or manually
psql -h <host> -U postgres -d postgres -f 001_create_jtd_master_tables.sql
psql -h <host> -U postgres -d postgres -f 002_seed_jtd_master_data.sql
```

## Usage Example

```sql
-- Create a JTD for user invitation
INSERT INTO n_jtd (
    tenant_id,
    event_type_code,
    channel_code,
    source_type_code,
    source_id,
    recipient_type,
    recipient_name,
    recipient_contact,
    payload,
    template_key,
    performed_by_type,
    performed_by_id,
    performed_by_name
) VALUES (
    'tenant-uuid',
    'notification',
    'email',
    'user_invite',
    'invitation-uuid',
    'user',
    'John Doe',
    'john@example.com',
    '{"inviter_name": "Jane Smith", "tenant_name": "Acme Corp", "invite_link": "https://..."}',
    'user_invite_email_v1',
    'vani',
    '00000000-0000-0000-0000-000000000001',
    'VaNi'
);
```

## Next Steps

1. **PGMQ Integration**: Add queue processing for high-volume scenarios
2. **JTD Service**: Create API service layer in contractnest-api
3. **User Invite Integration**: Connect existing invite flow to JTD
4. **VaNi UI Integration**: Connect VaNi UI to real JTD data
