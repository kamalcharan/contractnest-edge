// supabase/functions/group-discovery/index.ts
// CLEAN VERSION - Group Agnostic Framework (FIXED)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

// Import handlers
import { handleListSegments } from "./handlers/segments.ts";
import { handleListMembers } from "./handlers/members.ts";
import { handleSearch } from "./handlers/search.ts";
import { handleGetContact } from "./handlers/contact.ts";

// ============================================================================
// TYPES
// ============================================================================
type Intent = 
  | 'welcome' | 'goodbye' | 'about_owner' | 'book_appointment' | 'call_owner'
  | 'explore_bbb' | 'list_segments' | 'list_members' | 'search' | 'get_contact'
  | 'unknown';

type Channel = 'whatsapp' | 'chat' | 'api';

type SessionAction = 'start' | 'end' | 'continue';

interface Session {
  session_id: string;
  group_id: string;
  context?: Record<string, any>;
}

interface SessionConfig {
  welcome_message?: string;
  goodbye_message?: string;
  session_timeout_minutes?: number;
}

interface GroupDiscoveryRequest {
  intent?: Intent;
  message?: string;
  phone?: string;
  user_id?: string;
  group_id?: string;
  channel?: Channel;
  params?: Record<string, any>;
  session_action?: SessionAction;
  session_config?: SessionConfig;
}

interface GroupDiscoveryResponse {
  success: boolean;
  intent: Intent | string;
  response_type: string;
  detail_level: string;
  message: string;
  results: any[];
  results_count: number;
  session_id: string | null;
  is_new_session: boolean;
  is_member: boolean;
  group_id: string;
  group_name: string;
  channel: Channel | string;
  from_cache: boolean;
  duration_ms: number;
  error?: string;
  template_name?: string;
  template_params?: string[];
}

// ============================================================================
// CORS HEADERS
// ============================================================================
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

// ============================================================================
// TEMPLATE NAMES (Generic)
// ============================================================================
const TEMPLATES = {
  WELCOME: 'vani_welcome',
  CONTACT: 'vani_contact',
  BOOKING: 'vani_booking',
  ABOUT: 'vani_about',
  GOODBYE: 'vani_goodbye',
  INDUSTRIES: 'bbb_industries',
  RESULTS: 'bbb_results',
  MEMBER_CONTACT: 'bbb_contact',
  REPLY: 'vani_reply'
};

// ============================================================================
// DEFAULT MESSAGES (Used if not provided by N8N)
// ============================================================================
const DEFAULT_MESSAGES = {
  welcome: '👋 Welcome! How can I help you today?',
  goodbye: '👋 Thank you! Have a great day! Type "Hi" anytime to start again.',
  error: 'Sorry, something went wrong. Please try again.',
  unknown: "I'm not sure what you're looking for. Let me help you with some options."
};

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
      is_member: false,
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
        is_member: false,
        group_id: body.group_id || '',
        group_name: '',
        channel: body.channel || 'chat',
        from_cache: false,
        duration_ms: Date.now() - startTime,
        error: 'VALIDATION_ERROR',
        template_name: TEMPLATES.REPLY,
        template_params: [validation.error!]
      }, 400);
    }

    // Extract session action and config from N8N (N8N handles keyword detection)
    const sessionAction: SessionAction = body.session_action || 'continue';
    const sessionConfig: SessionConfig = body.session_config || {};

    // Use intent from N8N (N8N does intent detection based on group config)
    const intent: Intent = body.intent || 'unknown';

    // Normalize channel
    const channel: Channel = body.channel || 'chat';

    // Handle session based on action from N8N
    let session: Session | null = null;
    let isNew = false;
    let isMember = false;
    
    if (body.phone !== 'system') {
      const sessionResult = await handleSession(supabase, body, sessionAction);
      session = sessionResult.session;
      isNew = sessionResult.isNew;
      isMember = sessionResult.isMember;
    }

    // Get group name
    const groupName = await getGroupName(supabase, body.group_id || null);

    // Route to handler based on intent
    const result = await routeIntent(supabase, {
      intent,
      body,
      session,
      groupName,
      channel,
      isNewSession: isNew,
      isMember,
      sessionConfig,
      startTime
    });

    // Update session with this interaction (skip for system calls and session end)
    if (session?.session_id && body.phone !== 'system' && sessionAction !== 'end') {
      await updateSession(supabase, session.session_id, intent, body.message);
    }

    // Build final response
    const response: GroupDiscoveryResponse = {
      ...result,
      session_id: session?.session_id || null,
      is_new_session: isNew,
      is_member: isMember,
      group_id: body.group_id || '',
      group_name: groupName,
      channel,
      duration_ms: Date.now() - startTime
    } as GroupDiscoveryResponse;

    return jsonResponse(response, 200);

  } catch (error) {
    console.error('Error processing request:', error);
    return jsonResponse({
      success: false,
      intent: 'unknown',
      response_type: 'error',
      detail_level: 'none',
      message: DEFAULT_MESSAGES.error,
      results: [],
      results_count: 0,
      session_id: null,
      is_new_session: false,
      is_member: false,
      group_id: '',
      group_name: '',
      channel: 'chat',
      from_cache: false,
      duration_ms: Date.now() - startTime,
      error: error.message,
      template_name: TEMPLATES.REPLY,
      template_params: [DEFAULT_MESSAGES.error]
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
// SESSION MANAGEMENT (Group Agnostic)
// ============================================================================
async function handleSession(
  supabase: SupabaseClient, 
  body: GroupDiscoveryRequest,
  sessionAction: SessionAction
): Promise<{ session: Session | null; isNew: boolean; isMember: boolean }> {
  
  const phone = body.phone ? body.phone.replace(/[^0-9]/g, '') : null;
  const phoneNormalized = phone && phone.length === 10 ? '91' + phone : phone;

  // SESSION END
  if (sessionAction === 'end') {
    await endSession(supabase, phone);
    return { session: null, isNew: false, isMember: false };
  }

  // SESSION START - Always create new
  if (sessionAction === 'start') {
    // End any existing session first
    await endSession(supabase, phone);
    
    // Check membership
    const membershipResult = await checkMembership(supabase, body.group_id, body.phone, phoneNormalized);
    
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
      return { session: null, isNew: false, isMember: false };
    }

    // Store membership info in session context
    if (newSessionId) {
      await supabase.rpc('update_ai_session', {
        p_session_id: newSessionId,
        p_context: { 
          is_member: membershipResult.isMember,
          membership_id: membershipResult.membershipId,
          membership_business_name: membershipResult.businessName,
          session_started_at: new Date().toISOString()
        },
        p_language: null,
        p_add_message: null
      });
    }

    return { 
      session: { 
        session_id: newSessionId, 
        group_id: body.group_id!,
        context: { is_member: membershipResult.isMember }
      }, 
      isNew: true,
      isMember: membershipResult.isMember
    };
  }

  // SESSION CONTINUE - Get existing or create new
  const { data: existing, error: getError } = await supabase.rpc('get_ai_session', {
    p_phone: phone
  });

  if (!getError && existing && existing.length > 0) {
    const session = existing[0];
    const isMember = session.context?.is_member === true;
    return { session, isNew: false, isMember };
  }

  // No existing session - create new one
  const membershipResult = await checkMembership(supabase, body.group_id, body.phone, phoneNormalized);

  const { data: newSessionId, error: createError } = await supabase.rpc('create_ai_session', {
    p_user_id: body.user_id || null,
    p_group_id: body.group_id,
    p_phone: body.phone || null,
    p_channel: body.channel || 'chat',
    p_language: 'en'
  });

  if (createError) {
    console.error('Error creating session:', createError);
    return { session: null, isNew: false, isMember: false };
  }

  // Store membership info in session context
  if (newSessionId) {
    await supabase.rpc('update_ai_session', {
      p_session_id: newSessionId,
      p_context: { 
        is_member: membershipResult.isMember,
        membership_id: membershipResult.membershipId,
        membership_business_name: membershipResult.businessName,
        session_started_at: new Date().toISOString()
      },
      p_language: null,
      p_add_message: null
    });
  }

  return { 
    session: { 
      session_id: newSessionId, 
      group_id: body.group_id!,
      context: { is_member: membershipResult.isMember }
    }, 
    isNew: true,
    isMember: membershipResult.isMember
  };
}

async function checkMembership(
  supabase: SupabaseClient,
  groupId: string | undefined,
  phone: string | undefined,
  phoneNormalized: string | null
): Promise<{ isMember: boolean; membershipId: string | null; businessName: string | null }> {
  if (!groupId || !phone) {
    return { isMember: false, membershipId: null, businessName: null };
  }

  try {
    const { data: membership, error } = await supabase
      .from('t_group_memberships')
      .select('id, business_name, owner_name')
      .eq('group_id', groupId)
      .eq('status', 'active')
      .or(`phone.eq.${phone},phone_normalized.eq.${phoneNormalized},phone.ilike.%${phone.slice(-10)}%`)
      .limit(1)
      .maybeSingle();

    if (!error && membership) {
      return { 
        isMember: true, 
        membershipId: membership.id, 
        businessName: membership.business_name 
      };
    }
  } catch (error) {
    console.error('Membership check error:', error);
  }

  return { isMember: false, membershipId: null, businessName: null };
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

async function endSession(supabase: SupabaseClient, phone: string | null): Promise<void> {
  if (!phone) return;
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
// OWNER LOOKUP
// ============================================================================
async function getOwnerDetails(supabase: SupabaseClient, groupId: string): Promise<any | null> {
  try {
    const { data: owner, error: ownerError } = await supabase
      .from('t_group_memberships')
      .select('*')
      .eq('group_id', groupId)
      .eq('is_owner', true)
      .single();

    if (ownerError || !owner) return null;

    const { data: profile } = await supabase
      .from('t_tenant_profiles')
      .select('*')
      .eq('tenant_id', owner.tenant_id)
      .single();

    return {
      ...owner,
      membership_id: owner.id,  // Ensure membership_id is available
      business_name: profile?.business_name || owner.profile_data?.business_name || 'Business',
      mobile_number: profile?.business_phone || owner.mobile_number,
      business_email: profile?.business_email || owner.business_email,
      business_phone_country_code: profile?.business_phone_country_code || owner.business_phone_country_code || '+91',
      business_whatsapp: profile?.business_whatsapp || owner.business_whatsapp,
      business_whatsapp_country_code: profile?.business_whatsapp_country_code || owner.business_whatsapp_country_code || '+91',
      website_url: profile?.website_url || owner.website_url,
      booking_url: profile?.booking_url || owner.booking_url,
      city: profile?.city || owner.city,
      state_code: profile?.state_code || owner.state_code,
      short_description: profile?.short_description || owner.profile_data?.short_description || '',
      industry: profile?.industry || owner.industry || ''
    };
  } catch (error) {
    console.error('Owner lookup error:', error);
    return null;
  }
}

// ============================================================================
// MENU HELPERS (Generic - Group name injected)
// ============================================================================
function getMainMenu(ownerName: string): string {
  return `\n\nReply with:\n1️⃣ About ${ownerName}\n2️⃣ Book Appointment\n3️⃣ Call Us\n4️⃣ Explore Directory\n0️⃣ Exit`;
}

function getDirectoryMenu(): string {
  return `\n\nReply with:\n🔍 Type a business name to search\n📋 Type "industries" to browse\n0️⃣ Back to Main Menu`;
}

// ============================================================================
// INTENT ROUTER (Group Agnostic)
// ============================================================================
async function routeIntent(
  supabase: SupabaseClient,
  ctx: {
    intent: Intent;
    body: GroupDiscoveryRequest;
    session: Session | null;
    groupName: string;
    channel: Channel;
    isNewSession: boolean;
    isMember: boolean;
    sessionConfig: SessionConfig;
    startTime: number;
  }
): Promise<Partial<GroupDiscoveryResponse>> {
  const { intent, body, session, groupName, channel, isNewSession, isMember, sessionConfig } = ctx;

  // Get owner details for menu customization and welcome
  const owner = body.group_id ? await getOwnerDetails(supabase, body.group_id) : null;
  const ownerName = owner?.business_name || groupName;

  switch (intent) {
    case 'welcome':
      return handleWelcome(ownerName, groupName, channel, isNewSession, sessionConfig.welcome_message, owner);

    case 'goodbye':
      return handleGoodbye(groupName, channel, sessionConfig.goodbye_message);

    case 'about_owner':
      return handleAboutOwner(owner, ownerName, channel);

    case 'book_appointment':
      return handleBookAppointment(owner, ownerName, channel);

    case 'call_owner':
      return handleCallOwner(owner, ownerName, channel);

    case 'explore_bbb':
      return handleExploreDirectory(groupName, channel);

    case 'list_segments':
      const segmentsResult = await handleListSegments(supabase, body.group_id!);
      return addTemplate(segmentsResult, channel, TEMPLATES.INDUSTRIES, 
        segmentsResult.results?.map((s: any) => `${s.segment_name} (${s.member_count})`).join(', ') || '');

    case 'list_members':
      const membersResult = await handleListMembers(supabase, body);
      return addTemplate(membersResult, channel, TEMPLATES.RESULTS,
        String(membersResult.results_count || 0),
        membersResult.results?.map((m: any) => m.business_name).join(', ') || '');

    case 'search':
      const searchResult = await handleSearch(supabase, body);
      return addTemplate(searchResult, channel, TEMPLATES.RESULTS,
        String(searchResult.results_count || 0),
        searchResult.results?.map((m: any) => m.business_name).join(', ') || '');

    case 'get_contact':
      const contactResult = await handleGetContact(supabase, body);
      if (contactResult.results && contactResult.results[0]) {
        const c = contactResult.results[0];
        const details = `${c.business_name} - ${(c.short_description || '').substring(0, 100)}`;
        return addTemplate(contactResult, channel, TEMPLATES.MEMBER_CONTACT, details);
      }
      return addTemplate(contactResult, channel, TEMPLATES.REPLY, contactResult.message || 'Contact not found.');

    default:
      return handleUnknown(ownerName, channel);
  }
}

// ============================================================================
// TEMPLATE HELPER
// ============================================================================
function addTemplate(
  result: Partial<GroupDiscoveryResponse>, 
  channel: Channel, 
  templateName: string, 
  ...params: string[]
): Partial<GroupDiscoveryResponse> {
  if (channel === 'whatsapp') {
    return {
      ...result,
      template_name: templateName,
      template_params: params.filter(p => p !== undefined && p !== null && p !== '')
    };
  }
  return result;
}

// ============================================================================
// RESPONSE HANDLERS (Group Agnostic)
// ============================================================================
function handleWelcome(
  ownerName: string,
  groupName: string,
  channel: Channel,
  isNewSession: boolean,
  customMessage?: string,
  owner?: any
): Partial<GroupDiscoveryResponse> {
  const message = customMessage 
    || `👋 Welcome! I'm your AI assistant from *${ownerName}*.\n\nHow can I help you today?${getMainMenu(ownerName)}`;

  return {
    success: true,
    intent: 'welcome',
    response_type: isNewSession ? 'session_start' : 'welcome',
    detail_level: 'none',
    message,
    results: owner ? [owner] : [],
    results_count: owner ? 1 : 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.WELCOME : undefined,
    template_params: []
  };
}

function handleGoodbye(
  groupName: string,
  channel: Channel,
  customMessage?: string
): Partial<GroupDiscoveryResponse> {
  const message = customMessage || DEFAULT_MESSAGES.goodbye;

  return {
    success: true,
    intent: 'goodbye',
    response_type: 'session_end',
    detail_level: 'none',
    message,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.GOODBYE : undefined,
    template_params: []
  };
}

function handleAboutOwner(
  owner: any | null,
  ownerName: string,
  channel: Channel
): Partial<GroupDiscoveryResponse> {
  if (!owner) {
    return {
      success: false,
      intent: 'about_owner',
      response_type: 'error',
      detail_level: 'none',
      message: `Sorry, couldn't fetch details.${getMainMenu(ownerName)}`,
      results: [],
      results_count: 0,
      from_cache: false,
      template_name: TEMPLATES.REPLY,
      template_params: ['Sorry, couldn\'t fetch details.']
    };
  }

  const description = owner.short_description || '';
  const truncatedDesc = description.length > 400 ? description.substring(0, 400) + '...' : description;

  const message = `🏢 *${owner.business_name}*\n\n` +
    `${truncatedDesc}\n\n` +
    `📍 ${[owner.city, owner.state_code].filter(Boolean).join(', ') || 'India'}\n` +
    `📞 ${owner.business_phone_country_code} ${owner.mobile_number || ''}\n` +
    `✉️ ${owner.business_email || ''}\n` +
    `🌐 ${owner.website_url || ''}` +
    `${getMainMenu(ownerName)}`;

  return {
    success: true,
    intent: 'about_owner',
    response_type: 'contact_details',
    detail_level: 'full',
    message,
    results: [owner],
    results_count: 1,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.ABOUT : undefined,
    template_params: [truncatedDesc || 'Business solutions and services.']
  };
}

function handleBookAppointment(
  owner: any | null,
  ownerName: string,
  channel: Channel
): Partial<GroupDiscoveryResponse> {
  const bookingUrl = owner?.booking_url || 'Contact us to schedule';
  
  const message = `📅 *Book an Appointment*\n\n` +
    `Schedule a meeting with us:\n` +
    `🔗 ${bookingUrl}\n\n` +
    `Or reply with your preferred date and time!` +
    `${getMainMenu(ownerName)}`;

  return {
    success: true,
    intent: 'book_appointment',
    response_type: 'booking',
    detail_level: 'none',
    message,
    results: owner ? [owner] : [],
    results_count: owner ? 1 : 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.BOOKING : undefined,
    template_params: [bookingUrl]
  };
}

function handleCallOwner(
  owner: any | null,
  ownerName: string,
  channel: Channel
): Partial<GroupDiscoveryResponse> {
  if (!owner || !owner.mobile_number) {
    return {
      success: false,
      intent: 'call_owner',
      response_type: 'error',
      detail_level: 'none',
      message: `Sorry, contact number not available.${getMainMenu(ownerName)}`,
      results: [],
      results_count: 0,
      from_cache: false,
      template_name: TEMPLATES.REPLY,
      template_params: ['Contact number not available.']
    };
  }

  const phoneNumber = `${owner.business_phone_country_code} ${owner.mobile_number}`;
  const whatsappNumber = owner.business_whatsapp || owner.mobile_number;

  const message = `📞 *Contact Us*\n\n` +
    `📱 Call: ${phoneNumber}\n` +
    `💬 WhatsApp: ${owner.business_whatsapp_country_code} ${whatsappNumber}\n` +
    `✉️ Email: ${owner.business_email || 'N/A'}\n\n` +
    `We're here to help!` +
    `${getMainMenu(ownerName)}`;

  return {
    success: true,
    intent: 'call_owner',
    response_type: 'contact_details',
    detail_level: 'summary',
    message,
    results: [owner],
    results_count: 1,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.CONTACT : undefined,
    template_params: [phoneNumber]
  };
}

function handleExploreDirectory(
  groupName: string,
  channel: Channel
): Partial<GroupDiscoveryResponse> {
  const message = `🔍 *Welcome to ${groupName} Directory!*\n\n` +
    `I can help you find businesses and connect with members.\n\n` +
    `What would you like to do?${getDirectoryMenu()}`;

  return {
    success: true,
    intent: 'explore_bbb',
    response_type: 'directory_welcome',
    detail_level: 'none',
    message,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.WELCOME : undefined,
    template_params: []
  };
}

function handleUnknown(
  ownerName: string,
  channel: Channel
): Partial<GroupDiscoveryResponse> {
  return {
    success: true,
    intent: 'unknown',
    response_type: 'conversation',
    detail_level: 'none',
    message: `${DEFAULT_MESSAGES.unknown}${getMainMenu(ownerName)}`,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.WELCOME : undefined,
    template_params: []
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