// supabase/functions/jtd-worker/handlers/inapp.ts
// In-App notification handler - stores in database for UI to display

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

interface InAppRequest {
  userId: string;
  tenantId: string;
  title: string;
  body: string;
  metadata?: Record<string, any>;
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// Initialize Supabase client
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

/**
 * Store in-app notification in database
 * UI will fetch these via Supabase Realtime or polling
 */
export async function handleInApp(request: InAppRequest): Promise<ProcessResult> {
  const { userId, tenantId, title, body, metadata } = request;

  if (!userId) {
    return {
      success: false,
      error: 'User ID is required for in-app notifications'
    };
  }

  try {
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Insert into n_inapp_notifications table
    // This table should be created in migrations (TODO: add to schema)
    const { data, error } = await supabase
      .from('n_inapp_notifications')
      .insert({
        user_id: userId,
        tenant_id: tenantId,
        title: title,
        body: body,
        metadata: metadata || {},
        is_read: false,
        created_at: new Date().toISOString()
      })
      .select('id')
      .single();

    if (error) {
      console.error('In-app notification insert error:', error);
      return {
        success: false,
        error: error.message
      };
    }

    console.log(`In-app notification created for user ${userId}, id: ${data.id}`);

    return {
      success: true,
      provider_message_id: data.id
    };

  } catch (error) {
    console.error('In-app notification error:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error creating in-app notification'
    };
  }
}

/**
 * Mark in-app notification as read (called from API)
 */
export async function markAsRead(notificationId: string): Promise<boolean> {
  try {
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { error } = await supabase
      .from('n_inapp_notifications')
      .update({
        is_read: true,
        read_at: new Date().toISOString()
      })
      .eq('id', notificationId);

    if (error) {
      console.error('Mark as read error:', error);
      return false;
    }

    return true;
  } catch (error) {
    console.error('Mark as read error:', error);
    return false;
  }
}

/**
 * Get unread count for user (called from API)
 */
export async function getUnreadCount(userId: string, tenantId: string): Promise<number> {
  try {
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { count, error } = await supabase
      .from('n_inapp_notifications')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .eq('is_read', false);

    if (error) {
      console.error('Get unread count error:', error);
      return 0;
    }

    return count || 0;
  } catch (error) {
    console.error('Get unread count error:', error);
    return 0;
  }
}
