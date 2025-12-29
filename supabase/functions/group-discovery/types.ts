// supabase/functions/group-discovery/types.ts

// ============================================================================
// CORE TYPES
// ============================================================================

export type Intent = 
  | 'welcome' 
  | 'goodbye' 
  | 'list_segments' 
  | 'list_members' 
  | 'search'
  | 'search_prompt'
  | 'get_contact'
  | 'about_owner'
  | 'book_appointment'
  | 'call_owner'
  | 'explore_bbb'
  | 'unknown';

export type ResponseType = 
  | 'welcome' 
  | 'goodbye' 
  | 'segments_list' 
  | 'members_list'
  | 'search_results' 
  | 'contact_details' 
  | 'conversation'
  | 'owner_welcome'
  | 'booking'
  | 'bbb_welcome'
  | 'error';

export type DetailLevel = 'none' | 'summary' | 'list' | 'full';

export type Channel = 'chat' | 'whatsapp' | 'api';

// ============================================================================
// REQUEST/RESPONSE
// ============================================================================

export interface GroupDiscoveryRequest {
  intent?: Intent;
  message?: string;
  phone?: string;
  user_id?: string;
  group_id: string;
  channel?: Channel;
  params?: {
    query?: string;
    segment?: string;
    industry?: string;
    membership_id?: string;
    business_name?: string;
    limit?: number;
    offset?: number;
    embedding?: number[];
    [key: string]: any;
  };
}

export interface GroupDiscoveryResponse {
  success: boolean;
  intent: Intent;
  response_type: ResponseType;
  detail_level: DetailLevel;
  message: string;
  results: any[];
  results_count: number;
  total_count?: number;
  session_id: string | null;
  is_new_session: boolean;
  group_id: string;
  group_name: string;
  channel: Channel;
  from_cache: boolean;
  duration_ms: number;
  query?: string;
  filters?: Record<string, any>;
  original_phone?: string;
  error?: string;
  template_name?: string;
  template_params?: string[];
}

// ============================================================================
// SESSION
// ============================================================================

export interface Session {
  session_id: string;
  group_id: string;
  user_id?: string;
  phone?: string;
  channel?: Channel;
  context?: Record<string, any>;
  language?: string;
  created_at?: string;
  updated_at?: string;
  expires_at?: string;
}

// ============================================================================
// RESULTS
// ============================================================================

export interface SegmentResult {
  segment_name: string;
  industry_id: string;
  member_count: number;
}

export interface MemberResult {
  rank: number;
  membership_id: string;
  business_name: string;
  logo_url?: string;
  short_description?: string;
  industry: string;
  chapter?: string;
  city?: string;
  phone?: string;
  phone_country_code?: string;
  email?: string;
  website?: string;
  similarity?: number;
  card_url?: string;
  vcard_url?: string;
  actions?: ActionButton[];
}

export interface ContactResult extends MemberResult {
  ai_enhanced_description?: string;
  state?: string;
  address?: string;
  full_address?: string;
  whatsapp?: string;
  whatsapp_country_code?: string;
  booking_url?: string;
  semantic_clusters?: string[];
  profile_data?: Record<string, any>;
  is_owner?: boolean;
}

// ============================================================================
// ACTION BUTTONS
// ============================================================================

export interface ActionButton {
  type: 'call' | 'whatsapp' | 'email' | 'website' | 'booking' | 'card' | 'vcard' | 'details';
  label: string;
  value: string;
}

// ============================================================================
// RPC RESPONSE TYPES
// ============================================================================

export interface SegmentRpcResponse {
  segment_name: string;
  industry_id: string;
  member_count: number | string;
}

export interface MemberRpcResponse {
  membership_id: string;
  business_name: string;
  logo_url?: string;
  short_description?: string;
  industry?: string;
  chapter?: string;
  city?: string;
  contact_phone?: string;
  contact_email?: string;
  website_url?: string;
  business_phone_country_code?: string;
  total_count?: number | string;
}

export interface SearchRpcResponse {
  membership_id: string;
  business_name: string;
  logo_url?: string;
  description?: string;
  profile_snippet?: string;
  industry?: string;
  chapter?: string;
  city?: string;
  phone?: string;
  email?: string;
  website?: string;
  similarity?: number;
}

export interface ContactRpcResponse {
  membership_id: string;
  business_name?: string;
  logo_url?: string;
  short_description?: string;
  ai_enhanced_description?: string;
  industry?: string;
  chapter?: string;
  city?: string;
  state_code?: string;
  address_line1?: string;
  full_address?: string;
  mobile_number?: string;
  business_phone_country_code?: string;
  business_whatsapp?: string;
  business_whatsapp_country_code?: string;
  business_email?: string;
  website_url?: string;
  booking_url?: string;
  card_url?: string;
  vcard_url?: string;
  semantic_clusters?: string[];
}