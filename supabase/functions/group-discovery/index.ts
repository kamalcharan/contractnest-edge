// supabase/functions/group-discovery/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import type { 
  GroupDiscoveryRequest, 
  GroupDiscoveryResponse, 
  Intent, 
  Channel,
  Session
} from "./types.ts";

// Import handlers
import { handleListSegments } from "./handlers/segments.ts";
import { handleListMembers } from "./handlers/members.ts";
import { handleSearch } from "./handlers/search.ts";
import { handleGetContact } from "./handlers/contact.ts";

// ============================================================================
// CORS HEADERS
// ============================================================================
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

// ============================================================================
// CONSTANTS
// ============================================================================
const BASE_URL = 'https://n8n.srv1096269.hstgr.cloud/webhook';

// ============================================================================
// MAIN HANDLER
// ============================================================================
serve(async (req) => {
  const startTime = Date.now();

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Only accept POST
  if (req.method !== 'POST') {
    return jsonResponse({
      success: false,
      intent: 'unknown',
      response_type: 'error',
      detail_level: 'none',
      message: 'Method not allowed. Use POST.',
      results: [],
      results_count: 0,
      session_id: null,
      is_new_session: false,
      group_id: '',
      group_name: '',
      channel: 'chat',
      from_cache: false,
      duration_ms: Date.now() - startTime,
      error: 'METHOD_NOT_ALLOWED'
    }, 405);
  }

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Parse request body
    const body: GroupDiscoveryRequest = await req.json();

    // Validate required fields
    const validation = validateRequest(body);
    if (!validation.valid) {
      return jsonResponse({
        success: false,
        intent: 'unknown',
        response_type: 'error',
        detail_level: 'none',
        message: validation.error!,
        results: [],
        results_count: 0,
        session_id: null,
        is_new_session: false,
        group_id: body.group_id || '',
        group_name: '',
        channel: body.channel || 'chat',
        from_cache: false,
        duration_ms: Date.now() - startTime,
        error: 'VALIDATION_ERROR'
      }, 400);
    }

    // Detect intent if not provided
    const intent: Intent = body.intent || detectIntent(body.message || '');

    // Get or create session (skip for get_contact from vcard/card - phone='system')
    let session: Session | null = null;
    let isNew = false;
    
    if (body.phone !== 'system') {
      const sessionResult = await getOrCreateSession(supabase, body);
      session = sessionResult.session;
      isNew = sessionResult.isNew;
    }

    // Get group name (handles null group_id)
    const groupName = await getGroupName(supabase, body.group_id || null);

    // Normalize channel
    const channel: Channel = body.channel || 'chat';

    // Route to handler based on intent
    const result = await routeIntent(supabase, {
      intent,
      body,
      session,
      groupName,
      startTime
    });

    // Update session with this interaction (skip for system calls)
    if (session?.session_id && body.phone !== 'system') {
      await updateSession(supabase, session.session_id, intent, body.message);
    }

    // Build final response
    const response: GroupDiscoveryResponse = {
      ...result,
      session_id: session?.session_id || null,
      is_new_session: isNew,
      group_id: body.group_id || '',
      group_name: groupName,
      channel,
      duration_ms: Date.now() - startTime
    };

    return jsonResponse(response, 200);

  } catch (error) {
    console.error('Error processing request:', error);
    return jsonResponse({
      success: false,
      intent: 'unknown',
      response_type: 'error',
      detail_level: 'none',
      message: 'An error occurred processing your request.',
      results: [],
      results_count: 0,
      session_id: null,
      is_new_session: false,
      group_id: '',
      group_name: '',
      channel: 'chat',
      from_cache: false,
      duration_ms: Date.now() - startTime,
      error: error.message
    }, 500);
  }
});

// ============================================================================
// VALIDATION
// ============================================================================
function validateRequest(body: GroupDiscoveryRequest): { valid: boolean; error?: string } {
  // group_id required for all intents except get_contact (vcard/card lookup)
  if (!body.group_id && body.intent !== 'get_contact') {
    return { valid: false, error: 'group_id is required' };
  }

  // UUID format check - only if group_id provided
  if (body.group_id) {
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(body.group_id)) {
      return { valid: false, error: 'Invalid group_id format' };
    }
  }

  // Must have either message or intent
  if (!body.message && !body.intent) {
    return { valid: false, error: 'Either message or intent is required' };
  }

  // Must have phone or user_id (phone='system' allowed for vcard/card)
  if (!body.phone && !body.user_id) {
    return { valid: false, error: 'Either phone or user_id is required' };
  }

  return { valid: true };
}

// ============================================================================
// INTENT DETECTION
// ============================================================================
function detectIntent(message: string): Intent {
  const msg = message.toLowerCase().trim();

  // Exit patterns
  if (['bye', 'exit', 'quit', 'goodbye', 'end', 'stop'].includes(msg)) {
    return 'goodbye';
  }

  // Greeting patterns
  if (['hi', 'hello', 'hey', 'start'].some(w => msg === w || msg.startsWith(w + ' '))) {
    return 'welcome';
  }

  // Segments patterns
  if (msg.includes('segment') || msg.includes('industr') || msg.includes('categor') ||
      /show.*(all|every)/.test(msg) || /list.*(all|every)/.test(msg)) {
    return 'list_segments';
  }

  // Members patterns
  if (/who.*(is|are).*(into|in)/i.test(msg) ||
      /(show|list|get|find)\s+(.+?)\s*(companies|businesses|members)/i.test(msg)) {
    return 'list_members';
  }

  // Contact patterns
  if (/(detail|contact|info|about|tell me about|more about)/i.test(msg)) {
    return 'get_contact';
  }

  // Default to search
  return 'search';
}

// ============================================================================
// SESSION MANAGEMENT
// ============================================================================
async function getOrCreateSession(
  supabase: SupabaseClient, 
  body: GroupDiscoveryRequest
): Promise<{ session: Session | null; isNew: boolean }> {
  
  const phone = body.phone ? body.phone.replace(/[^0-9]/g, '') : null;

  // Try to get existing session
  const { data: existing, error: getError } = await supabase.rpc('get_ai_session', {
    p_phone: phone
  });

  if (!getError && existing && existing.length > 0) {
    return { session: existing[0], isNew: false };
  }

  // Create new session
  const { data: newSessionId, error: createError } = await supabase.rpc('create_ai_session', {
    p_user_id: body.user_id || null,
    p_group_id: body.group_id,
    p_phone: body.phone || null,
    p_channel: body.channel || 'chat',
    p_language: 'en'
  });

  if (createError) {
    console.error('Error creating session:', createError);
    return { session: null, isNew: false };
  }

  return { 
    session: { session_id: newSessionId, group_id: body.group_id } as Session, 
    isNew: true 
  };
}

async function updateSession(
  supabase: SupabaseClient,
  sessionId: string,
  intent: Intent,
  message?: string
): Promise<void> {
  try {
    await supabase.rpc('update_ai_session', {
      p_session_id: sessionId,
      p_context: { last_intent: intent },
      p_language: null,
      p_add_message: message ? { role: 'user', content: message } : null
    });
  } catch (error) {
    console.error('Error updating session:', error);
  }
}

async function endSession(supabase: SupabaseClient, phone: string): Promise<void> {
  try {
    await supabase.rpc('end_ai_session', { p_phone: phone });
  } catch (error) {
    console.error('Error ending session:', error);
  }
}

// ============================================================================
// GROUP NAME LOOKUP
// ============================================================================
async function getGroupName(supabase: SupabaseClient, groupId: string | null): Promise<string> {
  if (!groupId) return 'Business Directory';
  
  try {
    const { data, error } = await supabase
      .from('t_business_groups')
      .select('group_name')
      .eq('id', groupId)
      .single();

    if (error || !data) return 'Business Directory';
    return data.group_name || 'Business Directory';
  } catch {
    return 'Business Directory';
  }
}

// ============================================================================
// INTENT ROUTER
// ============================================================================
async function routeIntent(
  supabase: SupabaseClient,
  ctx: {
    intent: Intent;
    body: GroupDiscoveryRequest;
    session: Session | null;
    groupName: string;
    startTime: number;
  }
): Promise<Partial<GroupDiscoveryResponse>> {
  const { intent, body, session, groupName, startTime } = ctx;

  switch (intent) {
    case 'welcome':
      return handleWelcome(groupName);

    case 'goodbye':
      if (body.phone && body.phone !== 'system') {
        await endSession(supabase, body.phone);
      }
      return handleGoodbye(groupName);

    case 'list_segments':
      return await handleListSegments(supabase, body.group_id);

    case 'list_members':
      return await handleListMembers(supabase, body);

    case 'search':
      return await handleSearch(supabase, body);

    case 'get_contact':
      return await handleGetContact(supabase, body);

    default:
      return handleUnknown();
  }
}

// ============================================================================
// SIMPLE INTENT HANDLERS (inline - no RPC calls)
// ============================================================================
function handleWelcome(groupName: string): Partial<GroupDiscoveryResponse> {
  return {
    success: true,
    intent: 'welcome',
    response_type: 'welcome',
    detail_level: 'none',
    message: `👋 Welcome to **${groupName}** Business Directory!\n\nI can help you:\n• 🔍 Search for businesses\n• 📋 Browse by industry\n• 📞 Get contact details\n\nWhat would you like to find?`,
    results: [],
    results_count: 0,
    from_cache: false
  };
}

function handleGoodbye(groupName: string): Partial<GroupDiscoveryResponse> {
  return {
    success: true,
    intent: 'goodbye',
    response_type: 'goodbye',
    detail_level: 'none',
    message: `👋 Thank you for using **${groupName}** Directory. Goodbye!`,
    results: [],
    results_count: 0,
    from_cache: false
  };
}

function handleUnknown(): Partial<GroupDiscoveryResponse> {
  return {
    success: true,
    intent: 'unknown',
    response_type: 'conversation',
    detail_level: 'none',
    message: "I'm not sure what you're looking for. Try:\n• 'Show segments' - See industries\n• 'Who is into Technology' - Browse by industry\n• 'Search AI companies' - Find businesses\n• 'Details for [business]' - Get contact info",
    results: [],
    results_count: 0,
    from_cache: false
  };
}

// ============================================================================
// RESPONSE HELPER
// ============================================================================
function jsonResponse(data: GroupDiscoveryResponse, status: number = 200): Response {
  return new Response(
    JSON.stringify(data),
    { 
      status, 
      headers: { 
        ...corsHeaders, 
        'Content-Type': 'application/json' 
      } 
    }
  );
}