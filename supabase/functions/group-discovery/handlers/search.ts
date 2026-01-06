// supabase/functions/group-discovery/handlers/search.ts
// FIXED: Higher threshold + text relevance filtering

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

// Search thresholds
const SIMILARITY_THRESHOLD = 0.5;  // Increased from 0.3 to 0.5
const STRICT_THRESHOLD = 0.65;     // For very relevant results

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
// TEXT RELEVANCE CHECK
// Ensures results actually contain search terms (case-insensitive)
// ============================================================================
function isTextRelevant(result: SearchRpcResponse, searchTerms: string[]): boolean {
  // Build searchable text from all relevant fields
  const searchableText = [
    result.business_name || '',
    result.description || '',
    result.profile_snippet || '',
    result.industry || '',
    result.city || '',
    result.chapter || ''
  ].join(' ').toLowerCase();

  // Check if ANY search term is found (case-insensitive)
  return searchTerms.some(term => {
    // Escape special regex characters and handle underscores/spaces
    const normalizedTerm = term
      .replace(/[_\-]/g, ' ')  // Replace underscores/dashes with spaces
      .replace(/\s+/g, ' ')    // Normalize whitespace
      .trim();
    
    // Check for partial match (contains)
    return searchableText.includes(normalizedTerm) ||
           searchableText.includes(term);
  });
}

// ============================================================================
// NORMALIZE SEARCH QUERY
// ============================================================================
function normalizeQuery(query: string): { normalized: string; terms: string[] } {
  const normalized = query
    .toLowerCase()
    .replace(/[_\-]/g, ' ')  // Replace underscores/dashes with spaces
    .replace(/\s+/g, ' ')    // Normalize whitespace
    .trim();
  
  // Split into individual terms for matching
  const terms = normalized
    .split(' ')
    .filter(t => t.length >= 2);  // Ignore very short terms
  
  return { normalized, terms };
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
// FALLBACK TEXT SEARCH (when embedding search returns no relevant results)
// ============================================================================
async function fallbackTextSearch(
  supabase: SupabaseClient,
  groupId: string,
  searchTerms: string[],
  limit: number = 10
): Promise<SearchRpcResponse[]> {
  try {
    // Build ILIKE conditions for each term (case-insensitive)
    // Search in business_name, industry, and profile_data
    const { data, error } = await supabase
      .from('t_group_memberships')
      .select(`
        id,
        tenant_id,
        profile_data,
        is_active
      `)
      .eq('group_id', groupId)
      .eq('is_active', true)
      .limit(limit * 2);  // Get more to filter

    if (error || !data) {
      console.error('Fallback text search error:', error);
      return [];
    }

    // Filter results that match search terms
    const results: SearchRpcResponse[] = [];
    
    for (const row of data) {
      const profile = row.profile_data || {};
      const businessName = profile.business_name || '';
      const description = profile.short_description || profile.ai_enhanced_description || '';
      const industry = profile.industry || '';
      
      const searchableText = `${businessName} ${description} ${industry}`.toLowerCase();
      
      // Check if any search term matches
      const matches = searchTerms.some(term => searchableText.includes(term));
      
      if (matches) {
        results.push({
          membership_id: row.id,
          business_name: businessName,
          description: description,
          industry: industry,
          city: profile.city || '',
          phone: profile.phone || '',
          email: profile.email || '',
          website: profile.website_url || '',
          similarity: 0.5,  // Default similarity for text matches
          logo_url: profile.logo_url
        });
      }
      
      if (results.length >= limit) break;
    }
    
    return results;
  } catch (error) {
    console.error('Fallback text search exception:', error);
    return [];
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
    const { normalized: queryNormalized, terms: searchTerms } = normalizeQuery(query);
    
    if (!queryNormalized || searchTerms.length === 0) {
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
    
    let dataArray: SearchRpcResponse[] = [];
    let usedFallback = false;

    if (embedding && Array.isArray(embedding) && embedding.length > 0) {
      // Call existing RPC: search_businesses_v2 with HIGHER threshold
      const { data, error } = await supabase.rpc('search_businesses_v2', {
        p_query_text: query,
        p_embedding: JSON.stringify(embedding),
        p_group_id: body.group_id,
        p_threshold: SIMILARITY_THRESHOLD,  // Increased from 0.3 to 0.5
        p_limit: body.params?.limit || 10
      });

      if (error) {
        console.error('Error in search RPC:', error);
      } else {
        dataArray = data?.results || data || [];
      }

      // Filter results to ensure text relevance
      // This prevents returning unrelated high-similarity results
      if (dataArray.length > 0) {
        const filteredResults = dataArray.filter((r: SearchRpcResponse) => 
          // Keep if similarity is very high OR text matches
          (r.similarity && r.similarity >= STRICT_THRESHOLD) || 
          isTextRelevant(r, searchTerms)
        );
        
        // If filtering removed all results, keep original but sorted
        if (filteredResults.length > 0) {
          dataArray = filteredResults;
        }
      }
    }

    // If no embedding or no results, try fallback text search
    if (dataArray.length === 0) {
      console.log('Using fallback text search for:', searchTerms);
      dataArray = await fallbackTextSearch(supabase, body.group_id, searchTerms);
      usedFallback = true;
    }

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