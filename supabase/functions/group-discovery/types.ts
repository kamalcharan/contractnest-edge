// supabase/functions/group-discovery/types.ts

// ============================================================================
// REQUEST TYPES
// ============================================================================

export type Intent = 
  | 'welcome' 
  | 'goodbye' 
  | 'list_segments' 
  | 'list_members' 
  | 'search' 
  | 'get_contact'
  | 'unknown';

export type Channel = 'chat' | 'whatsapp';

export type ResponseType = 
  | 'welcome' 
  | 'goodbye' 
  | 'segments_list' 
  | 'search_results' 
  | 'contact_details' 
  | 'conversation'
  | 'error';

export type DetailLevel = 'none' | 'list' | 'summary' | 'full';

export interface RequestParams {
  query?: string;
  segment?: string;
  membership_id?: string;
  business_name?: string;
  limit?: number;
  offset?: number;
  embedding?: number[];  // Passed from N8N for search
}

export interface GroupDiscoveryRequest {
  intent?: Intent;
  message?: string;
  phone?: string;
  user_id?: string;
  group_id: string;
  channel?: Channel;
  params?: RequestParams;
}

// ============================================================================
// RESPONSE TYPES
// ============================================================================

export interface ActionButton {
  type: 'call' | 'whatsapp' | 'email' | 'website' | 'booking' | 'details' | 'card' | 'vcard';
  label: string;
  value: string;
}

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
  industry?: string;
  chapter?: string;
  city?: string;
  phone?: string;
  phone_country_code?: string;
  email?: string;
  website?: string;
  similarity?: number;
  card_url: string;
  vcard_url: string;
  actions: ActionButton[];
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
}

export type ResultItem = SegmentResult | MemberResult | ContactResult;

export interface GroupDiscoveryResponse {
  success: boolean;
  intent: Intent;
  response_type: ResponseType;
  detail_level: DetailLevel;
  message: string;
  results: ResultItem[];
  results_count: number;
  total_count?: number;
  query?: string;
  filters?: Record<string, string | null>;
  session_id: string | null;
  is_new_session: boolean;
  group_id: string;
  group_name: string;
  channel: Channel;
  from_cache: boolean;
  duration_ms: number;
  error?: string;
}

// ============================================================================
// SESSION TYPES
// ============================================================================

export interface Session {
  session_id: string;
  user_id?: string;
  phone?: string;
  group_id: string;
  group_code?: string;
  group_name?: string;
  session_scope?: string;
  channel?: string;
  context?: Record<string, unknown>;
  conversation_history?: unknown[];
  detected_language?: string;
  started_at?: string;
  last_activity_at?: string;
  expires_at?: string;
}

// ============================================================================
// RPC RESPONSE TYPES
// ============================================================================

export interface SegmentRpcResponse {
  segment_name: string;
  industry_id: string;
  member_count: number;
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
  business_phone_country_code?: string;
  contact_email?: string;
  website_url?: string;
  total_count?: number;
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
  similarity: number;
  cluster_boost?: number;
}

export interface ContactRpcResponse {
  membership_id: string;
  business_name: string;
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
  has_access?: boolean;
}