// supabase/functions/sequences/index.ts
// Sequence Numbers Edge Function - CRUD operations for sequence configuration
// Uses the Category (ProductMasterdata) system for dynamic sequence types

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-environment',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const requestId = crypto.randomUUID();

    // Get auth header and extract token
    const authHeader = req.headers.get('Authorization');
    const token = authHeader?.replace('Bearer ', '');
    const tenantHeader = req.headers.get('x-tenant-id');
    const environmentHeader = req.headers.get('x-environment') || 'live';
    const isLive = environmentHeader === 'live';

    console.log(`[Sequences] ${req.method} ${req.url}`, {
      hasAuth: !!authHeader,
      tenantId: tenantHeader,
      environment: environmentHeader,
      requestId
    });

    if (!authHeader || !token) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required', requestId }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!tenantHeader) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required', requestId }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Create supabase client with service role key (for user validation)
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: {
          Authorization: authHeader,
          'x-tenant-id': tenantHeader
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Create admin client WITHOUT user auth header - bypasses RLS for admin operations
    const adminSupabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Validate user token
    const { data: userData, error: userError } = await supabase.auth.getUser(token);

    if (userError || !userData?.user) {
      console.error('[Sequences] User validation error:', userError?.message || 'User not found');
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token', requestId }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Parse URL to get path segments and query parameters
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const resourceType = pathSegments.length > 1 ? pathSegments[1] : null;

    console.log('[Sequences] Request routing:', {
      pathSegments,
      resourceType,
      method: req.method,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });

    // =================================================================
    // HEALTH CHECK ENDPOINT
    // =================================================================
    if (resourceType === 'health') {
      return new Response(
        JSON.stringify({
          status: 'ok',
          service: 'sequences-edge',
          timestamp: new Date().toISOString(),
          requestId
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // =================================================================
    // GET /configs - List all sequence configurations
    // All DB operations use adminSupabase to bypass RLS (tenant isolation handled by tenantHeader)
    // =================================================================
    if ((resourceType === 'configs' || resourceType === null) && req.method === 'GET') {
      return await getSequenceConfigs(adminSupabase, tenantHeader, isLive, requestId);
    }

    // =================================================================
    // GET /next/:code - Get next formatted sequence number
    // =================================================================
    if (resourceType === 'next' && req.method === 'GET') {
      const sequenceCode = pathSegments.length > 2 ? pathSegments[2] : url.searchParams.get('code');

      if (!sequenceCode) {
        return new Response(
          JSON.stringify({ error: 'Sequence code is required', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return await getNextSequence(adminSupabase, tenantHeader, sequenceCode, isLive, requestId);
    }

    // =================================================================
    // GET /status - Get status of all sequences with current values
    // =================================================================
    if (resourceType === 'status' && req.method === 'GET') {
      return await getSequenceStatus(adminSupabase, tenantHeader, isLive, requestId);
    }

    // =================================================================
    // POST /configs - Create new sequence configuration
    // =================================================================
    if (resourceType === 'configs' && req.method === 'POST') {
      const data = await req.json();
      return await createSequenceConfig(adminSupabase, tenantHeader, isLive, data, userData.user.id, requestId);
    }

    // =================================================================
    // PATCH /configs/:id - Update sequence configuration
    // =================================================================
    if (resourceType === 'configs' && req.method === 'PATCH') {
      const configId = pathSegments.length > 2 ? pathSegments[2] : url.searchParams.get('id');

      if (!configId) {
        return new Response(
          JSON.stringify({ error: 'Config ID is required', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const data = await req.json();
      return await updateSequenceConfig(adminSupabase, tenantHeader, configId, data, userData.user.id, requestId);
    }

    // =================================================================
    // DELETE /configs/:id - Delete sequence configuration
    // =================================================================
    if (resourceType === 'configs' && req.method === 'DELETE') {
      const configId = pathSegments.length > 2 ? pathSegments[2] : url.searchParams.get('id');

      if (!configId) {
        return new Response(
          JSON.stringify({ error: 'Config ID is required', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return await deleteSequenceConfig(adminSupabase, tenantHeader, configId, requestId);
    }

    // =================================================================
    // POST /reset/:code - Manual reset sequence
    // =================================================================
    if (resourceType === 'reset' && req.method === 'POST') {
      const sequenceCode = pathSegments.length > 2 ? pathSegments[2] : null;
      const data = await req.json().catch(() => ({}));

      if (!sequenceCode) {
        return new Response(
          JSON.stringify({ error: 'Sequence code is required', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return await resetSequence(adminSupabase, tenantHeader, sequenceCode, isLive, data.newStartValue, requestId);
    }

    // =================================================================
    // POST /seed - Seed default sequences for tenant (onboarding)
    // Now accepts seedData from API layer for single source of truth
    // =================================================================
    if (resourceType === 'seed' && req.method === 'POST') {
      const data = await req.json().catch(() => ({}));
      const seedData = data.seedData || null;  // Seed data from API layer
      return await seedSequences(adminSupabase, tenantHeader, userData.user.id, isLive, seedData, requestId);
    }

    // =================================================================
    // POST /backfill/:code - Backfill existing records with sequence numbers
    // =================================================================
    if (resourceType === 'backfill' && req.method === 'POST') {
      const sequenceCode = pathSegments.length > 2 ? pathSegments[2] : null;

      if (!sequenceCode) {
        return new Response(
          JSON.stringify({ error: 'Sequence code is required (e.g., CONTACT)', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return await backfillSequence(adminSupabase, tenantHeader, sequenceCode, isLive, requestId);
    }

    return new Response(
      JSON.stringify({
        error: 'Invalid endpoint or method',
        availableEndpoints: [
          'GET  /health              - Service health check',
          'GET  /configs             - List sequence configurations',
          'GET  /status              - Get sequence status with current values',
          'GET  /next/:code          - Get next formatted sequence number',
          'POST /configs             - Create sequence configuration',
          'PATCH /configs/:id        - Update sequence configuration',
          'DELETE /configs/:id       - Delete sequence configuration',
          'POST /reset/:code         - Reset sequence to start value',
          'POST /seed                - Seed default sequences for tenant',
          'POST /backfill/:code      - Backfill existing records'
        ],
        requestId
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// =================================================================
// HANDLER FUNCTIONS
// =================================================================

/**
 * Get all sequence configurations for tenant
 * NEW ARCHITECTURE: Queries directly from t_sequence_counters (single source of truth)
 */
async function getSequenceConfigs(supabase: any, tenantId: string, isLive: boolean, requestId: string) {
  try {
    console.log(`[Sequences] Getting configs for tenant ${tenantId}, environment: ${isLive ? 'LIVE' : 'TEST'}`);

    // Query directly from t_sequence_counters (contains both config AND current values)
    const { data, error } = await supabase
      .from('t_sequence_counters')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('is_active', true)
      .order('sequence_code', { ascending: true });

    if (error) throw error;

    if (!data || data.length === 0) {
      console.log('[Sequences] No sequence configurations found for this tenant/environment');
      return new Response(
        JSON.stringify({ success: true, data: [], count: 0, requestId }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Transform to frontend format - use snake_case to match UI type definitions
    const transformedData = data.map((item: any) => ({
      id: item.id,
      entity_type: item.sequence_code,  // UI expects entity_type
      code: item.sequence_code,         // Keep for backwards compatibility
      name: item.display_name,
      prefix: item.prefix || '',
      separator: item.separator || '-',
      suffix: item.suffix || '',
      padding: item.padding_length || 4,      // UI expects padding
      start_value: item.start_value || 1,
      current_value: item.current_value || 0,
      last_reset_date: item.last_reset_date,
      increment_by: item.increment_by || 1,
      reset_frequency: (item.reset_frequency || 'NEVER').toLowerCase(),
      format_pattern: '',
      hexcolor: item.hexcolor,
      icon_name: item.icon_name,
      description: item.description,
      is_deletable: true,  // Tenant can customize their sequences
      is_active: item.is_active,
      is_live: item.is_live,
      tenant_id: item.tenant_id,
      environment: item.is_live ? 'live' : 'test',
      created_at: item.created_at,
      updated_at: item.updated_at
    }));

    return new Response(
      JSON.stringify({ success: true, data: transformedData, count: transformedData.length, requestId }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error getting configs:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Get next formatted sequence number (atomic increment)
 * NEW ARCHITECTURE: Uses get_next_formatted_sequence_v2 RPC which queries t_sequence_counters
 */
async function getNextSequence(supabase: any, tenantId: string, code: string, isLive: boolean, requestId: string) {
  try {
    // Call the new v2 PostgreSQL function that uses t_sequence_counters
    const { data, error } = await supabase.rpc('get_next_formatted_sequence_v2', {
      p_sequence_code: code.toUpperCase(),
      p_tenant_id: tenantId,
      p_is_live: isLive
    });

    if (error) {
      console.error('[Sequences] Error getting next sequence:', error);
      throw error;
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: data,
        formatted: data?.formatted,
        raw_value: data?.raw_value,
        requestId
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error in getNextSequence:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to get next sequence', requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Get sequence status with current values
 * NEW ARCHITECTURE: Queries directly from t_sequence_counters
 */
async function getSequenceStatus(supabase: any, tenantId: string, isLive: boolean, requestId: string) {
  try {
    // Query directly from t_sequence_counters
    const { data, error } = await supabase
      .from('t_sequence_counters')
      .select('sequence_code, current_value, start_value, prefix, separator, suffix, padding_length, last_reset_date')
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('is_active', true);

    if (error) throw error;

    // Transform to expected format with next_formatted
    const statusData = (data || []).map((item: any) => {
      const nextValue = item.current_value === 0
        ? (item.start_value || 1)
        : item.current_value + 1;

      const formatted = (item.prefix || '') +
        (item.separator || '') +
        String(nextValue).padStart(item.padding_length || 4, '0') +
        (item.suffix || '');

      return {
        entity_type: item.sequence_code,
        current_value: item.current_value,
        next_value: nextValue,
        next_formatted: formatted,
        last_reset_date: item.last_reset_date
      };
    });

    return new Response(
      JSON.stringify({ success: true, data: statusData, count: statusData.length, requestId }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error getting status:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Create new sequence configuration
 * NEW ARCHITECTURE: Inserts into t_sequence_counters
 */
async function createSequenceConfig(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  data: any,
  userId: string,
  requestId: string
) {
  try {
    const sequenceCode = data.code?.toUpperCase();

    // Check for duplicate code in t_sequence_counters
    const { data: existing } = await supabase
      .from('t_sequence_counters')
      .select('id')
      .eq('sequence_code', sequenceCode)
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .single();

    if (existing) {
      return new Response(
        JSON.stringify({ error: `Sequence type ${data.code} already exists`, requestId }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Insert new configuration into t_sequence_counters
    const { data: newConfig, error: insertError } = await supabase
      .from('t_sequence_counters')
      .insert({
        sequence_code: sequenceCode,
        tenant_id: tenantId,
        is_live: isLive,
        current_value: 0,
        prefix: data.prefix || '',
        separator: data.separator || '-',
        suffix: data.suffix || '',
        padding_length: data.paddingLength || data.padding || 4,
        start_value: data.startValue || data.start_value || 1,
        increment_by: data.incrementBy || data.increment_by || 1,
        reset_frequency: data.resetFrequency || data.reset_frequency || 'NEVER',
        display_name: data.name,
        description: data.description || '',
        hexcolor: data.hexcolor || '#3B82F6',
        icon_name: data.iconName || data.icon_name || 'Hash',
        is_active: true,
        created_by: userId,
        updated_by: userId
      })
      .select()
      .single();

    if (insertError) throw insertError;

    // Transform response - use snake_case to match UI type definitions
    const result = {
      id: newConfig.id,
      entity_type: newConfig.sequence_code,
      code: newConfig.sequence_code,
      name: newConfig.display_name,
      prefix: newConfig.prefix || '',
      separator: newConfig.separator || '-',
      suffix: newConfig.suffix || '',
      padding: newConfig.padding_length || 4,
      start_value: newConfig.start_value || 1,
      current_value: newConfig.current_value || 0,
      increment_by: newConfig.increment_by || 1,
      reset_frequency: (newConfig.reset_frequency || 'NEVER').toLowerCase(),
      format_pattern: '',
      is_active: newConfig.is_active,
      is_live: newConfig.is_live,
      environment: newConfig.is_live ? 'live' : 'test',
      tenant_id: newConfig.tenant_id
    };

    return new Response(
      JSON.stringify({ success: true, data: result, requestId }),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error creating config:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Update sequence configuration
 * NEW ARCHITECTURE: Updates t_sequence_counters directly
 */
async function updateSequenceConfig(
  supabase: any,
  tenantId: string,
  configId: string,
  data: any,
  userId: string,
  requestId: string
) {
  try {
    // Build update object - all fields stored directly in t_sequence_counters
    const updateData: any = {
      updated_by: userId,
      updated_at: new Date().toISOString()
    };

    // Accept both camelCase and snake_case field names for flexibility
    if (data.name !== undefined) updateData.display_name = data.name;
    if (data.hexcolor !== undefined) updateData.hexcolor = data.hexcolor;
    if (data.iconName !== undefined || data.icon_name !== undefined) {
      updateData.icon_name = data.iconName || data.icon_name;
    }
    if (data.description !== undefined) updateData.description = data.description;
    if (data.prefix !== undefined) updateData.prefix = data.prefix;
    if (data.separator !== undefined) updateData.separator = data.separator;
    if (data.suffix !== undefined) updateData.suffix = data.suffix;
    if (data.padding !== undefined || data.paddingLength !== undefined) {
      updateData.padding_length = data.padding ?? data.paddingLength;
    }
    if (data.start_value !== undefined || data.startValue !== undefined) {
      updateData.start_value = data.start_value ?? data.startValue;
    }
    if (data.reset_frequency !== undefined || data.resetFrequency !== undefined) {
      updateData.reset_frequency = (data.reset_frequency ?? data.resetFrequency)?.toUpperCase();
    }
    if (data.increment_by !== undefined || data.incrementBy !== undefined) {
      updateData.increment_by = data.increment_by ?? data.incrementBy;
    }

    const { data: updated, error } = await supabase
      .from('t_sequence_counters')
      .update(updateData)
      .eq('id', configId)
      .eq('tenant_id', tenantId)
      .select()
      .single();

    if (error) throw error;

    // Transform response - use snake_case to match UI type definitions
    const result = {
      id: updated.id,
      entity_type: updated.sequence_code,
      code: updated.sequence_code,
      name: updated.display_name,
      prefix: updated.prefix || '',
      separator: updated.separator || '-',
      suffix: updated.suffix || '',
      padding: updated.padding_length || 4,
      start_value: updated.start_value || 1,
      current_value: updated.current_value || 0,
      increment_by: updated.increment_by || 1,
      reset_frequency: (updated.reset_frequency || 'NEVER').toLowerCase(),
      format_pattern: '',
      is_active: updated.is_active,
      is_live: updated.is_live,
      environment: updated.is_live ? 'live' : 'test',
      tenant_id: updated.tenant_id
    };

    return new Response(
      JSON.stringify({ success: true, data: result, requestId }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error updating config:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Soft delete sequence configuration
 * NEW ARCHITECTURE: Updates t_sequence_counters
 */
async function deleteSequenceConfig(supabase: any, tenantId: string, configId: string, requestId: string) {
  try {
    // Get the config to check sequence_code
    const { data: config } = await supabase
      .from('t_sequence_counters')
      .select('sequence_code')
      .eq('id', configId)
      .eq('tenant_id', tenantId)
      .single();

    if (!config) {
      return new Response(
        JSON.stringify({ error: 'Configuration not found', requestId }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Core sequences cannot be deleted (CONTACT, CONTRACT, INVOICE, QUOTATION, RECEIPT)
    const coreSequences = ['CONTACT', 'CONTRACT', 'INVOICE', 'QUOTATION', 'RECEIPT'];
    if (coreSequences.includes(config.sequence_code)) {
      return new Response(
        JSON.stringify({ error: `Core sequence ${config.sequence_code} cannot be deleted`, requestId }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Soft delete
    const { error } = await supabase
      .from('t_sequence_counters')
      .update({ is_active: false })
      .eq('id', configId)
      .eq('tenant_id', tenantId);

    if (error) throw error;

    return new Response(
      JSON.stringify({ success: true, message: 'Configuration deleted', requestId }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error deleting config:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Manual reset sequence to start value
 */
async function resetSequence(
  supabase: any,
  tenantId: string,
  code: string,
  isLive: boolean,
  newStartValue: number | null,
  requestId: string
) {
  try {
    const { data, error } = await supabase.rpc('manual_reset_sequence', {
      p_sequence_code: code.toUpperCase(),
      p_tenant_id: tenantId,
      p_is_live: isLive,
      p_new_start_value: newStartValue
    });

    if (error) throw error;

    return new Response(
      JSON.stringify({ success: true, data, requestId }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error resetting sequence:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Seed default sequences for tenant (onboarding)
 * NEW ARCHITECTURE: Inserts into t_sequence_counters (tenant-specific)
 * Uses seedData from API layer as the single source of truth
 */
async function seedSequences(
  supabase: any,
  tenantId: string,
  userId: string,
  isLive: boolean,
  seedData: any[] | null,
  requestId: string
) {
  try {
    console.log(`[Sequences] Seeding for tenant ${tenantId}, environment: ${isLive ? 'LIVE' : 'TEST'}`);

    // If seedData is provided from API layer, use it
    if (seedData && Array.isArray(seedData) && seedData.length > 0) {
      console.log('[Sequences] Using seed data from API layer:', seedData.length, 'items');

      const seeded: string[] = [];
      const skipped: string[] = [];

      for (const item of seedData) {
        // Check if already exists in t_sequence_counters for this tenant/environment
        const { data: existing } = await supabase
          .from('t_sequence_counters')
          .select('id')
          .eq('sequence_code', item.code)
          .eq('tenant_id', tenantId)
          .eq('is_live', isLive)
          .single();

        if (existing) {
          console.log(`[Sequences] Skipping ${item.code} - already exists for ${isLive ? 'Live' : 'Test'}`);
          skipped.push(item.code);
          continue;
        }

        // Insert into t_sequence_counters (tenant-specific table)
        const { error: insertError } = await supabase
          .from('t_sequence_counters')
          .insert({
            sequence_code: item.code,
            tenant_id: tenantId,
            is_live: isLive,
            current_value: 0,  // Start at 0, first use will be start_value
            // Tenant-specific settings (copied from seed data)
            prefix: item.prefix || '',
            separator: item.separator || '-',
            suffix: item.suffix || '',
            padding_length: item.padding_length || 4,
            start_value: item.start_value || 1,
            increment_by: item.increment_by || 1,
            reset_frequency: item.reset_frequency || 'NEVER',
            // Display metadata
            display_name: item.name,
            description: item.description,
            hexcolor: item.hexcolor,
            icon_name: item.icon_name,
            is_active: true,
            // Audit
            created_by: userId,
            updated_by: userId
          });

        if (insertError) {
          console.error(`[Sequences] Error inserting ${item.code}:`, insertError);
          throw insertError;
        }

        seeded.push(item.code);
        console.log(`[Sequences] Seeded ${item.code} for ${isLive ? 'Live' : 'Test'}`);
      }

      return new Response(
        JSON.stringify({
          success: true,
          seeded_count: seeded.length,
          skipped_count: skipped.length,
          sequences: seeded,
          skipped: skipped,
          environment: isLive ? 'live' : 'test',
          requestId
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Fallback: Get templates from global t_category_details and seed
    console.log('[Sequences] No seedData provided, using global templates from t_category_details');

    // Global sequence_numbers category ID (from migration 006)
    const GLOBAL_CATEGORY_ID = 'a0000000-0000-0000-0000-000000000001';

    const { data: globalTemplates, error: templateError } = await supabase
      .from('t_category_details')
      .select('*')
      .eq('category_id', GLOBAL_CATEGORY_ID)
      .eq('is_active', true)
      .order('sequence_no', { ascending: true });

    if (templateError) {
      console.error('[Sequences] Error fetching global templates:', templateError);
      throw new Error('Failed to fetch global sequence templates');
    }

    if (!globalTemplates || globalTemplates.length === 0) {
      throw new Error('No global sequence templates found. Run migration 006 first.');
    }

    const seeded: string[] = [];
    const skipped: string[] = [];

    for (const template of globalTemplates) {
      // Check if already exists
      const { data: existing } = await supabase
        .from('t_sequence_counters')
        .select('id')
        .eq('sequence_code', template.sub_cat_name)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .single();

      if (existing) {
        skipped.push(template.sub_cat_name);
        continue;
      }

      // Extract settings from form_settings
      const settings = template.form_settings || {};

      // Insert into t_sequence_counters
      const { error: insertError } = await supabase
        .from('t_sequence_counters')
        .insert({
          sequence_code: template.sub_cat_name,
          tenant_id: tenantId,
          is_live: isLive,
          current_value: 0,
          prefix: settings.prefix || '',
          separator: settings.separator || '-',
          suffix: settings.suffix || '',
          padding_length: settings.padding_length || 4,
          start_value: settings.start_value || 1,
          increment_by: settings.increment_by || 1,
          reset_frequency: settings.reset_frequency || 'NEVER',
          display_name: template.display_name,
          description: template.description,
          hexcolor: template.hexcolor,
          icon_name: template.icon_name,
          is_active: true,
          created_by: userId,
          updated_by: userId
        });

      if (insertError) {
        console.error(`[Sequences] Error inserting ${template.sub_cat_name}:`, insertError);
        throw insertError;
      }

      seeded.push(template.sub_cat_name);
    }

    return new Response(
      JSON.stringify({
        success: true,
        seeded_count: seeded.length,
        skipped_count: skipped.length,
        sequences: seeded,
        skipped: skipped,
        environment: isLive ? 'live' : 'test',
        requestId
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error seeding sequences:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Backfill existing records with sequence numbers
 */
async function backfillSequence(
  supabase: any,
  tenantId: string,
  code: string,
  isLive: boolean,
  requestId: string
) {
  try {
    // Currently only supports CONTACT
    if (code.toUpperCase() === 'CONTACT') {
      const { data, error } = await supabase.rpc('backfill_contact_numbers', {
        p_tenant_id: tenantId,
        p_is_live: isLive
      });

      if (error) throw error;

      return new Response(
        JSON.stringify({ success: true, data, requestId }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ error: `Backfill not supported for ${code}`, requestId }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[Sequences] Error backfilling:', error);
    return new Response(
      JSON.stringify({ error: error.message, requestId }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}
