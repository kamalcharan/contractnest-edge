// supabase/functions/group-discovery/handlers/segments.ts

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import type { 
  GroupDiscoveryResponse, 
  SegmentResult,
  SegmentRpcResponse 
} from "../types.ts";

// ============================================================================
// LIST SEGMENTS HANDLER
// ============================================================================
export async function handleListSegments(
  supabase: SupabaseClient,
  groupId: string
): Promise<Partial<GroupDiscoveryResponse>> {
  
  try {
    // Call existing RPC: get_segments_by_scope
    const { data, error } = await supabase.rpc('get_segments_by_scope', {
      p_scope: 'group',
      p_group_id: groupId
    });

    if (error) {
      console.error('Error fetching segments:', error);
      return {
        success: false,
        intent: 'list_segments',
        response_type: 'error',
        detail_level: 'none',
        message: 'Unable to load segments. Please try again.',
        results: [],
        results_count: 0,
        from_cache: false
      };
    }

    // Handle empty results
    if (!data || data.length === 0) {
      return {
        success: true,
        intent: 'list_segments',
        response_type: 'segments_list',
        detail_level: 'list',
        message: 'No industry segments found.',
        results: [],
        results_count: 0,
        from_cache: false
      };
    }

    // Format segments
    const segments: SegmentResult[] = (data as SegmentRpcResponse[])
      .filter(s => s && s.segment_name)
      .map(s => ({
        segment_name: s.segment_name || 'Unknown',
        industry_id: s.industry_id || '',
        member_count: Number(s.member_count) || 0
      }));

    // Build message
    const message = 'Here are the available industries:\n\n' +
      segments.map(s => `• **${s.segment_name}**: ${s.member_count} member${s.member_count !== 1 ? 's' : ''}`).join('\n') +
      '\n\nSelect an industry to see members.';

    return {
      success: true,
      intent: 'list_segments',
      response_type: 'segments_list',
      detail_level: 'list',
      message,
      results: segments,
      results_count: segments.length,
      from_cache: false
    };

  } catch (error) {
    console.error('Exception in handleListSegments:', error);
    return {
      success: false,
      intent: 'list_segments',
      response_type: 'error',
      detail_level: 'none',
      message: 'An error occurred while fetching segments.',
      results: [],
      results_count: 0,
      from_cache: false
    };
  }
}