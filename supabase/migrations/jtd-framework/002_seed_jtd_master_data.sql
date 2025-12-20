-- ============================================================
-- Migration: 002_seed_jtd_master_data
-- Description: Seed master data for JTD framework
-- Author: Claude
-- Date: 2025-12-17
-- Updated: Statuses now per event type, status flows use UUID references
-- ============================================================

-- ============================================================
-- 1. SYSTEM ACTORS
-- ============================================================

INSERT INTO public.n_system_actors (id, code, name, description, avatar_url, is_active) VALUES
    ('00000000-0000-0000-0000-000000000001', 'vani', 'VaNi', 'AI Agent for automated task execution', '/avatars/vani.png', true),
    ('00000000-0000-0000-0000-000000000002', 'system', 'System', 'System-generated events and actions', '/avatars/system.png', true),
    ('00000000-0000-0000-0000-000000000003', 'webhook', 'Webhook', 'External webhook triggers', '/avatars/webhook.png', true)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description;

-- ============================================================
-- 2. EVENT TYPES
-- ============================================================

INSERT INTO public.n_jtd_event_types (
    code, name, description, category, icon, color,
    allowed_channels, supports_scheduling, supports_recurrence, supports_batch,
    default_priority, default_max_retries, retry_delay_seconds, display_order, is_active
) VALUES
    -- Communication events
    ('notification', 'Notification', 'Send notifications via various channels', 'communication',
     'Bell', '#3B82F6', ARRAY['email', 'sms', 'whatsapp', 'push', 'inapp'],
     false, false, true, 5, 3, 300, 1, true),

    ('reminder', 'Reminder', 'Reminders for various events', 'communication',
     'Clock', '#EC4899', ARRAY['email', 'sms', 'whatsapp', 'push', 'inapp'],
     true, true, true, 6, 3, 300, 2, true),

    -- Scheduling events
    ('appointment', 'Appointment', 'Scheduled appointments and meetings', 'scheduling',
     'Calendar', '#10B981', ARRAY['email', 'sms', 'whatsapp', 'inapp'],
     true, false, false, 7, 3, 300, 3, true),

    ('service_visit', 'Service Visit', 'Scheduled service visits for maintenance/repair', 'scheduling',
     'Truck', '#8B5CF6', ARRAY['email', 'sms', 'whatsapp'],
     true, true, false, 8, 3, 300, 4, true),

    -- Action events
    ('task', 'Task', 'Action items and tasks to be completed', 'action',
     'CheckSquare', '#F59E0B', ARRAY['inapp', 'email'],
     true, false, false, 5, 0, 0, 5, true),

    -- Payment events
    ('payment', 'Payment', 'Payment related notifications and confirmations', 'communication',
     'CreditCard', '#14B8A6', ARRAY['email', 'sms', 'whatsapp'],
     false, false, true, 8, 3, 300, 6, true),

    -- Document events
    ('document', 'Document', 'Document sharing and signature requests', 'communication',
     'FileText', '#6366F1', ARRAY['email', 'inapp'],
     false, false, false, 6, 3, 600, 7, true)

ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    allowed_channels = EXCLUDED.allowed_channels;

-- ============================================================
-- 3. CHANNELS
-- ============================================================

INSERT INTO public.n_jtd_channels (
    code, name, description, icon, color,
    default_provider, default_cost_per_unit, rate_limit_per_minute,
    supports_templates, supports_attachments, supports_rich_content,
    max_content_length, has_delivery_confirmation, has_read_receipt, display_order, is_active
) VALUES
    ('email', 'Email', 'Email notifications with rich formatting', 'Mail', '#3B82F6',
     'msg91', 0.25, 100,
     true, true, true, 50000, true, true, 1, true),

    ('sms', 'SMS', 'Short text messages (160 chars)', 'MessageSquare', '#10B981',
     'msg91', 0.75, 50,
     true, false, false, 160, true, false, 2, true),

    ('whatsapp', 'WhatsApp', 'WhatsApp Business messages', 'Phone', '#25D366',
     'msg91', 0.50, 30,
     true, true, true, 4096, true, true, 3, true),

    ('push', 'Push', 'Mobile push notifications', 'Bell', '#F59E0B',
     'firebase', 0.01, 500,
     true, false, false, 256, true, false, 4, true),

    ('inapp', 'In-App', 'In-app notifications and alerts', 'Inbox', '#8B5CF6',
     'internal', 0.00, 1000,
     true, false, true, 1000, true, true, 5, true)

ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    default_provider = EXCLUDED.default_provider,
    default_cost_per_unit = EXCLUDED.default_cost_per_unit;

-- ============================================================
-- 4. STATUSES (Per Event Type)
-- Note: Each event type has its own set of statuses
-- ============================================================

-- Clear existing statuses to reinsert with proper structure
DELETE FROM public.n_jtd_status_flows;
DELETE FROM public.n_jtd_statuses;

-- ─────────────────────────────────────────────────────────────
-- NOTIFICATION Statuses
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('notification', 'created', 'Created', 'Notification created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('notification', 'pending', 'Pending', 'Waiting to be processed', 'progress', 'Clock', 'blue', false, false, false, false, false, 2, true),
    ('notification', 'queued', 'Queued', 'Added to PGMQ queue', 'progress', 'List', 'blue', false, false, false, false, false, 3, true),
    ('notification', 'executing', 'Executing', 'Being processed by worker', 'progress', 'Loader', 'yellow', false, false, false, false, false, 4, true),
    ('notification', 'sent', 'Sent', 'Sent to provider', 'progress', 'Send', 'blue', false, false, false, false, false, 5, true),
    ('notification', 'delivered', 'Delivered', 'Delivered to recipient', 'success', 'Check', 'green', false, true, true, false, false, 6, true),
    ('notification', 'read', 'Read', 'Read by recipient', 'success', 'Eye', 'green', false, true, true, false, false, 7, true),
    ('notification', 'failed', 'Failed', 'Failed to deliver', 'failure', 'X', 'red', false, false, false, true, true, 8, true),
    ('notification', 'bounced', 'Bounced', 'Message bounced', 'failure', 'RotateCcw', 'red', false, true, false, true, false, 9, true),
    ('notification', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 10, true);

-- ─────────────────────────────────────────────────────────────
-- REMINDER Statuses (similar to notification but with scheduling)
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('reminder', 'created', 'Created', 'Reminder created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('reminder', 'scheduled', 'Scheduled', 'Scheduled for future', 'progress', 'Calendar', 'blue', false, false, false, false, false, 2, true),
    ('reminder', 'pending', 'Pending', 'Ready to process', 'progress', 'Clock', 'blue', false, false, false, false, false, 3, true),
    ('reminder', 'queued', 'Queued', 'In queue', 'progress', 'List', 'blue', false, false, false, false, false, 4, true),
    ('reminder', 'executing', 'Executing', 'Processing', 'progress', 'Loader', 'yellow', false, false, false, false, false, 5, true),
    ('reminder', 'sent', 'Sent', 'Sent', 'progress', 'Send', 'blue', false, false, false, false, false, 6, true),
    ('reminder', 'delivered', 'Delivered', 'Delivered', 'success', 'Check', 'green', false, true, true, false, false, 7, true),
    ('reminder', 'read', 'Read', 'Read', 'success', 'Eye', 'green', false, true, true, false, false, 8, true),
    ('reminder', 'failed', 'Failed', 'Failed', 'failure', 'X', 'red', false, false, false, true, true, 9, true),
    ('reminder', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 10, true);

-- ─────────────────────────────────────────────────────────────
-- APPOINTMENT Statuses
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('appointment', 'created', 'Created', 'Appointment created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('appointment', 'scheduled', 'Scheduled', 'Scheduled', 'progress', 'Calendar', 'blue', false, false, false, false, false, 2, true),
    ('appointment', 'reminded', 'Reminded', 'Reminder sent', 'progress', 'Bell', 'blue', false, false, false, false, false, 3, true),
    ('appointment', 'confirmed', 'Confirmed', 'Confirmed by customer', 'progress', 'CheckCircle', 'green', false, false, false, false, false, 4, true),
    ('appointment', 'in_progress', 'In Progress', 'Appointment started', 'progress', 'Play', 'yellow', false, false, false, false, false, 5, true),
    ('appointment', 'completed', 'Completed', 'Completed successfully', 'success', 'CheckCircle', 'green', false, true, true, false, false, 6, true),
    ('appointment', 'rescheduled', 'Rescheduled', 'Rescheduled to new time', 'progress', 'RefreshCw', 'blue', false, false, false, false, false, 7, true),
    ('appointment', 'no_show', 'No Show', 'Customer did not show', 'failure', 'UserX', 'red', false, true, false, true, false, 8, true),
    ('appointment', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 9, true);

-- ─────────────────────────────────────────────────────────────
-- SERVICE VISIT Statuses
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('service_visit', 'created', 'Created', 'Service visit created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('service_visit', 'scheduled', 'Scheduled', 'Scheduled', 'progress', 'Calendar', 'blue', false, false, false, false, false, 2, true),
    ('service_visit', 'reminded', 'Reminded', 'Reminder sent', 'progress', 'Bell', 'blue', false, false, false, false, false, 3, true),
    ('service_visit', 'confirmed', 'Confirmed', 'Confirmed', 'progress', 'CheckCircle', 'green', false, false, false, false, false, 4, true),
    ('service_visit', 'dispatched', 'Dispatched', 'Technician dispatched', 'progress', 'Truck', 'yellow', false, false, false, false, false, 5, true),
    ('service_visit', 'in_progress', 'In Progress', 'Service in progress', 'progress', 'Play', 'yellow', false, false, false, false, false, 6, true),
    ('service_visit', 'completed', 'Completed', 'Service completed', 'success', 'CheckCircle', 'green', false, true, true, false, false, 7, true),
    ('service_visit', 'rescheduled', 'Rescheduled', 'Rescheduled', 'progress', 'RefreshCw', 'blue', false, false, false, false, false, 8, true),
    ('service_visit', 'no_show', 'No Show', 'Customer not available', 'failure', 'UserX', 'red', false, true, false, true, false, 9, true),
    ('service_visit', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 10, true);

-- ─────────────────────────────────────────────────────────────
-- TASK Statuses
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('task', 'created', 'Created', 'Task created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('task', 'pending', 'Pending', 'Waiting to be picked up', 'progress', 'Clock', 'blue', false, false, false, false, false, 2, true),
    ('task', 'assigned', 'Assigned', 'Assigned to someone', 'progress', 'User', 'blue', false, false, false, false, false, 3, true),
    ('task', 'in_progress', 'In Progress', 'Being worked on', 'progress', 'Play', 'yellow', false, false, false, false, false, 4, true),
    ('task', 'blocked', 'Blocked', 'Blocked by dependency', 'progress', 'AlertCircle', 'red', false, false, false, false, false, 5, true),
    ('task', 'completed', 'Completed', 'Completed', 'success', 'CheckCircle', 'green', false, true, true, false, false, 6, true),
    ('task', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 7, true);

-- ─────────────────────────────────────────────────────────────
-- PAYMENT Statuses
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('payment', 'created', 'Created', 'Payment notification created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('payment', 'pending', 'Pending', 'Pending', 'progress', 'Clock', 'blue', false, false, false, false, false, 2, true),
    ('payment', 'queued', 'Queued', 'Queued', 'progress', 'List', 'blue', false, false, false, false, false, 3, true),
    ('payment', 'executing', 'Executing', 'Processing', 'progress', 'Loader', 'yellow', false, false, false, false, false, 4, true),
    ('payment', 'sent', 'Sent', 'Sent', 'progress', 'Send', 'blue', false, false, false, false, false, 5, true),
    ('payment', 'delivered', 'Delivered', 'Delivered', 'success', 'Check', 'green', false, true, true, false, false, 6, true),
    ('payment', 'read', 'Read', 'Read', 'success', 'Eye', 'green', false, true, true, false, false, 7, true),
    ('payment', 'failed', 'Failed', 'Failed', 'failure', 'X', 'red', false, false, false, true, true, 8, true),
    ('payment', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 9, true);

-- ─────────────────────────────────────────────────────────────
-- DOCUMENT Statuses
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    icon, color, is_initial, is_terminal, is_success, is_failure, allows_retry, display_order, is_active
) VALUES
    ('document', 'created', 'Created', 'Document notification created', 'initial', 'Plus', 'gray', true, false, false, false, false, 1, true),
    ('document', 'pending', 'Pending', 'Pending', 'progress', 'Clock', 'blue', false, false, false, false, false, 2, true),
    ('document', 'sent', 'Sent', 'Document sent', 'progress', 'Send', 'blue', false, false, false, false, false, 3, true),
    ('document', 'delivered', 'Delivered', 'Delivered', 'progress', 'Check', 'green', false, false, false, false, false, 4, true),
    ('document', 'viewed', 'Viewed', 'Document viewed', 'progress', 'Eye', 'blue', false, false, false, false, false, 5, true),
    ('document', 'signed', 'Signed', 'Document signed', 'success', 'FileCheck', 'green', false, true, true, false, false, 6, true),
    ('document', 'rejected', 'Rejected', 'Document rejected', 'failure', 'FileX', 'red', false, true, false, true, false, 7, true),
    ('document', 'expired', 'Expired', 'Document expired', 'terminal', 'Clock', 'gray', false, true, false, false, false, 8, true),
    ('document', 'cancelled', 'Cancelled', 'Cancelled', 'terminal', 'XCircle', 'gray', false, true, false, false, false, 9, true);

-- ============================================================
-- 5. STATUS FLOWS (Using UUIDs from inserted statuses)
-- ============================================================

-- NOTIFICATION FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'notification', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'pending', true),
    ('created', 'cancelled', false),
    ('pending', 'queued', true),
    ('pending', 'cancelled', false),
    ('queued', 'executing', true),
    ('queued', 'failed', true),
    ('executing', 'sent', true),
    ('executing', 'failed', true),
    ('sent', 'delivered', true),
    ('sent', 'failed', true),
    ('sent', 'bounced', true),
    ('delivered', 'read', true),
    ('failed', 'pending', false)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'notification' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'notification' AND t.code = flow.to_code;

-- REMINDER FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'reminder', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'scheduled', true),
    ('created', 'pending', true),
    ('created', 'cancelled', false),
    ('scheduled', 'pending', true),
    ('scheduled', 'cancelled', false),
    ('pending', 'queued', true),
    ('queued', 'executing', true),
    ('executing', 'sent', true),
    ('executing', 'failed', true),
    ('sent', 'delivered', true),
    ('sent', 'failed', true),
    ('delivered', 'read', true),
    ('failed', 'pending', false)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'reminder' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'reminder' AND t.code = flow.to_code;

-- APPOINTMENT FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'appointment', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'scheduled', true),
    ('created', 'cancelled', false),
    ('scheduled', 'reminded', true),
    ('scheduled', 'confirmed', false),
    ('scheduled', 'rescheduled', false),
    ('scheduled', 'cancelled', false),
    ('reminded', 'confirmed', false),
    ('reminded', 'cancelled', false),
    ('confirmed', 'in_progress', true),
    ('confirmed', 'no_show', false),
    ('confirmed', 'rescheduled', false),
    ('confirmed', 'cancelled', false),
    ('in_progress', 'completed', false),
    ('rescheduled', 'scheduled', true)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'appointment' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'appointment' AND t.code = flow.to_code;

-- SERVICE VISIT FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'service_visit', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'scheduled', true),
    ('created', 'cancelled', false),
    ('scheduled', 'reminded', true),
    ('scheduled', 'confirmed', false),
    ('scheduled', 'rescheduled', false),
    ('scheduled', 'cancelled', false),
    ('reminded', 'confirmed', false),
    ('confirmed', 'dispatched', false),
    ('confirmed', 'cancelled', false),
    ('dispatched', 'in_progress', false),
    ('dispatched', 'no_show', false),
    ('in_progress', 'completed', false),
    ('rescheduled', 'scheduled', true)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'service_visit' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'service_visit' AND t.code = flow.to_code;

-- TASK FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'task', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'pending', true),
    ('created', 'assigned', false),
    ('created', 'cancelled', false),
    ('pending', 'assigned', false),
    ('pending', 'in_progress', false),
    ('pending', 'cancelled', false),
    ('assigned', 'in_progress', false),
    ('assigned', 'cancelled', false),
    ('in_progress', 'blocked', false),
    ('in_progress', 'completed', false),
    ('in_progress', 'cancelled', false),
    ('blocked', 'in_progress', false)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'task' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'task' AND t.code = flow.to_code;

-- PAYMENT FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'payment', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'pending', true),
    ('created', 'cancelled', false),
    ('pending', 'queued', true),
    ('queued', 'executing', true),
    ('executing', 'sent', true),
    ('executing', 'failed', true),
    ('sent', 'delivered', true),
    ('sent', 'failed', true),
    ('delivered', 'read', true),
    ('failed', 'pending', false)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'payment' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'payment' AND t.code = flow.to_code;

-- DOCUMENT FLOWS
INSERT INTO public.n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_automatic, is_active)
SELECT 'document', f.id, t.id, flow.is_automatic, true
FROM (VALUES
    ('created', 'pending', true),
    ('created', 'cancelled', false),
    ('pending', 'sent', true),
    ('sent', 'delivered', true),
    ('delivered', 'viewed', true),
    ('viewed', 'signed', false),
    ('viewed', 'rejected', false),
    ('delivered', 'expired', true),
    ('viewed', 'expired', true)
) AS flow(from_code, to_code, is_automatic)
JOIN public.n_jtd_statuses f ON f.event_type_code = 'document' AND f.code = flow.from_code
JOIN public.n_jtd_statuses t ON t.event_type_code = 'document' AND t.code = flow.to_code;

-- ============================================================
-- 6. SOURCE TYPES
-- ============================================================

INSERT INTO public.n_jtd_source_types (
    code, name, description, default_event_type, source_table, source_id_field, default_channels, payload_mapping, is_active
) VALUES
    -- User related
    ('user_invite', 'User Invitation', 'Invitation sent to new user to join tenant', 'notification',
     't_user_invitations', 'id', ARRAY['email'],
     '{"recipient_name": "$.email", "inviter_name": "$.inviter.full_name", "tenant_name": "$.tenant.name", "invite_link": "$.invite_link"}'::jsonb, true),

    ('user_created', 'User Created', 'New user successfully joined the tenant', 'notification',
     't_user_tenants', 'id', ARRAY['email', 'inapp'],
     '{"user_name": "$.user.full_name", "tenant_name": "$.tenant.name"}'::jsonb, true),

    ('user_role_changed', 'User Role Changed', 'User role has been updated', 'notification',
     't_user_tenants', 'id', ARRAY['email', 'inapp'],
     '{"user_name": "$.user.full_name", "old_role": "$.old_role", "new_role": "$.new_role"}'::jsonb, true),

    -- Contract related
    ('contract_created', 'Contract Created', 'New contract has been created', 'notification',
     't_contracts', 'id', ARRAY['email'],
     '{"contract_number": "$.contract_number", "customer_name": "$.customer.name", "amount": "$.total_amount"}'::jsonb, true),

    ('contract_signed', 'Contract Signed', 'Contract has been signed by all parties', 'notification',
     't_contracts', 'id', ARRAY['email'],
     '{"contract_number": "$.contract_number", "signed_by": "$.signed_by.name"}'::jsonb, true),

    -- Service related
    ('service_scheduled', 'Service Scheduled', 'Service visit has been scheduled', 'service_visit',
     't_services', 'id', ARRAY['email', 'sms'],
     '{"service_date": "$.scheduled_date", "service_type": "$.service_type", "customer_name": "$.customer.name", "address": "$.address"}'::jsonb, true),

    ('service_reminder', 'Service Reminder', 'Reminder for upcoming service visit', 'reminder',
     't_services', 'id', ARRAY['email', 'sms', 'whatsapp'],
     '{"service_date": "$.scheduled_date", "service_type": "$.service_type", "customer_name": "$.customer.name"}'::jsonb, true),

    ('service_completed', 'Service Completed', 'Service visit has been completed', 'notification',
     't_services', 'id', ARRAY['email'],
     '{"service_date": "$.completed_date", "service_type": "$.service_type", "technician": "$.technician.name"}'::jsonb, true),

    -- Appointment related
    ('appointment_created', 'Appointment Created', 'New appointment has been scheduled', 'appointment',
     't_appointments', 'id', ARRAY['email', 'sms'],
     '{"appointment_date": "$.scheduled_at", "appointment_type": "$.type", "with_whom": "$.with_user.name"}'::jsonb, true),

    ('appointment_reminder', 'Appointment Reminder', 'Reminder for upcoming appointment', 'reminder',
     't_appointments', 'id', ARRAY['email', 'sms', 'whatsapp'],
     '{"appointment_date": "$.scheduled_at", "appointment_type": "$.type"}'::jsonb, true),

    -- Payment related
    ('payment_due', 'Payment Due', 'Payment due reminder', 'reminder',
     't_invoices', 'id', ARRAY['email', 'sms'],
     '{"invoice_number": "$.invoice_number", "amount": "$.amount_due", "due_date": "$.due_date"}'::jsonb, true),

    ('payment_received', 'Payment Received', 'Payment confirmation received', 'notification',
     't_payments', 'id', ARRAY['email'],
     '{"payment_amount": "$.amount", "payment_date": "$.payment_date", "invoice_number": "$.invoice.number"}'::jsonb, true),

    ('payment_overdue', 'Payment Overdue', 'Payment is overdue', 'notification',
     't_invoices', 'id', ARRAY['email', 'sms'],
     '{"invoice_number": "$.invoice_number", "amount": "$.amount_due", "days_overdue": "$.days_overdue"}'::jsonb, true),

    -- Manual/System
    ('manual', 'Manual', 'Manually created JTD by user', 'task',
     NULL, NULL, ARRAY[]::TEXT[], NULL, true),

    ('system', 'System', 'System-generated JTD', 'notification',
     NULL, NULL, ARRAY['inapp'], NULL, true)

ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    default_channels = EXCLUDED.default_channels;

-- ============================================================
-- 7. SYSTEM TEMPLATES (tenant_id = NULL, is_live = NULL)
-- ============================================================

INSERT INTO public.n_jtd_templates (
    tenant_id, template_key, name, description,
    channel_code, source_type_code, subject, content, content_html, variables, is_live, is_active
) VALUES
    -- USER INVITE - EMAIL
    (NULL, 'user_invite_email_v1', 'User Invitation Email', 'Default email template for user invitations',
     'email', 'user_invite',
     'You''re invited to join {{tenant_name}} on ContractNest',
     E'Hi {{recipient_name}},\n\n{{inviter_name}} has invited you to join {{tenant_name}} on ContractNest.\n\nClick the link below to accept your invitation:\n{{invite_link}}\n\nThis invitation will expire in 48 hours.\n\nBest regards,\nThe ContractNest Team',
     E'<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">\n  <h2 style="color: #3B82F6;">You''re Invited!</h2>\n  <p>Hi {{recipient_name}},</p>\n  <p><strong>{{inviter_name}}</strong> has invited you to join <strong>{{tenant_name}}</strong> on ContractNest.</p>\n  <p style="margin: 30px 0;">\n    <a href="{{invite_link}}" style="background-color: #3B82F6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Accept Invitation</a>\n  </p>\n  <p style="color: #666; font-size: 14px;">This invitation will expire in 48 hours.</p>\n  <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">\n  <p style="color: #999; font-size: 12px;">ContractNest - Contract Management Made Simple</p>\n</div>',
     '[{"name": "recipient_name", "type": "string", "required": false, "default": "there"}, {"name": "inviter_name", "type": "string", "required": true}, {"name": "tenant_name", "type": "string", "required": true}, {"name": "invite_link", "type": "string", "required": true}]'::jsonb,
     NULL, true),

    -- USER INVITE - SMS
    (NULL, 'user_invite_sms_v1', 'User Invitation SMS', 'Default SMS template for user invitations',
     'sms', 'user_invite',
     NULL,
     '{{inviter_name}} invited you to {{tenant_name}}. Join: {{invite_link}}',
     NULL,
     '[{"name": "inviter_name", "type": "string", "required": true}, {"name": "tenant_name", "type": "string", "required": true}, {"name": "invite_link", "type": "string", "required": true}]'::jsonb,
     NULL, true),

    -- USER INVITE - WHATSAPP
    (NULL, 'user_invite_whatsapp_v1', 'User Invitation WhatsApp', 'Default WhatsApp template for user invitations',
     'whatsapp', 'user_invite',
     NULL,
     E'Hi {{recipient_name}}! 👋\n\n*{{inviter_name}}* has invited you to join *{{tenant_name}}* on ContractNest.\n\nAccept your invitation:\n{{invite_link}}\n\n_This invitation expires in 48 hours._',
     NULL,
     '[{"name": "recipient_name", "type": "string", "required": false, "default": "there"}, {"name": "inviter_name", "type": "string", "required": true}, {"name": "tenant_name", "type": "string", "required": true}, {"name": "invite_link", "type": "string", "required": true}]'::jsonb,
     NULL, true),

    -- SERVICE REMINDER - EMAIL
    (NULL, 'service_reminder_email_v1', 'Service Reminder Email', 'Reminder for upcoming service visit',
     'email', 'service_reminder',
     'Reminder: Service visit scheduled for {{service_date}}',
     E'Hi {{customer_name}},\n\nThis is a reminder that your {{service_type}} service is scheduled for {{service_date}}.\n\nOur technician will arrive at the scheduled time. Please ensure someone is available to provide access.\n\nIf you need to reschedule, please contact us as soon as possible.\n\nThank you,\n{{tenant_name}}',
     NULL,
     '[{"name": "customer_name", "type": "string", "required": true}, {"name": "service_type", "type": "string", "required": true}, {"name": "service_date", "type": "string", "required": true}, {"name": "tenant_name", "type": "string", "required": true}]'::jsonb,
     NULL, true),

    -- SERVICE REMINDER - SMS
    (NULL, 'service_reminder_sms_v1', 'Service Reminder SMS', 'SMS reminder for upcoming service',
     'sms', 'service_reminder',
     NULL,
     'Reminder: {{service_type}} service on {{service_date}}. Contact us to reschedule. -{{tenant_name}}',
     NULL,
     '[{"name": "service_type", "type": "string", "required": true}, {"name": "service_date", "type": "string", "required": true}, {"name": "tenant_name", "type": "string", "required": true}]'::jsonb,
     NULL, true),

    -- PAYMENT DUE - EMAIL
    (NULL, 'payment_due_email_v1', 'Payment Due Email', 'Payment due reminder email',
     'email', 'payment_due',
     'Payment Reminder: Invoice {{invoice_number}} due {{due_date}}',
     E'Hi {{customer_name}},\n\nThis is a reminder that invoice {{invoice_number}} for {{amount}} is due on {{due_date}}.\n\nPlease make the payment at your earliest convenience to avoid any late fees.\n\nPay now: {{payment_link}}\n\nThank you,\n{{tenant_name}}',
     NULL,
     '[{"name": "customer_name", "type": "string", "required": true}, {"name": "invoice_number", "type": "string", "required": true}, {"name": "amount", "type": "string", "required": true}, {"name": "due_date", "type": "string", "required": true}, {"name": "payment_link", "type": "string", "required": false}, {"name": "tenant_name", "type": "string", "required": true}]'::jsonb,
     NULL, true),

    -- APPOINTMENT REMINDER - SMS
    (NULL, 'appointment_reminder_sms_v1', 'Appointment Reminder SMS', 'SMS reminder for upcoming appointment',
     'sms', 'appointment_reminder',
     NULL,
     'Reminder: Your appointment is on {{appointment_date}}. Reply YES to confirm or call to reschedule.',
     NULL,
     '[{"name": "appointment_date", "type": "string", "required": true}]'::jsonb,
     NULL, true)

ON CONFLICT (tenant_id, template_key, channel_code, is_live) DO UPDATE SET
    name = EXCLUDED.name,
    content = EXCLUDED.content,
    content_html = EXCLUDED.content_html,
    variables = EXCLUDED.variables;

-- ============================================================
-- END OF SEED DATA
-- ============================================================
