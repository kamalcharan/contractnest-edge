// supabase/functions/jtd-tenant-settings/index.ts
// Tenant-facing JTD message-type settings: per (tenant, source_type_code)
// on/off toggle + read-only template preview. Lives in n_jtd_tenant_source_config
// (previously dead schema — nothing read/wrote it until this function).
//
// A fixed set of identity/access message types (GLOBAL_SOURCE_TYPES, kept in
// sync with jtd-worker/index.ts's GATE_EXEMPT_SOURCE_TYPES) are never
// toggleable here and are always returned as enabled — blocking them isn't
// "saving spend," it breaks login/signup/contract-signing outright.
//
// Auth follows the same tenant-route pattern as the `integrations` function:
// Authorization header presence + client-supplied x-tenant-id, no deeper
// per-request tenant-membership check at this layer (consistent with every
// other tenant-facing edge function in this codebase, not something this
// change introduces).

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, PATCH, OPTIONS'
};

// Keep this in sync with jtd-worker/index.ts's GATE_EXEMPT_SOURCE_TYPES.
const GLOBAL_SOURCE_TYPES = new Set(['user_invite', 'user_created', 'contract_signoff']);

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    if (!supabaseUrl || !supabaseKey) {
      console.error('Missing environment variables');
      return jsonResponse({ error: 'Server configuration error' }, 500);
    }

    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');

    if (!authHeader) {
      return jsonResponse({ error: 'Authorization header is required' }, 401);
    }
    if (!tenantId) {
      return jsonResponse({ error: 'x-tenant-id header is required' }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { Authorization: authHeader } }
    });

    const url = new URL(req.url);
    const isLive = url.searchParams.get('isLive') !== 'false'; // default true

    // ========================================================================
    // GET /message-types — list all active source types with per-tenant
    // enabled state + a read-only template preview per channel
    // ========================================================================
    if (req.method === 'GET' && url.pathname.endsWith('/message-types')) {
      const { data: sourceTypes, error: stError } = await supabase
        .from('n_jtd_source_types')
        .select('code, name, description, default_channels')
        .eq('is_active', true)
        .order('code');

      if (stError) {
        console.error('Error fetching source types:', stError);
        return jsonResponse({ error: 'Failed to fetch message types' }, 500);
      }

      const { data: tenantConfigRows, error: tcError } = await supabase
        .from('n_jtd_tenant_source_config')
        .select('source_type_code, is_enabled')
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive);

      if (tcError) {
        console.error('Error fetching tenant source config:', tcError);
        return jsonResponse({ error: 'Failed to fetch tenant settings' }, 500);
      }

      const enabledByCode = new Map<string, boolean>();
      (tenantConfigRows || []).forEach((row: any) => {
        enabledByCode.set(row.source_type_code, row.is_enabled !== false);
      });

      // Templates: tenant-specific first, fall back to a system (tenant_id
      // IS NULL) template if one exists — same resolution order jtd-worker
      // uses at send time, so the preview matches what will actually go out.
      const codes = (sourceTypes || []).map((s: any) => s.code);
      const { data: templateRows, error: tplError } = codes.length
        ? await supabase
            .from('n_jtd_templates')
            .select('source_type_code, channel_code, tenant_id, subject, content')
            .in('source_type_code', codes)
            .eq('is_active', true)
            .or(`tenant_id.eq.${tenantId},tenant_id.is.null`)
        : { data: [], error: null };

      if (tplError) {
        console.error('Error fetching templates:', tplError);
        return jsonResponse({ error: 'Failed to fetch templates' }, 500);
      }

      // Prefer the tenant-specific row over the system fallback per (code, channel).
      const templatesByCode = new Map<string, Map<string, any>>();
      (templateRows || []).forEach((row: any) => {
        if (!templatesByCode.has(row.source_type_code)) {
          templatesByCode.set(row.source_type_code, new Map());
        }
        const byChannel = templatesByCode.get(row.source_type_code)!;
        const existing = byChannel.get(row.channel_code);
        if (!existing || (existing.tenant_id === null && row.tenant_id !== null)) {
          byChannel.set(row.channel_code, row);
        }
      });

      const result = (sourceTypes || []).map((st: any) => {
        const isGlobal = GLOBAL_SOURCE_TYPES.has(st.code);
        const byChannel = templatesByCode.get(st.code);
        const templates = byChannel
          ? Array.from(byChannel.values()).map((t: any) => ({
              channel_code: t.channel_code,
              subject: t.subject,
              content: t.content
            }))
          : [];

        return {
          source_type_code: st.code,
          name: st.name,
          description: st.description,
          is_global: isGlobal,
          is_enabled: isGlobal ? true : (enabledByCode.get(st.code) ?? true),
          templates
        };
      });

      return jsonResponse({ success: true, data: result });
    }

    // ========================================================================
    // PATCH /message-types/:code — toggle is_enabled for (tenant, code)
    // ========================================================================
    if (req.method === 'PATCH' && url.pathname.includes('/message-types/')) {
      const pathParts = url.pathname.split('/');
      const sourceTypeCode = decodeURIComponent(pathParts[pathParts.length - 1]);

      if (!sourceTypeCode) {
        return jsonResponse({ error: 'source_type_code is required' }, 400);
      }
      if (GLOBAL_SOURCE_TYPES.has(sourceTypeCode)) {
        return jsonResponse({ error: 'This message type is required for account access and cannot be restricted' }, 400);
      }

      const body = await req.json();
      if (body.is_enabled === undefined) {
        return jsonResponse({ error: 'is_enabled is required' }, 400);
      }

      const { data: exists } = await supabase
        .from('n_jtd_source_types')
        .select('code')
        .eq('code', sourceTypeCode)
        .eq('is_active', true)
        .maybeSingle();

      if (!exists) {
        return jsonResponse({ error: 'Unknown message type' }, 404);
      }

      // Applies to both TEST and LIVE rows for this tenant, same as the
      // channel-level toggle on /settings/integrations — the tenant isn't
      // shown a separate test/live switch for this, so keep both in sync.
      for (const liveFlag of [true, false]) {
        const { error: upsertError } = await supabase
          .from('n_jtd_tenant_source_config')
          .upsert(
            {
              tenant_id: tenantId,
              source_type_code: sourceTypeCode,
              is_live: liveFlag,
              is_enabled: body.is_enabled,
              updated_at: new Date().toISOString()
            },
            { onConflict: 'tenant_id,source_type_code,is_live' }
          );

        if (upsertError) {
          console.error('Error upserting tenant source config:', upsertError);
          return jsonResponse({ error: 'Failed to update message type setting' }, 500);
        }
      }

      return jsonResponse({ success: true, data: { source_type_code: sourceTypeCode, is_enabled: body.is_enabled } });
    }

    return jsonResponse({ error: 'Invalid endpoint or method', method: req.method, path: url.pathname }, 404);
  } catch (error) {
    console.error('jtd-tenant-settings error:', error);
    return jsonResponse({ error: error instanceof Error ? error.message : 'Unknown error' }, 500);
  }
});
