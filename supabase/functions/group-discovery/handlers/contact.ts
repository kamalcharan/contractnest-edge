// supabase/functions/group-discovery/handlers/contact.ts

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import type { 
  GroupDiscoveryRequest,
  GroupDiscoveryResponse, 
  ContactResult,
  ContactRpcResponse,
  ActionButton
} from "../types.ts";

// ============================================================================
// CONSTANTS
// ============================================================================
// UPDATE THESE URLs after importing the new workflow - get Production URLs from N8N
const BASE_URL_CARD = 'https://api.contractnest.com/card';
const BASE_URL_VCARD = 'https://api.contractnest.com/vcard';

// ============================================================================
// EXTRACT BUSINESS NAME FROM MESSAGE
// ============================================================================
function extractBusinessName(message: string | undefined): string | null {
  if (!message) return null;
  
  // Pattern: "details for [business]" or "contact for [business]" or "about [business]"
  const patterns = [
    /(?:details?|contact|info|about)\s+(?:for\s+|of\s+)?(.+)/i,
    /(?:tell me about|more about)\s+(.+)/i,
    /(?:get|show|find)\s+(?:details?|contact|info)\s+(?:for\s+|of\s+)?(.+)/i
  ];

  for (const pattern of patterns) {
    const match = message.match(pattern);
    if (match && match[1]) {
      return match[1].trim();
    }
  }

  return null;
}

// ============================================================================
// BUILD ACTION BUTTONS
// ============================================================================
function buildActions(contact: ContactRpcResponse): ActionButton[] {
  const actions: ActionButton[] = [];

  if (contact.mobile_number) {
    actions.push({
      type: 'call',
      label: 'Call',
      value: contact.mobile_number
    });
  }

  if (contact.business_whatsapp) {
    actions.push({
      type: 'whatsapp',
      label: 'WhatsApp',
      value: contact.business_whatsapp
    });
  }

  if (contact.business_email) {
    actions.push({
      type: 'email',
      label: 'Email',
      value: contact.business_email
    });
  }

  if (contact.website_url) {
    actions.push({
      type: 'website',
      label: 'Website',
      value: contact.website_url
    });
  }

  if (contact.booking_url) {
    actions.push({
      type: 'booking',
      label: 'Book Now',
      value: contact.booking_url
    });
  }

  actions.push({
    type: 'card',
    label: 'View Card',
    value: `${BASE_URL_CARD}/${contact.membership_id}`
  });

  actions.push({
    type: 'vcard',
    label: 'Save Contact',
    value: `${BASE_URL_VCARD}/${contact.membership_id}`
  });

  return actions;
}

// ============================================================================
// GET CONTACT HANDLER
// ============================================================================
export async function handleGetContact(
  supabase: SupabaseClient,
  body: GroupDiscoveryRequest
): Promise<Partial<GroupDiscoveryResponse>> {
  
  try {
    // Get membership_id or business_name from params or message
    const membershipId = body.params?.membership_id || null;
    const businessName = body.params?.business_name || extractBusinessName(body.message);

    if (!membershipId && !businessName) {
      return {
        success: false,
        intent: 'get_contact',
        response_type: 'error',
        detail_level: 'none',
        message: 'Please specify a business name or ID to get contact details.',
        results: [],
        results_count: 0,
        from_cache: false
      };
    }

    // If no group_id but have membership_id, look up group_id first
    let groupId = body.group_id;
    if ((!groupId || groupId === '') && membershipId) {
      const { data: membership } = await supabase
        .from('t_group_memberships')
        .select('group_id')
        .eq('id', membershipId)
        .single();
      
      if (membership) {
        groupId = membership.group_id;
      }
    }

    // Call existing RPC: get_member_contact
    const { data, error } = await supabase.rpc('get_member_contact', {
      p_membership_id: membershipId,
      p_group_id: groupId || null,
      p_scope: 'group',
      p_business_name: businessName
    });

    if (error) {
      console.error('Error fetching contact:', error);
      return {
        success: false,
        intent: 'get_contact',
        response_type: 'error',
        detail_level: 'none',
        message: 'Unable to load contact. Please try again.',
        results: [],
        results_count: 0,
        from_cache: false
      };
    }

    // Handle not found
    const contacts = Array.isArray(data) ? data : [data];
    const contact = contacts[0] as ContactRpcResponse | undefined;

    if (!contact || !contact.membership_id) {
      return {
        success: false,
        intent: 'get_contact',
        response_type: 'error',
        detail_level: 'none',
        message: `Contact not found${businessName ? ` for "${businessName}"` : ''}. Please check the name and try again.`,
        results: [],
        results_count: 0,
        from_cache: false
      };
    }

    // Format contact
    const formattedContact: ContactResult = {
      rank: 1,
      membership_id: contact.membership_id,
      business_name: contact.business_name || 'Unknown',
      logo_url: contact.logo_url || undefined,
      short_description: contact.short_description || undefined,
      ai_enhanced_description: contact.ai_enhanced_description || undefined,
      industry: contact.industry || 'General',
      chapter: contact.chapter || undefined,
      city: (contact.city || '').replace(/[\r\n]/g, '').trim(),
      state: contact.state_code || undefined,
      address: contact.address_line1 || undefined,
      full_address: contact.full_address || undefined,
      phone: contact.mobile_number || undefined,
      phone_country_code: contact.business_phone_country_code || '+91',
      whatsapp: contact.business_whatsapp || undefined,
      whatsapp_country_code: contact.business_whatsapp_country_code || '+91',
      email: contact.business_email || undefined,
      website: contact.website_url || undefined,
      booking_url: contact.booking_url || undefined,
      card_url: `${BASE_URL_CARD}/${contact.membership_id}`,
      vcard_url: `${BASE_URL_VCARD}/${contact.membership_id}`,
      semantic_clusters: contact.semantic_clusters || undefined,
      actions: buildActions(contact)
    };

    // Build message
    const message = `📇 **${formattedContact.business_name}**\n` +
      (formattedContact.industry !== 'General' ? `🏷️ ${formattedContact.industry}\n` : '') +
      (formattedContact.chapter ? `📍 ${formattedContact.chapter}\n` : '');

    return {
      success: true,
      intent: 'get_contact',
      response_type: 'contact_details',
      detail_level: 'full',
      message,
      results: [formattedContact],
      results_count: 1,
      from_cache: false
    };

  } catch (error) {
    console.error('Exception in handleGetContact:', error);
    return {
      success: false,
      intent: 'get_contact',
      response_type: 'error',
      detail_level: 'none',
      message: 'An error occurred while fetching contact details.',
      results: [],
      results_count: 0,
      from_cache: false
    };
  }
}