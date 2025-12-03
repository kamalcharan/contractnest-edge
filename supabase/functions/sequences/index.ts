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

    // Create supabase client with service role key
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
    // =================================================================
    if ((resourceType === 'configs' || resourceType === null) && req.method === 'GET') {
      return await getSequenceConfigs(supabase, tenantHeader, isLive, requestId);
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

      return await getNextSequence(supabase, tenantHeader, sequenceCode, isLive, requestId);
    }

    // =================================================================
    // GET /status - Get status of all sequences with current values
    // =================================================================
    if (resourceType === 'status' && req.method === 'GET') {
      return await getSequenceStatus(supabase, tenantHeader, isLive, requestId);
    }

    // =================================================================
    // POST /configs - Create new sequence configuration
    // =================================================================
    if (resourceType === 'configs' && req.method === 'POST') {
      const data = await req.json();
      return await createSequenceConfig(supabase, tenantHeader, isLive, data, userData.user.id, requestId);
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
      return await updateSequenceConfig(supabase, tenantHeader, configId, data, userData.user.id, requestId);
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

      return await deleteSequenceConfig(supabase, tenantHeader, configId, requestId);
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

      return await resetSequence(supabase, tenantHeader, sequenceCode, isLive, data.newStartValue, requestId);
    }

    // =================================================================
    // POST /seed - Seed default sequences for tenant (onboarding)
    // Now accepts seedData from API layer for single source of truth
    // =================================================================
    if (resourceType === 'seed' && req.method === 'POST') {
      const data = await req.json().catch(() => ({}));
      const seedData = data.seedData || null;  // Seed data from API layer
      return await seedSequences(supabase, tenantHeader, userData.user.id, isLive, seedData, requestId);
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

      return await backfillSequence(supabase, tenantHeader, sequenceCode, isLive, requestId);
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
 * Now includes current_value from t_sequence_numbers table
 */
async function getSequenceConfigs(supabase: any, tenantId: string, isLive: boolean, requestId: string) {
  try {
    // First get the sequence_numbers category ID (global category, not tenant-specific)
    const { data: categoryData, error: categoryError } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('category_name', 'sequence_numbers')
      .single();

    if (categoryError || !categoryData) {
      console.log('[Sequences] No sequence_numbers category found in master');
      return new Response(
        JSON.stringify({ success: true, data: [], requestId }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Get all sequence configurations
    const { data, error } = await supabase
      .from('t_category_details')
      .select('*')
      .eq('category_id', categoryData.id)
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('is_active', true)
      .order('sequence_no', { ascending: true });

    if (error) throw error;

    // Get current values from t_sequence_numbers for all sequence types
    const { data: sequenceNumbers, error: seqError } = await supabase
      .from('t_sequence_numbers')
      .select('sequence_code, current_value, last_reset_date')
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive);

    if (seqError) {
      console.warn('[Sequences] Could not fetch current values:', seqError.message);
    }

    // Create a lookup map for current values
    const currentValueMap: Record<string, { current_value: number; last_reset_date: string | null }> = {};
    (sequenceNumbers || []).forEach((seq: any) => {
      currentValueMap[seq.sequence_code] = {
        current_value: seq.current_value || 0,
        last_reset_date: seq.last_reset_date
      };
    });

    // Transform to frontend format - use snake_case to match UI type definitions
    const transformedData = (data || []).map((item: any) => {
      const seqData = currentValueMap[item.sub_cat_name] || { current_value: 0, last_reset_date: null };

      return {
        id: item.id,
        entity_type: item.sub_cat_name,  // UI expects entity_type, not code
        code: item.sub_cat_name,         // Keep for backwards compatibility
        name: item.display_name,
        prefix: item.form_settings?.prefix || '',
        separator: item.form_settings?.separator || '',
        suffix: item.form_settings?.suffix || '',
        padding: item.form_settings?.padding_length || 4,      // UI expects padding
        start_value: item.form_settings?.start_value || 1,     // UI expects start_value
        current_value: seqData.current_value,                  // Actual current value from t_sequence_numbers
        last_reset_date: seqData.last_reset_date,              // Last reset date
        increment_by: item.form_settings?.increment_by || 1,   // UI expects increment_by
        reset_frequency: (item.form_settings?.reset_frequency || 'NEVER').toLowerCase(), // UI expects lowercase
        format_pattern: '',
        hexcolor: item.hexcolor,
        icon_name: item.icon_name,
        description: item.description,
        is_deletable: item.is_deletable,
        is_active: item.is_active,
        is_live: item.is_live,
        tenant_id: item.tenant_id,
        environment: item.is_live ? 'live' : 'test',
        created_at: item.created_at,
        updated_at: item.updated_at
      };
    });

    return new Response(
      JSON.stringify({ success: true, data: transformedData, requestId }),
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
 */
async function getNextSequence(supabase: any, tenantId: string, code: string, isLive: boolean, requestId: string) {
  try {
    // Call the PostgreSQL function
    const { data, error } = await supabase.rpc('get_next_formatted_sequence', {
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
 */
async function getSequenceStatus(supabase: any, tenantId: string, isLive: boolean, requestId: string) {
  try {
    // Call the PostgreSQL function
    const { data, error } = await supabase.rpc('get_sequence_status', {
      p_tenant_id: tenantId,
      p_is_live: isLive
    });

    if (error) throw error;

    return new Response(
      JSON.stringify({ success: true, data: data || [], requestId }),
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
    // Get sequence_numbers category ID (global category, not tenant-specific)
    const { data: categoryData, error: categoryError } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('category_name', 'sequence_numbers')
      .single();

    if (categoryError || !categoryData) {
      return new Response(
        JSON.stringify({ error: 'Sequence numbers category not found. Please seed sequences first.', requestId }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check for duplicate code
    const { data: existing } = await supabase
      .from('t_category_details')
      .select('id')
      .eq('category_id', categoryData.id)
      .eq('sub_cat_name', data.code?.toUpperCase())
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .single();

    if (existing) {
      return new Response(
        JSON.stringify({ error: `Sequence type ${data.code} already exists`, requestId }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Get next sequence_no for ordering
    const { data: maxSeq } = await supabase
      .from('t_category_details')
      .select('sequence_no')
      .eq('category_id', categoryData.id)
      .eq('tenant_id', tenantId)
      .order('sequence_no', { ascending: false })
      .limit(1)
      .single();

    const nextSeqNo = (maxSeq?.sequence_no || 0) + 1;

    // Insert new configuration
    const { data: newConfig, error: insertError } = await supabase
      .from('t_category_details')
      .insert({
        sub_cat_name: data.code?.toUpperCase(),
        display_name: data.name,
        category_id: categoryData.id,
        hexcolor: data.hexcolor || '#3B82F6',
        icon_name: data.iconName || 'Hash',
        is_active: true,
        sequence_no: nextSeqNo,
        description: data.description || '',
        tenant_id: tenantId,
        is_deletable: data.isDeletable !== false,
        form_settings: {
          prefix: data.prefix || '',
          separator: data.separator || '',
          suffix: data.suffix || '',
          padding_length: data.paddingLength || 4,
          start_value: data.startValue || 1,
          reset_frequency: data.resetFrequency || 'NEVER',
          increment_by: data.incrementBy || 1
        },
        is_live: isLive
      })
      .select()
      .single();

    if (insertError) throw insertError;

    // Transform response - use snake_case to match UI type definitions
    const result = {
      id: newConfig.id,
      entity_type: newConfig.sub_cat_name,
      code: newConfig.sub_cat_name,
      name: newConfig.display_name,
      prefix: newConfig.form_settings?.prefix || '',
      separator: newConfig.form_settings?.separator || '',
      suffix: newConfig.form_settings?.suffix || '',
      padding: newConfig.form_settings?.padding_length || 4,
      start_value: newConfig.form_settings?.start_value || 1,
      current_value: 0,
      increment_by: newConfig.form_settings?.increment_by || 1,
      reset_frequency: (newConfig.form_settings?.reset_frequency || 'NEVER').toLowerCase(),
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
    // Build update object
    const updateData: any = {};

    if (data.name !== undefined) updateData.display_name = data.name;
    if (data.hexcolor !== undefined) updateData.hexcolor = data.hexcolor;
    if (data.iconName !== undefined) updateData.icon_name = data.iconName;
    if (data.description !== undefined) updateData.description = data.description;

    // Update form_settings if any related fields are provided
    // Accept both camelCase and snake_case field names for flexibility
    const hasFormSettingUpdates =
        data.prefix !== undefined ||
        data.separator !== undefined ||
        data.suffix !== undefined ||
        data.paddingLength !== undefined ||
        data.padding !== undefined ||
        data.startValue !== undefined ||
        data.start_value !== undefined ||
        data.resetFrequency !== undefined ||
        data.reset_frequency !== undefined ||
        data.incrementBy !== undefined ||
        data.increment_by !== undefined;

    if (hasFormSettingUpdates) {
      // Get current form_settings
      const { data: current } = await supabase
        .from('t_category_details')
        .select('form_settings')
        .eq('id', configId)
        .single();

      const currentSettings = current?.form_settings || {};

      // Accept both camelCase and snake_case
      const newPadding = data.padding ?? data.paddingLength;
      const newStartValue = data.start_value ?? data.startValue;
      const newResetFrequency = data.reset_frequency ?? data.resetFrequency;
      const newIncrementBy = data.increment_by ?? data.incrementBy;

      updateData.form_settings = {
        ...currentSettings,
        ...(data.prefix !== undefined && { prefix: data.prefix }),
        ...(data.separator !== undefined && { separator: data.separator }),
        ...(data.suffix !== undefined && { suffix: data.suffix }),
        ...(newPadding !== undefined && { padding_length: newPadding }),
        ...(newStartValue !== undefined && { start_value: newStartValue }),
        ...(newResetFrequency !== undefined && { reset_frequency: newResetFrequency?.toUpperCase() }),
        ...(newIncrementBy !== undefined && { increment_by: newIncrementBy })
      };
    }

    const { data: updated, error } = await supabase
      .from('t_category_details')
      .update(updateData)
      .eq('id', configId)
      .eq('tenant_id', tenantId)
      .select()
      .single();

    if (error) throw error;

    // Transform response - use snake_case to match UI type definitions
    const result = {
      id: updated.id,
      entity_type: updated.sub_cat_name,
      code: updated.sub_cat_name,
      name: updated.display_name,
      prefix: updated.form_settings?.prefix || '',
      separator: updated.form_settings?.separator || '',
      suffix: updated.form_settings?.suffix || '',
      padding: updated.form_settings?.padding_length || 4,
      start_value: updated.form_settings?.start_value || 1,
      current_value: 0,
      increment_by: updated.form_settings?.increment_by || 1,
      reset_frequency: (updated.form_settings?.reset_frequency || 'NEVER').toLowerCase(),
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
 */
async function deleteSequenceConfig(supabase: any, tenantId: string, configId: string, requestId: string) {
  try {
    // Check if deletable
    const { data: config } = await supabase
      .from('t_category_details')
      .select('is_deletable, sub_cat_name')
      .eq('id', configId)
      .eq('tenant_id', tenantId)
      .single();

    if (!config) {
      return new Response(
        JSON.stringify({ error: 'Configuration not found', requestId }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (config.is_deletable === false) {
      return new Response(
        JSON.stringify({ error: `System sequence ${config.sub_cat_name} cannot be deleted`, requestId }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Soft delete
    const { error } = await supabase
      .from('t_category_details')
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
 * Now accepts seedData from API layer for single source of truth
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
    // If seedData is provided from API layer, use it
    // Otherwise fall back to RPC function (legacy support)
    if (seedData && Array.isArray(seedData) && seedData.length > 0) {
      console.log('[Sequences] Using seed data from API layer:', seedData.length, 'items');

      // Get or create the sequence_numbers category
      const { data: categoryData, error: catError } = await supabase
        .from('t_category_master')
        .select('id')
        .eq('category_name', 'sequence_numbers')
        .single();

      if (catError) throw new Error('sequence_numbers category not found in master');

      const categoryId = categoryData.id;
      const seeded: string[] = [];
      const skipped: string[] = [];

      for (const item of seedData) {
        // Check if already exists for this environment
        const { data: existing } = await supabase
          .from('t_category_details')
          .select('id')
          .eq('category_id', categoryId)
          .eq('tenant_id', tenantId)
          .eq('sub_cat_name', item.code)
          .eq('is_live', isLive)
          .single();

        if (existing) {
          console.log(`[Sequences] Skipping ${item.code} - already exists for ${isLive ? 'Live' : 'Test'}`);
          skipped.push(item.code);
          continue;
        }

        // Insert new sequence config
        const { error: insertError } = await supabase
          .from('t_category_details')
          .insert({
            tenant_id: tenantId,
            category_id: categoryId,
            sub_cat_name: item.code,
            display_name: item.name,
            description: item.description,
            hexcolor: item.hexcolor,
            icon_name: item.icon_name,
            sequence_no: item.sequence_order,
            is_active: true,
            is_deletable: item.is_deletable,
            is_live: isLive,
            form_settings: {
              prefix: item.prefix,
              separator: item.separator,
              suffix: item.suffix || '',
              padding_length: item.padding_length,
              start_value: item.start_value,
              increment_by: item.increment_by,
              reset_frequency: item.reset_frequency
            }
          });

        if (insertError) {
          console.error(`[Sequences] Error inserting ${item.code}:`, insertError);
          throw insertError;
        }

        seeded.push(item.code);
      }

      return new Response(
        JSON.stringify({
          success: true,
          seeded_count: seeded.length,
          skipped_count: skipped.length,
          sequences: seeded,
          skipped: skipped,
          requestId
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Legacy: Fall back to RPC function if no seedData provided
    console.log('[Sequences] Using legacy RPC function for seeding');
    const { data, error } = await supabase.rpc('seed_sequence_numbers_for_tenant', {
      p_tenant_id: tenantId,
      p_created_by: userId
    });

    if (error) throw error;

    return new Response(
      JSON.stringify({ success: true, data, requestId }),
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
