// supabase/functions/group-discovery/handlers/members.ts

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import type { 
  GroupDiscoveryRequest,
  GroupDiscoveryResponse, 
  MemberResult,
  MemberRpcResponse,
  ActionButton
} from "../types.ts";

// ============================================================================
// CONSTANTS
// ============================================================================
const BASE_URL = 'https://n8n.srv1096269.hstgr.cloud/webhook';

// ============================================================================
// SEGMENT NORMALIZATION MAP
// ============================================================================
const SEGMENT_MAP: Record<string, string> = {
  'tech': 'Technology',
  'technology': 'Technology',
  'it': 'Technology',
  'software': 'Technology',
  'agri': 'Agriculture',
  'agriculture': 'Agriculture',
  'farming': 'Agriculture',
  'farm': 'Agriculture',
  'finance': 'Financial Services',
  'financial': 'Financial Services',
  'banking': 'Financial Services',
  'real estate': 'Real Estate & Construction',
  'realestate': 'Real Estate & Construction',
  'construction': 'Real Estate & Construction',
  'property': 'Real Estate & Construction'
};

// ============================================================================
// NORMALIZE SEGMENT NAME
// ============================================================================
function normalizeSegment(segment: string | undefined): string | null {
  if (!segment) return null;
  const key = segment.toLowerCase().trim();
  return SEGMENT_MAP[key] || segment;
}

// ============================================================================
// EXTRACT SEGMENT FROM MESSAGE
// ============================================================================
function extractSegmentFromMessage(message: string | undefined): string | null {
  if (!message) return null;
  const msg = message.toLowerCase();

  // Pattern: "who is into [segment]"
  const whoMatch = msg.match(/who.*(is|are).*(into|in)\s+(.+)/i);
  if (whoMatch) {
    return normalizeSegment(whoMatch[3].trim());
  }

  // Pattern: "show [segment] companies"
  const showMatch = msg.match(/(show|list|get|find)\s+(.+?)\s*(companies|businesses|members|firms|people)/i);
  if (showMatch) {
    return normalizeSegment(showMatch[2].trim());
  }

  return null;
}

// ============================================================================
// BUILD ACTION BUTTONS
// ============================================================================
function buildActions(member: MemberRpcResponse): ActionButton[] {
  const actions: ActionButton[] = [];

  if (member.contact_phone) {
    actions.push({
      type: 'call',
      label: 'Call',
      value: member.contact_phone
    });
  }

  if (member.contact_email) {
    actions.push({
      type: 'email',
      label: 'Email',
      value: member.contact_email
    });
  }

  if (member.website_url) {
    actions.push({
      type: 'website',
      label: 'Website',
      value: member.website_url
    });
  }

  actions.push({
    type: 'details',
    label: 'Get Details',
    value: member.membership_id
  });

  return actions;
}

// ============================================================================
// LIST MEMBERS HANDLER
// ============================================================================
export async function handleListMembers(
  supabase: SupabaseClient,
  body: GroupDiscoveryRequest
): Promise<Partial<GroupDiscoveryResponse>> {
  
  try {
    // Get segment from params or extract from message
    const segment = normalizeSegment(body.params?.segment) || 
                    extractSegmentFromMessage(body.message);
    
    const limit = body.params?.limit || 10;
    const offset = body.params?.offset || 0;

    // Call existing RPC: get_members_by_scope
    const { data, error } = await supabase.rpc('get_members_by_scope', {
      p_scope: 'group',
      p_group_id: body.group_id,
      p_industry_filter: segment,
      p_chapter_filter: null,
      p_search_text: null,
      p_limit: limit,
      p_offset: offset
    });

    if (error) {
      console.error('Error fetching members:', error);
      return {
        success: false,
        intent: 'list_members',
        response_type: 'error',
        detail_level: 'none',
        message: 'Unable to load members. Please try again.',
        results: [],
        results_count: 0,
        from_cache: false
      };
    }

    // Handle empty results
    const segmentDisplay = segment || 'all industries';
    
    if (!data || data.length === 0) {
      return {
        success: true,
        intent: 'list_members',
        response_type: 'search_results',
        detail_level: 'summary',
        message: `No members found in ${segmentDisplay}.`,
        results: [],
        results_count: 0,
        total_count: 0,
        filters: { segment },
        from_cache: false
      };
    }

    // Get total count from first record
    const totalCount = (data as MemberRpcResponse[])[0]?.total_count || data.length;

    // Format members
    const members: MemberResult[] = (data as MemberRpcResponse[])
      .filter(m => m && m.membership_id)
      .map((m, idx) => ({
        rank: idx + 1,
        membership_id: m.membership_id,
        business_name: m.business_name || 'Unknown',
        logo_url: m.logo_url || undefined,
        short_description: (m.short_description || '').substring(0, 200),
        industry: m.industry || 'General',
        chapter: m.chapter || undefined,
        city: (m.city || '').replace(/[\r\n]/g, '').trim(),
        phone: m.contact_phone || undefined,
        phone_country_code: m.business_phone_country_code || '+91',
        email: m.contact_email || undefined,
        website: m.website_url || undefined,
        card_url: `${BASE_URL}/card/${m.membership_id}`,
        vcard_url: `${BASE_URL}/vcard/${m.membership_id}`,
        actions: buildActions(m)
      }));

    // Build message
    const message = `Found ${totalCount} member${totalCount !== 1 ? 's' : ''} in **${segmentDisplay}**:`;

    return {
      success: true,
      intent: 'list_members',
      response_type: 'search_results',
      detail_level: 'summary',
      message,
      results: members,
      results_count: members.length,
      total_count: Number(totalCount),
      filters: { segment },
      from_cache: false
    };

  } catch (error) {
    console.error('Exception in handleListMembers:', error);
    return {
      success: false,
      intent: 'list_members',
      response_type: 'error',
      detail_level: 'none',
      message: 'An error occurred while fetching members.',
      results: [],
      results_count: 0,
      from_cache: false
    };
  }
}