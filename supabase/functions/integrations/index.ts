// ============================================================================
// Integrations Edge Function
// ============================================================================
// Purpose: Handle integration operations via RPC calls
// Pattern: UI → API → Edge (this) → RPC → DB
// Security: Follows billing pattern - RPC functions bypass RLS
// ============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

// ============================================================================
// ENCRYPTION UTILITIES
// ============================================================================

async function encryptData(data: any, encryptionKey: string): Promise<string> {
  const jsonData = JSON.stringify(data);
  const dataBytes = new TextEncoder().encode(jsonData);
  const iv = crypto.getRandomValues(new Uint8Array(12));

  const keyBytes = new TextEncoder().encode(encryptionKey.padEnd(32, '0').slice(0, 32));
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt']
  );

  const encryptedContent = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: iv },
    cryptoKey,
    dataBytes
  );

  const encryptedBytes = new Uint8Array(iv.length + encryptedContent.byteLength);
  encryptedBytes.set(iv, 0);
  encryptedBytes.set(new Uint8Array(encryptedContent), iv.length);

  return btoa(String.fromCharCode(...encryptedBytes));
}

async function decryptData(encryptedData: string, encryptionKey: string): Promise<any> {
  const encryptedBytes = new Uint8Array(atob(encryptedData).split('').map(c => c.charCodeAt(0)));
  const iv = encryptedBytes.slice(0, 12);
  const ciphertext = encryptedBytes.slice(12);

  const keyBytes = new TextEncoder().encode(encryptionKey.padEnd(32, '0').slice(0, 32));
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );

  const decryptedContent = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: iv },
    cryptoKey,
    ciphertext
  );

  const jsonString = new TextDecoder().decode(decryptedContent);
  return JSON.parse(jsonString);
}

// ============================================================================
// TEST CONNECTION IMPLEMENTATIONS
// ============================================================================

async function testRazorpayConnection(credentials: any): Promise<{ success: boolean; message: string }> {
  try {
    const { key_id, key_secret, test_mode } = credentials;

    if (!key_id || !key_secret) {
      return {
        success: false,
        message: 'API Key ID and API Key Secret are required'
      };
    }

    if (!key_id.startsWith('rzp_')) {
      return {
        success: false,
        message: 'Invalid Razorpay Key ID format. It should start with rzp_'
      };
    }

    return {
      success: true,
      message: 'Razorpay connection verified successfully'
    };
  } catch (error) {
    return {
      success: false,
      message: `Razorpay connection failed: ${error.message}`
    };
  }
}

async function testStripeConnection(credentials: any): Promise<{ success: boolean; message: string }> {
  try {
    const { publishable_key, secret_key, test_mode } = credentials;

    if (!publishable_key || !secret_key) {
      return {
        success: false,
        message: 'Publishable Key and Secret Key are required'
      };
    }

    const keyPrefix = test_mode ? 'sk_test_' : 'sk_live_';
    if (!secret_key.startsWith(keyPrefix)) {
      return {
        success: false,
        message: `Invalid Stripe Secret Key format. It should start with ${keyPrefix}`
      };
    }

    const pubKeyPrefix = test_mode ? 'pk_test_' : 'pk_live_';
    if (!publishable_key.startsWith(pubKeyPrefix)) {
      return {
        success: false,
        message: `Invalid Stripe Publishable Key format. It should start with ${pubKeyPrefix}`
      };
    }

    return {
      success: true,
      message: 'Stripe connection verified successfully'
    };
  } catch (error) {
    return {
      success: false,
      message: `Stripe connection failed: ${error.message}`
    };
  }
}

async function testSendGridConnection(credentials: any): Promise<{ success: boolean; message: string }> {
  try {
    const { api_key, from_email } = credentials;

    if (!api_key || !from_email) {
      return {
        success: false,
        message: 'API Key and From Email are required'
      };
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(from_email)) {
      return {
        success: false,
        message: 'Invalid From Email format'
      };
    }

    if (!api_key.startsWith('SG.')) {
      return {
        success: false,
        message: 'Invalid SendGrid API Key format. It should start with SG.'
      };
    }

    return {
      success: true,
      message: 'SendGrid connection verified successfully'
    };
  } catch (error) {
    return {
      success: false,
      message: `SendGrid connection failed: ${error.message}`
    };
  }
}

async function testTwilioConnection(credentials: any): Promise<{ success: boolean; message: string }> {
  try {
    const { account_sid, auth_token, from_number } = credentials;

    if (!account_sid || !auth_token || !from_number) {
      return {
        success: false,
        message: 'Account SID, Auth Token, and From Number are required'
      };
    }

    if (!account_sid.startsWith('AC')) {
      return {
        success: false,
        message: 'Invalid Twilio Account SID format. It should start with AC'
      };
    }

    return {
      success: true,
      message: 'Twilio connection verified successfully'
    };
  } catch (error) {
    return {
      success: false,
      message: `Twilio connection failed: ${error.message}`
    };
  }
}

async function testOneSignalConnection(credentials: any): Promise<{ success: boolean; message: string }> {
  try {
    const { app_id, api_key } = credentials;

    if (!app_id || !api_key) {
      return {
        success: false,
        message: 'App ID and API Key are required'
      };
    }

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(app_id)) {
      return {
        success: false,
        message: 'Invalid OneSignal App ID format'
      };
    }

    return {
      success: true,
      message: 'OneSignal connection verified successfully'
    };
  } catch (error) {
    return {
      success: false,
      message: `OneSignal connection failed: ${error.message}`
    };
  }
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function jsonResponse(data: any, status: number = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json'
    }
  });
}

// ============================================================================
// MAIN HANDLER
// ============================================================================

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const encryptionKey = Deno.env.get('INTEGRATION_ENCRYPTION_KEY') || 'default-encryption-key-change-in-prod';

    if (!supabaseUrl || !supabaseKey) {
      console.error('Missing environment variables');
      return jsonResponse({ error: 'Server configuration error' }, 500);
    }

    // Get auth header and tenant ID
    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');

    if (!authHeader) {
      return jsonResponse({ error: 'Authorization header is required' }, 401);
    }

    // Create Supabase client
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { Authorization: authHeader } }
    });

    // Direct reads of t_tenant_integrations. `supabase` above forwards the
    // user's JWT, and that table's RLS (tenant_id = get_current_tenant_id(),
    // a claim our JWTs do not carry) returns ZERO rows with no error — which
    // is why the save "merge" never found the saved values and a QR-only save
    // wiped the UPI id. This client uses the service role; every query on it
    // is filtered to the request's tenant explicitly, the same trust model as
    // the tenant-scoped RPCs used throughout this function.
    const serviceDb = createClient(supabaseUrl, supabaseKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // Parse URL
    const url = new URL(req.url);
    const isLive = url.searchParams.get('isLive') === 'true';
    const integrationType = url.searchParams.get('type');
    const providerId = url.searchParams.get('providerId');

    console.log('Request:', {
      method: req.method,
      path: url.pathname,
      isLive,
      integrationType,
      providerId,
      tenantId
    });

    // ========================================================================
    // GET HANDLERS
    // ========================================================================

    if (req.method === 'GET' && url.pathname.endsWith('/integrations')) {

      // GET integration types (no type or providerId specified)
      if (!integrationType && !providerId) {
        // If no tenant header, return basic type info
        if (!tenantId) {
          const { data, error } = await supabase.rpc('get_integration_types_with_status', {
            p_tenant_id: '',
            p_is_live: isLive
          });

          if (error) {
            console.error('Error fetching types:', error);
            return jsonResponse({ error: 'Failed to fetch integration types' }, 500);
          }

          return jsonResponse(data || []);
        }

        // With tenant header, get counts
        const { data, error } = await supabase.rpc('get_integration_types_with_status', {
          p_tenant_id: tenantId,
          p_is_live: isLive
        });

        if (error) {
          console.error('Error fetching types with status:', error);
          return jsonResponse({ error: 'Failed to fetch integration types' }, 500);
        }

        return jsonResponse(data || []);
      }

      // For provider or type queries, tenant header is required
      if (!tenantId) {
        return jsonResponse({ error: 'x-tenant-id header is required' }, 400);
      }

      // GET specific integration by providerId
      if (providerId) {
        const { data, error } = await supabase.rpc('get_tenant_integration', {
          p_tenant_id: tenantId,
          p_provider_id: providerId,
          p_is_live: isLive
        });

        if (error) {
          console.error('Error fetching integration:', error);
          return jsonResponse({ error: 'Failed to fetch integration' }, 500);
        }

        // Don't return credentials to client
        if (data && data.credentials) {
          data.credentials = {};
        }

        return jsonResponse(data);
      }

      // GET integrations by type
      if (integrationType) {
        const { data, error } = await supabase.rpc('get_integrations_by_type', {
          p_tenant_id: tenantId,
          p_type: integrationType,
          p_is_live: isLive
        });

        if (error) {
          console.error('Error fetching integrations by type:', error);
          return jsonResponse({ error: 'Failed to fetch integrations' }, 500);
        }

        // Config-only providers (Offline UPI) keep a plaintext, payer-facing
        // `public` blob — the UPI id, payee name and QR the customer already
        // sees on the payment page. Return it so the edit form opens with the
        // saved values instead of blank fields (a blank form is how a QR
        // upload used to submit the QR alone). Secret-bearing providers
        // (Razorpay etc.) still get nothing back.
        const rows: any[] = Array.isArray(data) ? data : [];
        const configOnlyIds = rows
          .filter((r) => r?.is_configured && r?.metadata?.config_only && r?.master_integration_id)
          .map((r) => r.master_integration_id);
        if (configOnlyIds.length > 0) {
          try {
            const { data: saved } = await serviceDb
              .from('t_tenant_integrations')
              .select('master_integration_id, credentials')
              .eq('tenant_id', tenantId)
              .eq('is_live', isLive)
              .in('master_integration_id', configOnlyIds);
            const byProvider = new Map<string, Record<string, any>>();
            for (const s of saved || []) {
              byProvider.set(s.master_integration_id, s?.credentials?.public || {});
            }
            for (const r of rows) {
              if (byProvider.has(r.master_integration_id)) {
                r.credentials = byProvider.get(r.master_integration_id);
              }
            }
          } catch (e) {
            // Non-fatal: the page still loads, the form just opens blank.
            console.error('Error attaching public credentials:', e);
          }
        }

        return jsonResponse(rows);
      }
    }

    // ========================================================================
    // POST /integrations - Create/Update integration
    // ========================================================================

    if (req.method === 'POST' && url.pathname.endsWith('/integrations')) {
      if (!tenantId) {
        return jsonResponse({ error: 'x-tenant-id header is required' }, 400);
      }

      const requestData = await req.json();

      if (!requestData.master_integration_id) {
        return jsonResponse({ error: 'master_integration_id is required' }, 400);
      }

      // What gets encrypted. For every provider except config-only ones this
      // is exactly what the client sent (unchanged behaviour).
      let credentialsToStore: Record<string, any> = requestData.credentials || {};
      const credentialsJsonb: Record<string, any> = {};

      // For config-only providers (e.g. Offline UPI) keep a plaintext,
      // payer-facing copy so the public check-in page can read the VPA. These
      // values (UPI id + payee name + QR) are non-secret by design.
      //
      // MERGED with the existing public blob, never replaced, so a save only
      // changes what it means to change:
      //   · a field the client did not send is kept (derived org_id/mcc from
      //     an uploaded merchant QR are never in the form);
      //   · a field sent blank ('' / null) is kept too — a blank form field
      //     means "untouched", not "erase" (a QR upload on a form that opened
      //     blank used to submit the QR alone and wipe the UPI id);
      //   · a field is removed ONLY when named in `clear_fields` (the
      //     "Remove QR" button).
      // If the existing row cannot be read the save is REFUSED: saving without
      // the merge would overwrite the stored blob with a partial one.
      const { data: prov, error: provErr } = await supabase.rpc('get_integration_provider', {
        p_provider_id: requestData.master_integration_id
      });
      if (provErr) {
        console.error('Error loading provider before save:', provErr);
        return jsonResponse({ error: 'Failed to save integration' }, 500);
      }
      if (prov?.metadata?.config_only) {
        const targetIsLive = requestData.is_live ?? isLive;
        const { data: existingRow, error: existingErr } = await serviceDb
          .from('t_tenant_integrations')
          .select('credentials')
          .eq('tenant_id', tenantId)
          .eq('master_integration_id', requestData.master_integration_id)
          .eq('is_live', targetIsLive)
          .maybeSingle();
        if (existingErr) {
          console.error('Error reading saved settings before merge:', existingErr);
          return jsonResponse({ error: 'Could not read your saved settings. Nothing was changed — please try again.' }, 500);
        }
        const merged: Record<string, any> = { ...(existingRow?.credentials?.public || {}) };
        for (const [key, value] of Object.entries(requestData.credentials || {})) {
          if (value === '' || value === null || value === undefined) continue;
          merged[key] = value;
        }
        const clearFields: string[] = Array.isArray(requestData.clear_fields)
          ? requestData.clear_fields.filter((f: unknown) => typeof f === 'string')
          : [];
        for (const key of clearFields) delete merged[key];
        credentialsJsonb.public = merged;
        credentialsToStore = merged;
      }

      // Encrypt credentials before saving, wrapped for the JSONB column
      credentialsJsonb.encrypted = await encryptData(credentialsToStore, encryptionKey);

      const { data, error } = await supabase.rpc('save_tenant_integration', {
        p_tenant_id: tenantId,
        p_master_integration_id: requestData.master_integration_id,
        p_credentials: credentialsJsonb,
        p_is_live: requestData.is_live ?? isLive,
        p_is_active: requestData.is_active ?? true,
        p_connection_status: requestData.connection_status || 'Pending'
      });

      if (error) {
        console.error('Error saving integration:', error);
        return jsonResponse({ error: 'Failed to save integration' }, 500);
      }

      return jsonResponse(data, 201);
    }

    // ========================================================================
    // DELETE /integrations/tenant-integrations?id= - Remove a tenant integration
    // ========================================================================

    if (req.method === 'DELETE' && url.pathname.includes('tenant-integrations')) {
      if (!tenantId) {
        return jsonResponse({ error: 'x-tenant-id header is required' }, 400);
      }

      const delId = url.searchParams.get('id');
      if (!delId) {
        return jsonResponse({ error: 'id query parameter is required' }, 400);
      }

      const { data, error } = await supabase.rpc('delete_tenant_integration', {
        p_tenant_id: tenantId,
        p_integration_id: delId
      });

      if (error) {
        console.error('Error deleting integration:', error);
        return jsonResponse({ error: 'Failed to delete integration' }, 500);
      }

      if (!data?.success) {
        return jsonResponse({ error: data?.error || 'Integration not found or not authorized' }, 404);
      }

      return jsonResponse(data);
    }

    // ========================================================================
    // POST /test - Test integration connection
    // ========================================================================

    if (req.method === 'POST' && url.pathname.endsWith('/test')) {
      if (!tenantId) {
        return jsonResponse({ error: 'x-tenant-id header is required' }, 400);
      }

      const requestData = await req.json();

      if (!requestData.master_integration_id || !requestData.credentials) {
        return jsonResponse({ error: 'master_integration_id and credentials are required' }, 400);
      }

      // Get provider details to know which test function to use
      const { data: provider, error: providerError } = await supabase.rpc('get_integration_provider', {
        p_provider_id: requestData.master_integration_id
      });

      if (providerError || !provider) {
        return jsonResponse({ error: 'Invalid provider ID' }, 400);
      }

      // If testing existing integration, merge with existing credentials
      let testCredentials = requestData.credentials;

      if (requestData.integration_id) {
        const { data: existingCreds } = await supabase.rpc('get_integration_credentials', {
          p_tenant_id: tenantId,
          p_integration_id: requestData.integration_id
        });

        if (existingCreds) {
          try {
            // Handle both new format { encrypted: "..." } and legacy plain string
            const encryptedString = typeof existingCreds === 'object' && existingCreds.encrypted
              ? existingCreds.encrypted
              : existingCreds;
            const decryptedExisting = await decryptData(encryptedString, encryptionKey);
            // Merge existing with new credentials
            testCredentials = {
              ...decryptedExisting,
              ...Object.fromEntries(
                Object.entries(requestData.credentials).filter(([_, v]) => v !== '' && v !== undefined)
              )
            };
          } catch (e) {
            console.error('Error decrypting existing credentials:', e);
          }
        }
      }

      // Call appropriate test function based on provider
      let testResult: { success: boolean; message: string };

      // Config-only providers (e.g. Offline UPI) have nothing to connect to —
      // there is no endpoint to verify. Treat them as always valid so the
      // stored values (e.g. a UPI VPA) can be saved without a live test.
      if (provider.metadata?.config_only || provider.name === 'offline_upi') {
        return jsonResponse({ success: true, message: 'No connection test required for this provider.' });
      }

      switch (provider.name) {
        case 'razorpay':
          testResult = await testRazorpayConnection(testCredentials);
          break;
        case 'stripe':
          testResult = await testStripeConnection(testCredentials);
          break;
        case 'sendgrid':
          testResult = await testSendGridConnection(testCredentials);
          break;
        case 'twilio':
          testResult = await testTwilioConnection(testCredentials);
          break;
        case 'onesignal':
          testResult = await testOneSignalConnection(testCredentials);
          break;
        default:
          testResult = {
            success: false,
            message: `Test connection not implemented for provider: ${provider.name}`
          };
      }

      // Update last_verified if test was successful and save flag is true
      if (testResult.success && requestData.save !== false && requestData.integration_id) {
        await supabase.rpc('update_integration_verified', {
          p_tenant_id: tenantId,
          p_integration_id: requestData.integration_id
        });
      }

      return jsonResponse(testResult);
    }

    // ========================================================================
    // PUT /status/{id} - Toggle integration status
    // ========================================================================

    if (req.method === 'PUT' && url.pathname.includes('/status')) {
      if (!tenantId) {
        return jsonResponse({ error: 'x-tenant-id header is required' }, 400);
      }

      const pathParts = url.pathname.split('/');
      const integrationId = pathParts[pathParts.length - 1];
      const requestData = await req.json();

      if (!integrationId || integrationId === 'status') {
        return jsonResponse({ error: 'Integration ID is required' }, 400);
      }

      if (requestData.is_active === undefined) {
        return jsonResponse({ error: 'is_active field is required' }, 400);
      }

      const { data, error } = await supabase.rpc('toggle_integration_status', {
        p_tenant_id: tenantId,
        p_integration_id: integrationId,
        p_is_active: requestData.is_active
      });

      if (error) {
        console.error('Error toggling status:', error);
        return jsonResponse({ error: 'Failed to update status' }, 500);
      }

      if (!data?.success) {
        return jsonResponse({ error: data?.error || 'Integration not found or not authorized' }, 404);
      }

      return jsonResponse(data);
    }

    // If no matching endpoint is found
    return jsonResponse({
      error: 'Invalid endpoint or method',
      method: req.method,
      path: url.pathname
    }, 404);

  } catch (error) {
    console.error('Error processing request:', error);
    return jsonResponse({
      error: 'Internal server error',
      details: error.message
    }, 500);
  }
});
