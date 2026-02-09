// supabase/functions/audit-log/index.ts
// Edge function for contract audit log queries
// Pattern: CORS → HMAC validation → single RPC → response
//
// Routes:
//   GET    /audit-log                     → get_audit_log (paginated, filtered)

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // ==========================================================
    // STEP 1: Extract and validate headers
    // ==========================================================
    const tenantId = req.headers.get('x-tenant-id');

    // ==========================================================
    // STEP 2: Validate environment variables
    // ==========================================================
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    // ==========================================================
    // STEP 3: Validate tenant ID
    // ==========================================================
    if (!tenantId) {
      return jsonResponse(
        { success: false, error: 'x-tenant-id header is required', code: 'MISSING_TENANT_ID' },
        400
      );
    }

    // ==========================================================
    // STEP 4: Validate HMAC signature (internal handshake)
    // ==========================================================
    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return jsonResponse(
        { success: false, error: 'Missing internal signature', code: 'MISSING_SIGNATURE' },
        401
      );
    }

    let requestBody = '';
    if (internalSigningSecret && signature) {
      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValid = await verifyInternalSignature(requestBody, signature, internalSigningSecret);

      if (!isValid) {
        return jsonResponse(
          { success: false, error: 'Invalid internal signature', code: 'INVALID_SIGNATURE' },
          403
        );
      }
    }

    // ==========================================================
    // STEP 5: Initialize Supabase client (service_role)
    // ==========================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ==========================================================
    // STEP 6: Route — only GET is supported
    // ==========================================================
    if (req.method !== 'GET') {
      return jsonResponse(
        { success: false, error: 'Method not allowed. Audit log is read-only.', code: 'METHOD_NOT_ALLOWED' },
        405
      );
    }

    const url = new URL(req.url);
    return await handleList(supabase, tenantId, url.searchParams);

  } catch (error: any) {
    console.error('Error in audit-log edge function:', error);
    return jsonResponse(
      { success: false, error: error.message || 'Internal server error', code: 'INTERNAL_ERROR' },
      500
    );
  }
});


// ==========================================================
// HANDLER: GET — paginated audit log with filters
// RPC: get_audit_log
// ==========================================================
async function handleList(
  supabase: any,
  tenantId: string,
  searchParams: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_audit_log', {
    p_tenant_id:    tenantId,
    p_contract_id:  searchParams.get('contract_id') || null,
    p_entity_type:  searchParams.get('entity_type') || null,
    p_entity_id:    searchParams.get('entity_id') || null,
    p_category:     searchParams.get('category') || null,
    p_performed_by: searchParams.get('performed_by') || null,
    p_date_from:    searchParams.get('date_from') || null,
    p_date_to:      searchParams.get('date_to') || null,
    p_page:         parseInt(searchParams.get('page') || '1', 10),
    p_per_page:     Math.min(parseInt(searchParams.get('per_page') || '20', 10), 100)
  });

  if (error) {
    console.error('RPC get_audit_log error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// UTILITY: JSON response with CORS headers
// ==========================================================
function jsonResponse(data: any, status: number = 200): Response {
  return new Response(
    JSON.stringify(data),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}


// ==========================================================
// UTILITY: HMAC signature verification (Deno Web Crypto)
// ==========================================================
async function verifyInternalSignature(
  body: string,
  signature: string,
  secret: string
): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(body);

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    return signature === expectedSignature;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
}
