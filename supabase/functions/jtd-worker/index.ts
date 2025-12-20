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
interface JTDMessage {
  msg_id: number;
  read_ct: number;
  enqueued_at: string;
  vt: string;
  message: {
    jtd_id: string;
    event_type: string;
    channel: string;
    tenant_id: string;
    source_type: string;
    priority: number;
    recipient_data: Record<string, any>;
    template_data: Record<string, any>;
    metadata: Record<string, any>;
  };
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// Constants
const BATCH_SIZE = 10;
const VISIBILITY_TIMEOUT = 60; // seconds
const MAX_RETRIES = 3;
const VANI_UUID = '00000000-0000-0000-0000-000000000001';

// Initialize Supabase client with service role
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

/**
 * Read batch of messages from JTD queue
 */
async function readQueue(batchSize: number = BATCH_SIZE): Promise<JTDMessage[]> {
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
 * Delete message from queue after successful processing
 */
async function deleteMessage(msgId: number): Promise<void> {
  const { error } = await supabase.rpc('jtd_delete_message', {
    p_msg_id: msgId
  });

  if (error) {
    console.error('Error deleting message:', error);
    throw error;
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
    throw error;
  }
}

/**
 * Update JTD status in database
 */
async function updateJTDStatus(
  jtdId: string,
  status: string,
  providerMessageId?: string,
  errorMessage?: string
): Promise<void> {
  const updateData: Record<string, any> = {
    current_status: status,
    updated_by: VANI_UUID,
    updated_at: new Date().toISOString()
  };

  if (providerMessageId) {
    updateData.provider_message_id = providerMessageId;
  }

  if (status === 'sent') {
    updateData.sent_at = new Date().toISOString();
  } else if (status === 'delivered') {
    updateData.delivered_at = new Date().toISOString();
  } else if (status === 'failed') {
    updateData.failed_at = new Date().toISOString();
    updateData.error_message = errorMessage;
  }

  const { error } = await supabase
    .from('n_jtd')
    .update(updateData)
    .eq('id', jtdId);

  if (error) {
    console.error('Error updating JTD status:', error);
    throw error;
  }

  // Status history is handled by database trigger
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
async function processMessage(msg: JTDMessage): Promise<void> {
  const { message } = msg;
  const { jtd_id, event_type, channel, tenant_id, source_type, recipient_data, template_data, metadata } = message;

  console.log(`Processing JTD ${jtd_id} - ${source_type}/${event_type} via ${channel}`);

  try {
    // Update status to 'processing'
    await updateJTDStatus(jtd_id, 'processing');

    // Get template using source_type (e.g., 'user_invite')
    const template = await getTemplate(source_type, channel, tenant_id);
    if (!template) {
      throw new Error(`No template found for ${source_type}/${channel}`);
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

    switch (channel) {
      case 'email':
        result = await handleEmail({
          to: recipient_data.email,
          subject: renderedSubject || `Notification: ${source_type}`,
          body: renderedBodyHtml || renderedBody, // Prefer HTML for email
          metadata
        });
        break;

      case 'sms':
        result = await handleSMS({
          to: recipient_data.mobile,
          body: renderedBody, // Plain text for SMS
          metadata
        });
        break;

      case 'whatsapp':
        result = await handleWhatsApp({
          to: recipient_data.mobile,
          templateName: template.providerTemplateId || metadata.whatsapp_template || source_type,
          templateData: template_data,
          metadata
        });
        break;

      case 'inapp':
        result = await handleInApp({
          userId: recipient_data.user_id,
          tenantId: tenant_id,
          title: renderedSubject || source_type,
          body: renderedBody,
          metadata
        });
        break;

      default:
        throw new Error(`Unknown channel: ${channel}`);
    }

    if (result.success) {
      // Success - update status and delete from queue
      await updateJTDStatus(jtd_id, 'sent', result.provider_message_id);
      await deleteMessage(msg.msg_id);
      console.log(`JTD ${jtd_id} sent successfully`);
    } else {
      throw new Error(result.error || 'Unknown error');
    }

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    console.error(`Error processing JTD ${jtd_id}:`, errorMessage);

    // Check retry count
    if (msg.read_ct >= MAX_RETRIES) {
      // Max retries exceeded - move to DLQ
      await updateJTDStatus(jtd_id, 'failed', undefined, errorMessage);
      await archiveToDLQ(msg.msg_id, errorMessage);
      console.log(`JTD ${jtd_id} moved to DLQ after ${msg.read_ct} retries`);
    } else {
      // Will be retried after visibility timeout expires
      console.log(`JTD ${jtd_id} will be retried (attempt ${msg.read_ct} of ${MAX_RETRIES})`);
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
