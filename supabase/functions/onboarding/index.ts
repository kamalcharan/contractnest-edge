// supabase/functions/onboarding/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { createHash } from "https://deno.land/std@0.168.0/crypto/mod.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-internal-signature, x-idempotency-key, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

// Rate limiting store (in-memory for now, consider Redis for production)
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

// Idempotency store
const idempotencyStore = new Map<string, { response: any; expiry: number }>();

// Constants
const RATE_LIMIT_WINDOW = 60000; // 1 minute
const RATE_LIMIT_MAX_REQUESTS = 30; // 30 requests per minute
const IDEMPOTENCY_EXPIRY = 3600000; // 1 hour

/**
 * Verify internal signature
 */
const verifyInternalSignature = async (
  payload: string,
  signature: string,
  secret: string
): Promise<boolean> => {
  const encoder = new TextEncoder();
  const data = encoder.encode(payload);
  const key = encoder.encode(secret);
  
  const hmac = await crypto.subtle.importKey(
    'raw',
    key,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signatureBuffer = await crypto.subtle.sign('HMAC', hmac, data);
  const computedSignature = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));
  
  return computedSignature === signature;
};

/**
 * Rate limiting middleware
 */
const checkRateLimit = (clientIp: string): { allowed: boolean; remaining: number } => {
  const now = Date.now();
  const clientData = rateLimitStore.get(clientIp);
  
  if (!clientData || clientData.resetTime < now) {
    rateLimitStore.set(clientIp, {
      count: 1,
      resetTime: now + RATE_LIMIT_WINDOW
    });
    return { allowed: true, remaining: RATE_LIMIT_MAX_REQUESTS - 1 };
  }
  
  if (clientData.count >= RATE_LIMIT_MAX_REQUESTS) {
    return { allowed: false, remaining: 0 };
  }
  
  clientData.count++;
  return { allowed: true, remaining: RATE_LIMIT_MAX_REQUESTS - clientData.count };
};

/**
 * Clean expired entries from stores
 */
const cleanupStores = () => {
  const now = Date.now();
  
  // Cleanup rate limit store
  for (const [key, value] of rateLimitStore.entries()) {
    if (value.resetTime < now) {
      rateLimitStore.delete(key);
    }
  }
  
  // Cleanup idempotency store
  for (const [key, value] of idempotencyStore.entries()) {
    if (value.expiry < now) {
      idempotencyStore.delete(key);
    }
  }
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET') ?? '';
    
    // Verify internal signature for all non-GET requests
    if (req.method !== 'GET') {
      const signature = req.headers.get('x-internal-signature');
      if (!signature) {
        return new Response(
          JSON.stringify({ error: 'Missing internal signature' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      const payload = await req.clone().text();
      const isValid = await verifyInternalSignature(payload, signature, internalSecret);
      
      if (!isValid) {
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Get client IP for rate limiting
    const clientIp = req.headers.get('x-forwarded-for') || 
                     req.headers.get('x-real-ip') || 
                     'unknown';
    
    // Check rate limit
    const { allowed, remaining } = checkRateLimit(clientIp);
    
    if (!allowed) {
      return new Response(
        JSON.stringify({ error: 'Rate limit exceeded. Please try again later.' }),
        { 
          status: 429, 
          headers: { 
            ...corsHeaders, 
            'Content-Type': 'application/json',
            'X-RateLimit-Limit': RATE_LIMIT_MAX_REQUESTS.toString(),
            'X-RateLimit-Remaining': '0',
            'X-RateLimit-Reset': new Date(Date.now() + RATE_LIMIT_WINDOW).toISOString()
          } 
        }
      );
    }
    
    // Periodic cleanup
    if (Math.random() < 0.01) { // 1% chance on each request
      cleanupStores();
    }
    
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { 
        headers: { 
          Authorization: authHeader
        } 
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    const url = new URL(req.url);
    const pathname = url.pathname.replace(/^\/onboarding/, '');

    // GET /industries - Get all active industries for onboarding
    if (pathname === '/industries' && req.method === 'GET') {
      const { data, error } = await supabase
        .from('m_catalog_industries')
        .select(`
          id, 
          name, 
          description, 
          icon,
          common_pricing_rules,
          compliance_requirements,
          sort_order
        `)
        .eq('is_active', true)
        .order('sort_order');

      if (error) throw error;

      // Add category count for each industry
      const industriesWithCounts = await Promise.all(
        data.map(async (industry) => {
          const { count } = await supabase
            .from('m_catalog_category_industry_map')
            .select('*', { count: 'exact', head: true })
            .eq('industry_id', industry.id)
            .eq('is_active', true);

          return {
            ...industry,
            available_services_count: count || 0
          };
        })
      );

      return new Response(
        JSON.stringify(industriesWithCounts),
        { 
          status: 200, 
          headers: { 
            ...corsHeaders, 
            'Content-Type': 'application/json',
            'X-RateLimit-Remaining': remaining.toString()
          } 
        }
      );
    }

    // GET /industry-categories/:industryId - Get categories for specific industry
    if (pathname.startsWith('/industry-categories/') && req.method === 'GET') {
      const industryId = pathname.split('/')[2];
      
      if (!industryId) {
        return new Response(
          JSON.stringify({ error: 'Industry ID is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { data, error } = await supabase
        .from('m_catalog_categories')
        .select(`
          id,
          name,
          description,
          icon,
          default_pricing_model,
          suggested_duration,
          common_variants,
          m_catalog_category_industry_map!inner (
            display_name,
            is_primary,
            display_order,
            customizations
          )
        `)
        .eq('m_catalog_category_industry_map.industry_id', industryId)
        .eq('m_catalog_category_industry_map.is_active', true)
        .eq('is_active', true)
        .order('m_catalog_category_industry_map.is_primary', { ascending: false })
        .order('m_catalog_category_industry_map.display_order');

      if (error) throw error;

      // Transform the data
      const transformedData = data.map(category => ({
        id: category.id,
        display_name: category.m_catalog_category_industry_map[0]?.display_name || category.name,
        description: category.description,
        icon: category.icon,
        default_pricing_model: category.default_pricing_model,
        suggested_duration: category.suggested_duration,
        common_variants: category.common_variants,
        is_primary: category.m_catalog_category_industry_map[0]?.is_primary,
        display_order: category.m_catalog_category_industry_map[0]?.display_order,
        customizations: category.m_catalog_category_industry_map[0]?.customizations,
        category_type: category.m_catalog_category_industry_map[0]?.is_primary 
          ? 'Primary Service' 
          : 'Additional Service'
      }));

      return new Response(
        JSON.stringify(transformedData),
        { 
          status: 200, 
          headers: { 
            ...corsHeaders, 
            'Content-Type': 'application/json',
            'X-RateLimit-Remaining': remaining.toString()
          } 
        }
      );
    }

    // GET /pricing-templates - Get pricing templates
    if (pathname === '/pricing-templates' && req.method === 'GET') {
      const industryId = url.searchParams.get('industryId');
      const categoryIds = url.searchParams.get('categoryIds')?.split(',');

      if (!industryId) {
        return new Response(
          JSON.stringify({ error: 'Industry ID is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      let query = supabase
        .from('m_catalog_pricing_templates')
        .select(`
          id,
          template_name,
          template_description,
          rule_type,
          condition_config,
          action_config,
          is_recommended,
          popularity_score,
          sort_order,
          category_id,
          m_catalog_categories (
            name
          )
        `)
        .eq('industry_id', industryId)
        .eq('is_active', true);

      if (categoryIds && categoryIds.length > 0) {
        query = query.or(`category_id.in.(${categoryIds.join(',')}),category_id.is.null`);
      }

      const { data, error } = await query
        .order('is_recommended', { ascending: false })
        .order('popularity_score', { ascending: false })
        .order('sort_order');

      if (error) throw error;

      const transformedData = data.map(template => ({
        ...template,
        category_name: template.m_catalog_categories?.name || 'All Categories'
      }));

      return new Response(
        JSON.stringify(transformedData),
        { 
          status: 200, 
          headers: { 
            ...corsHeaders, 
            'Content-Type': 'application/json',
            'X-RateLimit-Remaining': remaining.toString()
          } 
        }
      );
    }

    // POST /complete - Complete onboarding (with idempotency)
    if (pathname === '/complete' && req.method === 'POST') {
      const tenantHeader = req.headers.get('x-tenant-id');
      const idempotencyKey = req.headers.get('x-idempotency-key');
      
      if (!tenantHeader) {
        return new Response(
          JSON.stringify({ error: 'x-tenant-id header is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      if (!idempotencyKey) {
        return new Response(
          JSON.stringify({ error: 'x-idempotency-key header is required for onboarding completion' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Check idempotency
      const cacheKey = `${tenantHeader}:${idempotencyKey}`;
      const cached = idempotencyStore.get(cacheKey);
      
      if (cached && cached.expiry > Date.now()) {
        return new Response(
          JSON.stringify(cached.response),
          { 
            status: 201, 
            headers: { 
              ...corsHeaders, 
              'Content-Type': 'application/json',
              'X-Idempotent-Replay': 'true'
            } 
          }
        );
      }

      const body = await req.json();
      const { industry_id, selected_category_ids, selected_template_ids } = body;

      if (!industry_id || !selected_category_ids || selected_category_ids.length === 0) {
        return new Response(
          JSON.stringify({ error: 'Industry ID and at least one category are required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Use database transaction to prevent race conditions
      const { data: lockData, error: lockError } = await supabase
        .rpc('acquire_tenant_onboarding_lock', { 
          p_tenant_id: tenantHeader,
          p_timeout_seconds: 30 
        });

      if (lockError || !lockData) {
        return new Response(
          JSON.stringify({ error: 'Could not acquire lock. Another onboarding may be in progress.' }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      try {
        // Check if tenant already onboarded
        const { data: existing } = await supabase
          .from('t_tenant_profiles')
          .select('industry_id')
          .eq('tenant_id', tenantHeader)
          .single();

        if (existing?.industry_id) {
          const response = {
            success: false,
            message: 'Tenant already completed onboarding',
            existing_industry_id: existing.industry_id
          };
          
          // Store in idempotency cache
          idempotencyStore.set(cacheKey, {
            response,
            expiry: Date.now() + IDEMPOTENCY_EXPIRY
          });
          
          return new Response(
            JSON.stringify(response),
            { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Fetch categories with industry mapping
        const { data: categories, error: catError } = await supabase
          .from('m_catalog_categories')
          .select(`
            *,
            m_catalog_category_industry_map!inner (
              display_name,
              customizations
            )
          `)
          .in('id', selected_category_ids)
          .eq('m_catalog_category_industry_map.industry_id', industry_id);

        if (catError) throw catError;

        // Copy categories to tenant
        const tenantCategories = categories.map(cat => ({
          tenant_id: tenantHeader,
          category_id: cat.id,
          name: cat.m_catalog_category_industry_map[0]?.display_name || cat.name,
          description: cat.description,
          pricing_model: cat.default_pricing_model,
          customizations: cat.m_catalog_category_industry_map[0]?.customizations,
          is_active: true
        }));

        const { error: insertCatError } = await supabase
          .from('t_service_categories')
          .insert(tenantCategories);

        if (insertCatError) throw insertCatError;

        // Copy pricing templates if selected
        if (selected_template_ids && selected_template_ids.length > 0) {
          const { data: templates, error: templateError } = await supabase
            .from('m_catalog_pricing_templates')
            .select('*')
            .in('id', selected_template_ids);

          if (templateError) throw templateError;

          const tenantRules = templates.map(template => ({
            tenant_id: tenantHeader,
            category_id: template.category_id,
            rule_name: template.template_name,
            rule_type: template.rule_type,
            conditions: template.condition_config,
            actions: template.action_config
          }));

          const { error: insertRuleError } = await supabase
            .from('t_pricing_rules')
            .insert(tenantRules);

          if (insertRuleError) throw insertRuleError;
        }

        // Update tenant profile with industry
        const { error: updateError } = await supabase
          .from('t_tenant_profiles')
          .update({ 
            industry_id,
            onboarding_completed_at: new Date().toISOString()
          })
          .eq('tenant_id', tenantHeader);

        if (updateError) throw updateError;

        const response = {
          success: true,
          message: 'Onboarding completed successfully',
          tenant_id: tenantHeader,
          industry_id,
          categories_copied: tenantCategories.length,
          templates_copied: selected_template_ids?.length || 0,
          completed_at: new Date().toISOString()
        };

        // Store in idempotency cache
        idempotencyStore.set(cacheKey, {
          response,
          expiry: Date.now() + IDEMPOTENCY_EXPIRY
        });

        return new Response(
          JSON.stringify(response),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );

      } finally {
        // Release lock
        await supabase.rpc('release_tenant_onboarding_lock', { 
          p_tenant_id: tenantHeader 
        });
      }
    }

    return new Response(
      JSON.stringify({ error: 'Endpoint not found' }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Error in onboarding function:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});