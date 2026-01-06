// supabase/functions/jtd-worker/index.ts
// JTD Worker - Polls PGMQ and processes jobs
// Invoked via cron job or HTTP trigger

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Handler imports
import { handleEmail } from './handlers/email.ts';
import { handleSMS } from './handlers/sms.ts';
import { handleWhatsApp } from './handlers/whatsapp.ts';
import { handleInApp } from './handlers/inapp.ts';

// Types
interface JTDQueueMessage {
  msg_id: number;
  read_ct: number;
  enqueued_at: string;
  vt: string;
  message: {
    jtd_id: string;
    tenant_id: string;
    event_type_code: string;
    channel_code: string;
    source_type_code: string;
    priority: number;
    scheduled_at: string | null;
    recipient_contact: string;
    is_live: boolean;
    created_at: string;
  };
}

interface JTDRecord {
  id: string;
  tenant_id: string;
  event_type_code: string;
  channel_code: string;
  source_type_code: string;
  recipient_name: string;
  recipient_contact: string;
  payload: {
    recipient_data?: Record<string, any>;
    template_data?: Record<string, any>;
  };
  template_key: string;
  template_variables: Record<string, any>;
  metadata: Record<string, any>;
  is_live: boolean;
  retry_count: number;
  max_retries: number;
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// Constants
const BATCH_SIZE = 10;
const VISIBILITY_TIMEOUT = 60; // seconds
const DEFAULT_MAX_RETRIES = 3;
const VANI_UUID = '00000000-0000-0000-0000-000000000001';

// Initialize Supabase client with service role
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

/**
 * Read batch of messages from JTD queue
 */
async function readQueue(batchSize: number = BATCH_SIZE): Promise<JTDQueueMessage[]> {
  const { data, error } = await supabase.rpc('jtd_read_queue', {
    p_batch_size: batchSize,
    p_visibility_timeout: VISIBILITY_TIMEOUT
  });

  if (error) {
    console.error('Error reading queue:', error);
    throw error;
  }

  return data || [];
}

/**
 * Fetch full JTD record from database including retry info
 */
async function fetchJTDRecord(jtdId: string): Promise<JTDRecord | null> {
  const { data, error } = await supabase
    .from('n_jtd')
    .select('id, tenant_id, event_type_code, channel_code, source_type_code, recipient_name, recipient_contact, payload, template_key, template_variables, metadata, is_live, retry_count, max_retries')
    .eq('id', jtdId)
    .single();

  if (error) {
    console.error('Error fetching JTD record:', error);
    return null;
  }

  return data;
}

/**
 * Delete message from queue (ALWAYS call this after processing)
 */
async function deleteMessage(msgId: number): Promise<void> {
  const { error } = await supabase.rpc('jtd_delete_message', {
    p_msg_id: msgId
  });

  if (error) {
    console.error('Error deleting message:', error);
    // Don't throw - we want to continue even if delete fails
  }
}

/**
 * Move message to DLQ after max retries
 */
async function archiveToDLQ(msgId: number, errorMessage: string): Promise<void> {
  const { error } = await supabase.rpc('jtd_archive_to_dlq', {
    p_msg_id: msgId,
    p_error_message: errorMessage
  });

  if (error) {
    console.error('Error archiving to DLQ:', error);
  }
}

/**
 * Update JTD status in database
 * Column names: status_code, executed_at, completed_at, error_message, retry_count
 */
async function updateJTDStatus(
  jtdId: string,
  status: string,
  providerMessageId?: string,
  errorMessage?: string,
  incrementRetry: boolean = false
): Promise<void> {
  const updateData: Record<string, any> = {
    status_code: status,
    updated_by: VANI_UUID,
    updated_at: new Date().toISOString()
  };

  if (providerMessageId) {
    updateData.provider_message_id = providerMessageId;
  }

  if (status === 'sent' || status === 'processing') {
    updateData.executed_at = new Date().toISOString();
  } else if (status === 'delivered' || status === 'completed') {
    updateData.completed_at = new Date().toISOString();
  } else if (status === 'failed') {
    updateData.error_message = errorMessage;
    updateData.last_retry_at = new Date().toISOString();
  }

  // Build query
  let query = supabase.from('n_jtd').update(updateData).eq('id', jtdId);

  const { error } = await query;

  if (error) {
    console.error('Error updating JTD status:', error);
    throw error;
  }

  // Increment retry_count separately if needed
  if (incrementRetry) {
    // Fetch current retry_count and increment
    const { data: currentRecord } = await supabase
      .from('n_jtd')
      .select('retry_count')
      .eq('id', jtdId)
      .single();

    const newRetryCount = (currentRecord?.retry_count || 0) + 1;

    await supabase
      .from('n_jtd')
      .update({ retry_count: newRetryCount })
      .eq('id', jtdId);
  }
}

/**
 * Get template for JTD
 */
async function getTemplate(
  sourceType: string,
  channel: string,
  tenantId: string
): Promise<{ subject?: string; body: string; bodyHtml?: string; providerTemplateId?: string } | null> {
  // First try tenant-specific template
  let { data, error } = await supabase
    .from('n_jtd_templates')
    .select('subject, content, content_html, provider_template_id')
    .eq('source_type_code', sourceType)
    .eq('channel_code', channel)
    .eq('tenant_id', tenantId)
    .eq('is_active', true)
    .single();

  if (!data) {
    // Fall back to system template (tenant_id is null)
    const result = await supabase
      .from('n_jtd_templates')
      .select('subject, content, content_html, provider_template_id')
      .eq('source_type_code', sourceType)
      .eq('channel_code', channel)
      .is('tenant_id', null)
      .eq('is_active', true)
      .single();

    data = result.data;
    error = result.error;
  }

  if (error && error.code !== 'PGRST116') {
    console.error('Error fetching template:', error);
    return null;
  }

  if (!data) return null;

  return {
    subject: data.subject,
    body: data.content,
    bodyHtml: data.content_html,
    providerTemplateId: data.provider_template_id
  };
}

/**
 * Replace template variables with actual values
 * Variables format: {{variable_name}}
 */
function renderTemplate(template: string, data: Record<string, any>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (match, key) => {
    return data[key] !== undefined ? String(data[key]) : match;
  });
}

/**
 * Process a single JTD message
 */
async function processMessage(msg: JTDQueueMessage): Promise<void> {
  const { message } = msg;
  const { jtd_id } = message;

  console.log(`Processing JTD ${jtd_id}`);

  try {
    // Fetch full JTD record from database (queue message only has basic info)
    const jtdRecord = await fetchJTDRecord(jtd_id);
    if (!jtdRecord) {
      console.error(`JTD record not found: ${jtd_id}, deleting from queue`);
      await deleteMessage(msg.msg_id);
      return;
    }

    // Check retry limit BEFORE processing
    const maxRetries = jtdRecord.max_retries || DEFAULT_MAX_RETRIES;
    if (jtdRecord.retry_count >= maxRetries) {
      console.log(`JTD ${jtd_id} exceeded max retries (${jtdRecord.retry_count}/${maxRetries}), marking as failed`);
      await updateJTDStatus(jtd_id, 'failed', undefined, `Max retries (${maxRetries}) exceeded`);
      await archiveToDLQ(msg.msg_id, `Max retries exceeded`);
      await deleteMessage(msg.msg_id);
      return;
    }

    const {
      tenant_id,
      channel_code,
      source_type_code,
      recipient_contact,
      recipient_name,
      payload,
      template_variables,
      metadata
    } = jtdRecord;

    // Build recipient_data from payload or construct from record
    const recipient_data = payload?.recipient_data || {
      email: channel_code === 'email' ? recipient_contact : undefined,
      mobile: channel_code !== 'email' ? recipient_contact : undefined,
      name: recipient_name
    };

    // Use template_variables from record
    const template_data = template_variables || payload?.template_data || {};

    console.log(`Processing JTD ${jtd_id} - ${source_type_code} via ${channel_code} (retry ${jtdRecord.retry_count}/${maxRetries})`);

    // Update status to 'processing'
    await updateJTDStatus(jtd_id, 'processing');

    // Get template using source_type_code (e.g., 'user_invite')
    const template = await getTemplate(source_type_code, channel_code, tenant_id);
    if (!template) {
      throw new Error(`No template found for ${source_type_code}/${channel_code}`);
    }

    // Render template with data
    const renderedBody = renderTemplate(template.body, template_data);
    const renderedBodyHtml = template.bodyHtml
      ? renderTemplate(template.bodyHtml, template_data)
      : undefined;
    const renderedSubject = template.subject
      ? renderTemplate(template.subject, template_data)
      : undefined;

    // Route to appropriate handler
    let result: ProcessResult;

    switch (channel_code) {
      case 'email':
        result = await handleEmail({
          to: recipient_data.email || recipient_contact,
          toName: recipient_name,
          subject: renderedSubject || `Notification: ${source_type_code}`,
          body: renderedBodyHtml || renderedBody,
          templateId: template.providerTemplateId,
          templateVariables: template_data,
          metadata
        });
        break;

      case 'sms':
        result = await handleSMS({
          to: recipient_data.mobile || recipient_contact,
          body: renderedBody, // Plain text for SMS
          metadata
        });
        break;

      case 'whatsapp':
        result = await handleWhatsApp({
          to: recipient_data.mobile || recipient_contact,
          templateName: template.providerTemplateId || metadata?.whatsapp_template || source_type_code,
          templateData: template_data,
          metadata
        });
        break;

      case 'inapp':
        result = await handleInApp({
          userId: recipient_data.user_id,
          tenantId: tenant_id,
          title: renderedSubject || source_type_code,
          body: renderedBody,
          metadata
        });
        break;

      default:
        throw new Error(`Unknown channel: ${channel_code}`);
    }

    // ALWAYS delete from queue after processing (success or failure)
    await deleteMessage(msg.msg_id);

    if (result.success) {
      // Success - update status
      await updateJTDStatus(jtd_id, 'sent', result.provider_message_id);
      console.log(`JTD ${jtd_id} sent successfully`);
    } else {
      // Failure - increment retry count and update status
      const newRetryCount = jtdRecord.retry_count + 1;

      if (newRetryCount >= maxRetries) {
        // Max retries reached
        await updateJTDStatus(jtd_id, 'failed', undefined, result.error, true);
        await archiveToDLQ(msg.msg_id, result.error || 'Unknown error');
        console.log(`JTD ${jtd_id} FAILED permanently after ${newRetryCount} retries: ${result.error}`);
      } else {
        // More retries available - update status but DON'T re-queue
        // The scheduled job will pick it up based on status/retry_count
        await updateJTDStatus(jtd_id, 'failed', undefined, result.error, true);
        console.log(`JTD ${jtd_id} failed (retry ${newRetryCount}/${maxRetries}): ${result.error}`);
      }
    }

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    console.error(`Error processing JTD ${jtd_id}:`, errorMessage);

    // ALWAYS delete from queue to prevent infinite retry loop
    await deleteMessage(msg.msg_id);

    // Update status with error
    try {
      const jtdRecord = await fetchJTDRecord(jtd_id);
      const maxRetries = jtdRecord?.max_retries || DEFAULT_MAX_RETRIES;
      const currentRetry = jtdRecord?.retry_count || 0;

      if (currentRetry + 1 >= maxRetries) {
        await updateJTDStatus(jtd_id, 'failed', undefined, errorMessage, true);
        await archiveToDLQ(msg.msg_id, errorMessage);
        console.log(`JTD ${jtd_id} FAILED permanently: ${errorMessage}`);
      } else {
        await updateJTDStatus(jtd_id, 'failed', undefined, errorMessage, true);
        console.log(`JTD ${jtd_id} failed, retry ${currentRetry + 1}/${maxRetries}`);
      }
    } catch (updateError) {
      console.error(`Failed to update JTD ${jtd_id} status:`, updateError);
    }
  }
}

/**
 * Main worker function - processes batch of messages
 */
async function processQueue(): Promise<{ processed: number; errors: number }> {
  let processed = 0;
  let errors = 0;

  try {
    const messages = await readQueue();
    console.log(`Found ${messages.length} messages in queue`);

    for (const msg of messages) {
      try {
        await processMessage(msg);
        processed++;
      } catch (error) {
        errors++;
        console.error('Message processing failed:', error);
      }
    }
  } catch (error) {
    console.error('Queue processing failed:', error);
    throw error;
  }

  return { processed, errors };
}

/**
 * Process scheduled JTDs that are due
 */
async function processScheduled(): Promise<number> {
  const { data, error } = await supabase.rpc('jtd_enqueue_scheduled');

  if (error) {
    console.error('Error processing scheduled JTDs:', error);
    throw error;
  }

  const count = data || 0;
  if (count > 0) {
    console.log(`Enqueued ${count} scheduled JTDs`);
  }

  return count;
}

// HTTP Server
serve(async (req) => {
  // CORS headers
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Verify authorization (service role or cron secret)
    const authHeader = req.headers.get('Authorization');
    const cronSecret = req.headers.get('X-Cron-Secret');
    const expectedCronSecret = Deno.env.get('CRON_SECRET');

    if (!authHeader && cronSecret !== expectedCronSecret) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Process scheduled JTDs first
    const scheduledCount = await processScheduled();

    // Process queue
    const { processed, errors } = await processQueue();

    return new Response(
      JSON.stringify({
        success: true,
        scheduled_enqueued: scheduledCount,
        processed,
        errors,
        timestamp: new Date().toISOString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Worker error:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
