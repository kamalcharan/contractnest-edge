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
// TEMPLATE NAMES
// ============================================================================
const TEMPLATES = {
  VANI_WELCOME: 'vani_welcome',
  VANI_CONTACT: 'vani_contact',
  VANI_BOOKING: 'vani_booking',
  VANI_ABOUT: 'vani_about',
  VANI_GOODBYE: 'vani_goodbye',
  BBB_WELCOME: 'bbb_welcome',
  BBB_INDUSTRIES: 'bbb_industries',
  BBB_RESULTS: 'bbb_results',
  BBB_CONTACT: 'bbb_contact',
  VANI_REPLY: 'vani_reply'
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
        error: 'VALIDATION_ERROR',
        template_name: TEMPLATES.VANI_REPLY,
        template_params: [validation.error!]
      }, 400);
    }

    // Detect intent from message (ignore N8N's pre-detected intent)
    const intent: Intent = body.intent || detectIntent(body.message || '', body.channel || 'chat');

// Get or create session (skip for get_contact from vcard/card - phone='system')
let session: Session | null = null;
let isNew = false;
let isMember = false;

if (body.phone !== 'system') {
  const sessionResult = await getOrCreateSession(supabase, body);
  session = sessionResult.session;
  isNew = sessionResult.isNew;
  isMember = sessionResult.isMember;
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
      channel,
      isNewSession: isNew,
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
  is_member: isMember,  // <-- ADD THIS
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
      error: error.message,
      template_name: TEMPLATES.VANI_REPLY,
      template_params: ['Sorry, something went wrong. Please try again.']
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
function detectIntent(message: string, channel: Channel = 'chat'): Intent {
  const msg = message.toLowerCase().trim();

  // VaNi menu options (primarily for WhatsApp)
  if (msg === '1' || msg === 'about vikuna' || msg === 'about') {
    return 'about_owner';
  }
  if (msg === '2' || msg === 'book appointment' || msg === 'book' || msg === 'appointment') {
    return 'book_appointment';
  }
  if (msg === '3' || msg === 'call us' || msg === 'contact us' || msg === 'call vikuna' || msg === 'call') {
    return 'call_owner';
  }
  if (msg === '4' || msg === 'explore bbb' || msg === 'bbb directory' || msg === 'bbb' || msg === 'explore') {
    return 'explore_bbb';
  }

  // Exit patterns
  if (['bye', 'exit', 'quit', 'goodbye', 'end', 'stop', '0'].includes(msg)) {
    return 'goodbye';
  }

  // Greeting patterns - for WhatsApp, new sessions go to owner_welcome
  if (['hi', 'hello', 'hey', 'start', 'menu', 'main menu', 'hii', 'hiii'].some(w => msg === w || msg.startsWith(w + ' '))) {
    return 'welcome';
  }

  // BBB menu patterns
  if (msg === 'browse industries' || msg === 'industries' || msg === 'segments') {
    return 'list_segments';
  }

  // Segments patterns
  if (msg.includes('segment') || msg.includes('industr') || msg.includes('categor') ||
      /show.*(all|every).*(segment|industr|categor)/i.test(msg) ||
      /list.*(all|every).*(segment|industr|categor)/i.test(msg)) {
    return 'list_segments';
  }

  // Members patterns
  if (/who.*(is|are).*(into|in)/i.test(msg) ||
      /(show|list|get|find).*members/i.test(msg) ||
      /(show|list|get|find)\s+(.+?)\s*(companies|businesses)/i.test(msg)) {
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
// SESSION MANAGEMENT (with Membership Check)
// ============================================================================
async function getOrCreateSession(
  supabase: SupabaseClient, 
  body: GroupDiscoveryRequest
): Promise<{ session: Session | null; isNew: boolean; isMember: boolean }> {
  
  const phone = body.phone ? body.phone.replace(/[^0-9]/g, '') : null;
  const phoneNormalized = phone && phone.length === 10 ? '91' + phone : phone;

  // Try to get existing session
  const { data: existing, error: getError } = await supabase.rpc('get_ai_session', {
    p_phone: phone
  });

  if (!getError && existing && existing.length > 0) {
    const session = existing[0];
    // Read is_member from session context (was set on creation)
    const isMember = session.context?.is_member === true;
    return { session, isNew: false, isMember };
  }

  // === NEW: Check membership before creating session ===
  let isMember = false;
  let membershipData: any = null;

  if (body.group_id && phone) {
    const { data: membership, error: memberError } = await supabase
      .from('t_group_memberships')
      .select('id, business_name, owner_name, phone, phone_normalized')
      .eq('group_id', body.group_id)
      .eq('status', 'active')
      .or(`phone.eq.${body.phone},phone_normalized.eq.${phoneNormalized},phone.ilike.%${phone.slice(-10)}%`)
      .limit(1)
      .maybeSingle();

    if (!memberError && membership) {
      isMember = true;
      membershipData = membership;
    }
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
    return { session: null, isNew: false, isMember: false };
  }

  // === NEW: Store is_member in session context ===
  if (newSessionId) {
    await supabase.rpc('update_ai_session', {
      p_session_id: newSessionId,
      p_context: { 
        is_member: isMember,
        membership_id: membershipData?.id || null,
        membership_business_name: membershipData?.business_name || null,
        checked_at: new Date().toISOString()
      },
      p_language: null,
      p_add_message: null
    });
  }

  return { 
    session: { 
      session_id: newSessionId, 
      group_id: body.group_id,
      context: { is_member: isMember }
    } as Session, 
    isNew: true,
    isMember
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
// OWNER LOOKUP (with tenant_profiles join)
// ============================================================================
async function getOwnerDetails(supabase: SupabaseClient, groupId: string): Promise<any | null> {
  try {
    // First get owner from memberships
    const { data: owner, error: ownerError } = await supabase
      .from('t_group_memberships')
      .select('*')
      .eq('group_id', groupId)
      .eq('is_owner', true)
      .single();

    if (ownerError || !owner) return null;

    // Then get contact details from tenant_profiles
    const { data: profile, error: profileError } = await supabase
      .from('t_tenant_profiles')
      .select('*')
      .eq('tenant_id', owner.tenant_id)
      .single();

    // Merge both - profile fields take priority for contact info
    return {
      ...owner,
      business_name: profile?.business_name || owner.profile_data?.business_name || 'Vikuna Technologies',
      mobile_number: profile?.business_phone || owner.mobile_number,
      business_email: profile?.business_email || owner.business_email,
      business_phone_country_code: profile?.business_phone_country_code || owner.business_phone_country_code,
      business_whatsapp: profile?.business_whatsapp || owner.business_whatsapp,
      business_whatsapp_country_code: profile?.business_whatsapp_country_code || owner.business_whatsapp_country_code,
      website_url: profile?.website_url || owner.website_url,
      booking_url: profile?.booking_url || owner.booking_url,
      city: profile?.city || owner.city,
      state_code: profile?.state_code || owner.state_code,
      short_description: profile?.short_description || owner.profile_data?.short_description || ''
    };
  } catch (error) {
    console.error('Owner lookup error:', error);
    return null;
  }
}

// ============================================================================
// VANI MENU HELPER
// ============================================================================
function getVaNiMenu(): string {
  return `\n\nReply with:\n1️⃣ About Vikuna\n2️⃣ Book Appointment\n3️⃣ Call Us\n4️⃣ Explore BBB Directory\n0️⃣ Exit`;
}

function getBBBMenu(): string {
  return `\n\nReply with:\n🔍 Type a business name to search\n📋 Type "industries" to browse\n0️⃣ Back to Main Menu`;
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
    channel: Channel;
    isNewSession: boolean;
    startTime: number;
  }
): Promise<Partial<GroupDiscoveryResponse>> {
  const { intent, body, session, groupName, channel, isNewSession, startTime } = ctx;

  // For WhatsApp new sessions, show VaNi welcome first
  if (channel === 'whatsapp' && isNewSession && intent === 'welcome') {
    return await handleOwnerWelcome(supabase, body.group_id, groupName, channel);
  }

  switch (intent) {
    case 'welcome':
      // Chat UI gets BBB welcome, WhatsApp existing sessions get VaNi menu
      if (channel === 'whatsapp') {
        return await handleOwnerWelcome(supabase, body.group_id, groupName, channel);
      }
      return handleWelcome(groupName, channel);

    case 'goodbye':
      if (body.phone && body.phone !== 'system') {
        await endSession(supabase, body.phone);
      }
      return handleGoodbye(groupName, channel);

    case 'about_owner':
      return await handleAboutOwner(supabase, body.group_id, channel);

    case 'book_appointment':
      return await handleBookAppointment(supabase, body.group_id, channel);

    case 'call_owner':
      return await handleCallOwner(supabase, body.group_id, channel);

    case 'explore_bbb':
      return handleExploreBBB(groupName, channel);

    case 'list_segments':
      const segmentsResult = await handleListSegments(supabase, body.group_id);
      return addTemplate(segmentsResult, channel, TEMPLATES.BBB_INDUSTRIES, 
        segmentsResult.results?.map((s: any) => `${s.segment_name} (${s.member_count})`).join(', ') || '');

    case 'list_members':
      const membersResult = await handleListMembers(supabase, body);
      return addTemplate(membersResult, channel, TEMPLATES.BBB_RESULTS,
        String(membersResult.results_count || 0),
        membersResult.results?.map((m: any) => m.business_name).join(', ') || '');

    case 'search':
      const searchResult = await handleSearch(supabase, body);
      return addTemplate(searchResult, channel, TEMPLATES.BBB_RESULTS,
        String(searchResult.results_count || 0),
        searchResult.results?.map((m: any) => m.business_name).join(', ') || '');

    case 'get_contact':
      const contactResult = await handleGetContact(supabase, body);
      if (contactResult.results && contactResult.results[0]) {
        const c = contactResult.results[0];
        const details = `${c.business_name} - ${(c.short_description || '').substring(0, 100)}. Location: ${c.city || 'India'}. Phone: ${c.phone || 'N/A'}. Email: ${c.email || 'N/A'}`;
        return addTemplate(contactResult, channel, TEMPLATES.BBB_CONTACT, details);
      }
      return addTemplate(contactResult, channel, TEMPLATES.VANI_REPLY, contactResult.message || 'Contact not found.');

    default:
      return handleUnknown(channel);
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
// OWNER/VANI HANDLERS
// ============================================================================
async function handleOwnerWelcome(
  supabase: SupabaseClient,
  groupId: string,
  groupName: string,
  channel: Channel
): Promise<Partial<GroupDiscoveryResponse>> {
  const owner = await getOwnerDetails(supabase, groupId);
  
  const ownerName = owner?.business_name || 'Vikuna Technologies';
  
  const message = `👋 Welcome! I'm *VaNi*, your AI assistant from *${ownerName}*.\n\nHow can I help you today?${getVaNiMenu()}`;

  return {
    success: true,
    intent: 'welcome',
    response_type: 'owner_welcome',
    detail_level: 'none',
    message,
    results: owner ? [owner] : [],
    results_count: owner ? 1 : 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.VANI_WELCOME : undefined,
    template_params: []
  };
}

async function handleAboutOwner(
  supabase: SupabaseClient,
  groupId: string,
  channel: Channel
): Promise<Partial<GroupDiscoveryResponse>> {
  const owner = await getOwnerDetails(supabase, groupId);

  if (!owner) {
    return {
      success: false,
      intent: 'about_owner',
      response_type: 'error',
      detail_level: 'none',
      message: `Sorry, couldn't fetch details.${getVaNiMenu()}`,
      results: [],
      results_count: 0,
      from_cache: false,
      template_name: TEMPLATES.VANI_REPLY,
      template_params: ['Sorry, couldn\'t fetch details. Please try again.']
    };
  }

  const description = owner.short_description || '';
  const truncatedDesc = description.length > 400 ? description.substring(0, 400) + '...' : description;

  const message = `🏢 *${owner.business_name}*\n\n` +
    `${truncatedDesc}\n\n` +
    `📍 ${[owner.city, owner.state_code].filter(Boolean).join(', ') || 'India'}\n` +
    `📞 ${owner.business_phone_country_code || '+91'} ${owner.mobile_number || ''}\n` +
    `✉️ ${owner.business_email || ''}\n` +
    `🌐 ${owner.website_url || ''}` +
    `${getVaNiMenu()}`;

  return {
    success: true,
    intent: 'about_owner',
    response_type: 'contact_details',
    detail_level: 'full',
    message,
    results: [owner],
    results_count: 1,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.VANI_ABOUT : undefined,
    template_params: [truncatedDesc || 'AI transformation consulting and digital solutions for enterprises.']
  };
}

async function handleBookAppointment(
  supabase: SupabaseClient,
  groupId: string,
  channel: Channel
): Promise<Partial<GroupDiscoveryResponse>> {
  const owner = await getOwnerDetails(supabase, groupId);

  const bookingUrl = owner?.booking_url || 'https://calendly.com/vikuna';
  
  const message = `📅 *Book an Appointment*\n\n` +
    `Schedule a meeting with us:\n` +
    `🔗 ${bookingUrl}\n\n` +
    `Or reply with your preferred date and time, and we'll get back to you!` +
    `${getVaNiMenu()}`;

  return {
    success: true,
    intent: 'book_appointment',
    response_type: 'booking',
    detail_level: 'none',
    message,
    results: owner ? [owner] : [],
    results_count: owner ? 1 : 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.VANI_BOOKING : undefined,
    template_params: [bookingUrl]
  };
}

async function handleCallOwner(
  supabase: SupabaseClient,
  groupId: string,
  channel: Channel
): Promise<Partial<GroupDiscoveryResponse>> {
  const owner = await getOwnerDetails(supabase, groupId);

  if (!owner || !owner.mobile_number) {
    return {
      success: false,
      intent: 'call_owner',
      response_type: 'error',
      detail_level: 'none',
      message: `Sorry, contact number not available.${getVaNiMenu()}`,
      results: [],
      results_count: 0,
      from_cache: false,
      template_name: TEMPLATES.VANI_REPLY,
      template_params: ['Sorry, contact number not available.']
    };
  }

  const phoneNumber = `${owner.business_phone_country_code || '+91'} ${owner.mobile_number}`;
  const whatsappNumber = owner.business_whatsapp || owner.mobile_number;

  const message = `📞 *Contact Us*\n\n` +
    `📱 Call: ${phoneNumber}\n` +
    `💬 WhatsApp: ${owner.business_whatsapp_country_code || '+91'} ${whatsappNumber}\n` +
    `✉️ Email: ${owner.business_email || ''}\n\n` +
    `We're here to help!` +
    `${getVaNiMenu()}`;

  return {
    success: true,
    intent: 'call_owner',
    response_type: 'contact_details',
    detail_level: 'summary',
    message,
    results: [owner],
    results_count: 1,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.VANI_CONTACT : undefined,
    template_params: [phoneNumber]
  };
}

function handleExploreBBB(groupName: string, channel: Channel): Partial<GroupDiscoveryResponse> {
  const message = `🔍 *Welcome to ${groupName} Business Directory!*\n\n` +
    `I can help you find businesses and connect with members.\n\n` +
    `What would you like to do?${getBBBMenu()}`;

  return {
    success: true,
    intent: 'explore_bbb',
    response_type: 'bbb_welcome',
    detail_level: 'none',
    message,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.BBB_WELCOME : undefined,
    template_params: []
  };
}

// ============================================================================
// BBB HANDLERS (existing)
// ============================================================================
function handleWelcome(groupName: string, channel: Channel): Partial<GroupDiscoveryResponse> {
  return {
    success: true,
    intent: 'welcome',
    response_type: 'welcome',
    detail_level: 'none',
    message: `👋 Welcome to *${groupName}* Business Directory!\n\nI can help you:\n• 🔍 Search for businesses\n• 📋 Browse by industry\n• 📞 Get contact details\n\nWhat would you like to find?`,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.BBB_WELCOME : undefined,
    template_params: []
  };
}

function handleGoodbye(groupName: string, channel: Channel): Partial<GroupDiscoveryResponse> {
  const message = channel === 'whatsapp' 
    ? `👋 Thank you for using *VaNi*. Have a great day!\n\nType "Hi" anytime to start again.`
    : `👋 Thank you for using *${groupName}* Directory. Goodbye!`;

  return {
    success: true,
    intent: 'goodbye',
    response_type: 'goodbye',
    detail_level: 'none',
    message,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.VANI_GOODBYE : undefined,
    template_params: []
  };
}

function handleUnknown(channel: Channel): Partial<GroupDiscoveryResponse> {
  const menu = channel === 'whatsapp' ? getVaNiMenu() : '';
  
  return {
    success: true,
    intent: 'unknown',
    response_type: 'conversation',
    detail_level: 'none',
    message: `I'm not sure what you're looking for. Let me help you with some options.${menu}`,
    results: [],
    results_count: 0,
    from_cache: false,
    template_name: channel === 'whatsapp' ? TEMPLATES.VANI_WELCOME : undefined,
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