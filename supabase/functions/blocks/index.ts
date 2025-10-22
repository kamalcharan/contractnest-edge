// supabase/functions/blocks/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { corsHeaders } from "../_shared/cors.ts";

console.log("blocks function starting...");

// Types for block system
interface BlockCategory {
  id: string;
  created_at: string;
  parent_id: string | null;
  version: number;
  name: string | null;
  description: string | null;
  icon: string | null;
  sort_order: number | null;
  active: boolean | null;
}

interface BlockMaster {
  id: string;
  created_at: string;
  parent_id: string | null;
  version: number;
  category_id: string;
  name: string | null;
  description: string | null;
  icon: string | null;
  node_type: string | null;
  config: any;
  theme_styles: any;
  can_rotate: boolean | null;
  can_resize: boolean | null;
  is_bidirectional: boolean | null;
  icon_names: string[] | null;
  hex_color: string | null;
  border_style: string | null;
  active: boolean | null;
}

interface BlockVariant {
  id: string;
  created_at: string;
  parent_id: string | null;
  version: number;
  block_id: string;
  name: string | null;
  description: string | null;
  node_type: string | null;
  default_config: any;
  active: boolean | null;
}

// Helper function to generate HMAC signature (matching your Node.js implementation)
async function generateHMACSignature(payload: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

// Enhanced signature validation with better body handling
async function validateInternalSignature(req: Request, internalSecret: string): Promise<boolean> {
  const internalSignature = req.headers.get('x-internal-signature');
  if (!internalSignature || !internalSecret) {
    return false;
  }

  try {
    const clonedReq = req.clone();
    const body = await clonedReq.text();
    const expectedSignature = await generateHMACSignature(body, internalSecret);
    
    const isValid = internalSignature === expectedSignature;
    if (!isValid) {
      console.error('[Security] Invalid internal signature', {
        expected: expectedSignature.substring(0, 10) + '...',
        received: internalSignature.substring(0, 10) + '...',
        bodyLength: body.length
      });
    }
    return isValid;
  } catch (error) {
    console.error('[Security] Error validating signature:', error);
    return false;
  }
}

serve(async (req: Request) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const method = req.method;
  const url = new URL(req.url);

  // Parse URL path segments
  let pathname = url.pathname;
  if (pathname.startsWith('/')) {
    pathname = pathname.substring(1);
  }
  
  // Remove function name if present
  if (pathname.startsWith('blocks')) {
    pathname = pathname.substring('blocks'.length);
    if (pathname.startsWith('/')) {
      pathname = pathname.substring(1);
    }
  }
  
  const pathSegments = pathname ? pathname.split('/').filter(Boolean) : [];
  
  console.log('🔍 Parsed URL Info:');
  console.log('  - Method:', method);
  console.log('  - Path segments:', pathSegments);
  console.log('  - Query params:', Object.fromEntries(url.searchParams.entries()));

  try {
    // Environment validation
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');
    
    if (!supabaseUrl || !supabaseServiceKey) {
      console.error('Missing required environment variables');
      return new Response(
        JSON.stringify({ 
          error: 'Server configuration error',
          details: ['SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set']
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Create Supabase client
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Extract headers
    const authHeader = req.headers.get('authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const environment = req.headers.get('x-environment') || 'test';
    
    console.log('Request validation:', {
      hasAuth: !!authHeader,
      hasTenantId: !!tenantId,
      environment: environment,
      hasInternalSecret: !!internalSecret,
      method: method
    });

    // Validate internal signature for security (only for non-GET requests)
    if (method !== 'GET' && internalSecret) {
      const isValidSignature = await validateInternalSignature(req, internalSecret);
      if (!isValidSignature) {
        console.error('[Security] Invalid internal signature');
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { 
            status: 401, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }
      console.log('[Security] Internal signature validated successfully');
    }

    // Only allow GET requests for now (read-only)
    if (method !== 'GET') {
      return new Response(
        JSON.stringify({ error: 'Method not allowed. Only GET requests are supported.' }),
        { 
          status: 405, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Route: GET /categories - List block categories
    if (pathSegments.length === 1 && pathSegments[0] === 'categories') {
      console.log('Getting block categories');

      const { data: categories, error } = await supabase
        .from('m_block_categories')
        .select('*')
        .eq('active', true)
        .order('sort_order', { ascending: true });

      if (error) {
        console.error('Database error:', error);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to fetch block categories',
            details: error.message 
          }), 
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      return new Response(
        JSON.stringify({ 
          success: true,
          data: categories,
          count: categories?.length || 0
        }), 
        { 
          status: 200, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Route: GET /masters - List block masters (optionally filtered by category)
    if (pathSegments.length === 1 && pathSegments[0] === 'masters') {
      console.log('Getting block masters');

      const categoryId = url.searchParams.get('categoryId');
      
      let query = supabase
        .from('m_block_masters')
        .select(`
          *,
          category:m_block_categories(id, name, icon)
        `)
        .eq('active', true);

      if (categoryId) {
        query = query.eq('category_id', categoryId);
      }

      const { data: masters, error } = await query.order('name', { ascending: true });

      if (error) {
        console.error('Database error:', error);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to fetch block masters',
            details: error.message 
          }), 
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      return new Response(
        JSON.stringify({ 
          success: true,
          data: masters,
          count: masters?.length || 0,
          filters: { categoryId }
        }), 
        { 
          status: 200, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Route: GET /masters/{masterId}/variants - List variants for a block master
    if (pathSegments.length === 3 && pathSegments[0] === 'masters' && pathSegments[2] === 'variants') {
      const masterId = pathSegments[1];
      console.log('Getting variants for master:', masterId);

      const { data: variants, error } = await supabase
        .from('m_block_variants')
        .select(`
          *,
          master:m_block_masters(id, name, icon, node_type)
        `)
        .eq('block_id', masterId)
        .eq('active', true)
        .order('name', { ascending: true });

      if (error) {
        console.error('Database error:', error);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to fetch block variants',
            details: error.message 
          }), 
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      return new Response(
        JSON.stringify({ 
          success: true,
          data: variants,
          count: variants?.length || 0,
          masterId: masterId
        }), 
        { 
          status: 200, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Route: GET /hierarchy - Get complete block hierarchy
    if (pathSegments.length === 1 && pathSegments[0] === 'hierarchy') {
      console.log('Getting complete block hierarchy');
      console.log('Environment:', environment);
      console.log('Tenant ID:', tenantId);

      // Get categories with their masters and variants
      const { data: categories, error: categoriesError } = await supabase
        .from('m_block_categories')
        .select('*')
        .eq('active', true)
        .order('sort_order', { ascending: true });

      if (categoriesError) {
        console.error('Database error fetching categories:', categoriesError);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to fetch block categories',
            details: categoriesError.message 
          }), 
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      // Get all masters
      const { data: masters, error: mastersError } = await supabase
        .from('m_block_masters')
        .select('*')
        .eq('active', true)
        .order('name', { ascending: true });

      if (mastersError) {
        console.error('Database error fetching masters:', mastersError);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to fetch block masters',
            details: mastersError.message 
          }), 
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      // Get all variants
      const { data: variants, error: variantsError } = await supabase
        .from('m_block_variants')
        .select('*')
        .eq('active', true)
        .order('name', { ascending: true });

      if (variantsError) {
        console.error('Database error fetching variants:', variantsError);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to fetch block variants',
            details: variantsError.message 
          }), 
          { 
            status: 500, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      // Build hierarchy with 'masters' property (FIXED from 'blockMasters')
      const hierarchy = categories?.map(category => ({
        ...category,
        masters: masters?.filter(master => master.category_id === category.id).map(master => ({
          ...master,
          variants: variants?.filter(variant => variant.block_id === master.id) || []
        })) || []
      })) || [];

      // Log hierarchy structure for debugging
      console.log('Hierarchy structure:', {
        categoriesCount: categories?.length || 0,
        mastersCount: masters?.length || 0,
        variantsCount: variants?.length || 0,
        firstCategory: hierarchy[0] ? {
          name: hierarchy[0].name,
          mastersCount: hierarchy[0].masters?.length || 0
        } : null
      });

      return new Response(
        JSON.stringify({ 
          success: true,
          data: hierarchy,
          summary: {
            categories: categories?.length || 0,
            masters: masters?.length || 0,
            variants: variants?.length || 0
          }
        }), 
        { 
          status: 200, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Route: GET /variant/{variantId} - Get specific variant details
    if (pathSegments.length === 2 && pathSegments[0] === 'variant') {
      const variantId = pathSegments[1];
      console.log('Getting variant details:', variantId);

      const { data: variant, error } = await supabase
        .from('m_block_variants')
        .select(`
          *,
          master:m_block_masters(
            *,
            category:m_block_categories(*)
          )
        `)
        .eq('id', variantId)
        .eq('active', true)
        .single();

      if (error) {
        const status = error.code === 'PGRST116' ? 404 : 500; // PGRST116 = not found
        return new Response(
          JSON.stringify({ 
            error: status === 404 ? 'Block variant not found' : 'Failed to fetch block variant',
            details: error.message 
          }), 
          { 
            status, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }

      return new Response(
        JSON.stringify({ 
          success: true,
          data: variant
        }), 
        { 
          status: 200, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Default: Route not found
    console.log('Unhandled route:', method, pathSegments);
    return new Response(
      JSON.stringify({ 
        error: 'Not found',
        available_routes: [
          'GET /categories',
          'GET /masters',
          'GET /masters?categoryId={id}',
          'GET /masters/{masterId}/variants',
          'GET /hierarchy',
          'GET /variant/{variantId}'
        ]
      }),
      { 
        status: 404, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );

  } catch (error) {
    console.error('Unhandled error in blocks function:', error);
    
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error',
        message: error.message
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});

console.log("blocks function ready to serve requests!");