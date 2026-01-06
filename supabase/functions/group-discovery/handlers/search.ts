// supabase/functions/group-discovery/handlers/search.ts

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import type { 
  GroupDiscoveryRequest,
  GroupDiscoveryResponse, 
  MemberResult,
  SearchRpcResponse,
  ActionButton
} from "../types.ts";

// ============================================================================
// CONSTANTS
// ============================================================================
const BASE_URL = 'https://n8n.srv1096269.hstgr.cloud/webhook';
const CACHE_TTL_HOURS = 1;

// ============================================================================
// BUILD ACTION BUTTONS
// ============================================================================
function buildActions(result: SearchRpcResponse): ActionButton[] {
  const actions: ActionButton[] = [];

  if (result.phone) {
    actions.push({
      type: 'call',
      label: 'Call',
      value: result.phone
    });
  }

  if (result.email) {
    actions.push({
      type: 'email',
      label: 'Email',
      value: result.email
    });
  }

  if (result.website) {
    actions.push({
      type: 'website',
      label: 'Website',
      value: result.website
    });
  }

  actions.push({
    type: 'details',
    label: 'Get Details',
    value: result.membership_id
  });

  return actions;
}

// ============================================================================
// CHECK CACHE
// ============================================================================
async function checkCache(
  supabase: SupabaseClient,
  queryNormalized: string,
  groupId: string
): Promise<MemberResult[] | null> {
  
  try {
    const cacheExpiry = new Date(Date.now() - CACHE_TTL_HOURS * 60 * 60 * 1000).toISOString();
    
    const { data, error } = await supabase
      .from('t_query_cache')
      .select('results')
      .eq('query_normalized', queryNormalized)
      .eq('group_id', groupId)
      .gte('created_at', cacheExpiry)
      .limit(1)
      .single();

    if (error || !data || !data.results) {
      return null;
    }

    // Parse results if string
    const results = typeof data.results === 'string' 
      ? JSON.parse(data.results) 
      : data.results;

    // Ensure array
    if (!Array.isArray(results)) {
      return null;
    }

    return results as MemberResult[];

  } catch (error) {
    console.error('Cache check error:', error);
    return null;
  }
}

// ============================================================================
// STORE CACHE
// ============================================================================
async function storeCache(
  supabase: SupabaseClient,
  groupId: string,
  queryText: string,
  queryNormalized: string,
  results: MemberResult[]
): Promise<void> {
  
  try {
    await supabase.rpc('store_search_cache', {
      p_group_id: groupId,
      p_query_text: queryText,
      p_query_normalized: queryNormalized,
      p_query_embedding: null,
      p_results: results,
      p_results_count: results.length,
      p_search_type: 'vector'
    });
  } catch (error) {
    console.error('Cache store error:', error);
    // Don't throw - caching is optional
  }
}

// ============================================================================
// SEARCH HANDLER
// ============================================================================
export async function handleSearch(
  supabase: SupabaseClient,
  body: GroupDiscoveryRequest
): Promise<Partial<GroupDiscoveryResponse>> {
  
  try {
    // Get query from params or message
    const query = body.params?.query || body.message || '';
    const queryNormalized = query.toLowerCase().trim();
    
    if (!queryNormalized) {
      return {
        success: false,
        intent: 'search',
        response_type: 'error',
        detail_level: 'none',
        message: 'Please provide a search query.',
        results: [],
        results_count: 0,
        query,
        from_cache: false
      };
    }

    // Check cache first
    const cachedResults = await checkCache(supabase, queryNormalized, body.group_id);
    
    if (cachedResults && cachedResults.length > 0) {
      const message = `Found ${cachedResults.length} business${cachedResults.length !== 1 ? 'es' : ''} matching "${query}":`;
      
      return {
        success: true,
        intent: 'search',
        response_type: 'search_results',
        detail_level: 'summary',
        message,
        results: cachedResults,
        results_count: cachedResults.length,
        query,
        from_cache: true
      };
    }

    // Check if embedding is provided (from N8N)
    const embedding = body.params?.embedding;
    
    if (!embedding || !Array.isArray(embedding) || embedding.length === 0) {
      return {
        success: false,
        intent: 'search',
        response_type: 'error',
        detail_level: 'none',
        message: 'Search requires embedding. Please try again.',
        results: [],
        results_count: 0,
        query,
        from_cache: false
      };
    }

    // Call existing RPC: search_businesses_v2
    const { data, error } = await supabase.rpc('search_businesses_v2', {
      p_query_text: query,
      p_embedding: JSON.stringify(embedding),
      p_group_id: body.group_id,
      p_threshold: 0.3,
      p_limit: body.params?.limit || 10
    });

    if (error) {
      console.error('Error in search RPC:', error);
      return {
        success: false,
        intent: 'search',
        response_type: 'error',
        detail_level: 'none',
        message: 'Search failed. Please try again.',
        results: [],
        results_count: 0,
        query,
        from_cache: false
      };
    }

    // Ensure data is an array (safety check)
    const dataArray: SearchRpcResponse[] = data?.results || [];

    // Handle empty results
    if (dataArray.length === 0) {
      return {
        success: true,
        intent: 'search',
        response_type: 'search_results',
        detail_level: 'summary',
        message: `No businesses found matching "${query}". Try different keywords.`,
        results: [],
        results_count: 0,
        query,
        from_cache: false
      };
    }

    // Format results
    const results: MemberResult[] = dataArray
      .filter((r: SearchRpcResponse) => r && r.membership_id)
      .map((r: SearchRpcResponse, idx: number) => ({
        rank: idx + 1,
        membership_id: r.membership_id,
        business_name: r.business_name || 'Unknown',
        logo_url: r.logo_url || undefined,
        short_description: (r.description || r.profile_snippet || '').substring(0, 200),
        industry: r.industry || 'General',
        chapter: r.chapter || undefined,
        city: (r.city || '').replace(/[\r\n]/g, '').trim(),
        phone: r.phone || undefined,
        phone_country_code: '+91',
        email: r.email || undefined,
        website: r.website || undefined,
        similarity: typeof r.similarity === 'number' ? Math.round(r.similarity * 100) : 0,
        card_url: `${BASE_URL}/card/${r.membership_id}`,
        vcard_url: `${BASE_URL}/vcard/${r.membership_id}`,
        actions: buildActions(r)
      }));

    // Store in cache (async, don't wait)
    storeCache(supabase, body.group_id, query, queryNormalized, results);

    // Build message
    const message = `Found ${results.length} business${results.length !== 1 ? 'es' : ''} matching "${query}":`;

    return {
      success: true,
      intent: 'search',
      response_type: 'search_results',
      detail_level: 'summary',
      message,
      results,
      results_count: results.length,
      query,
      from_cache: false
    };

  } catch (error) {
    console.error('Exception in handleSearch:', error);
    return {
      success: false,
      intent: 'search',
      response_type: 'error',
      detail_level: 'none',
      message: 'An error occurred while searching.',
      results: [],
      results_count: 0,
      from_cache: false
    };
  }
}