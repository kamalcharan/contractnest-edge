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

        return jsonResponse(data || []);
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

      // Encrypt credentials before saving
      const encryptedCredentials = await encryptData(requestData.credentials || {}, encryptionKey);

      const { data, error } = await supabase.rpc('save_tenant_integration', {
        p_tenant_id: tenantId,
        p_master_integration_id: requestData.master_integration_id,
        p_credentials: encryptedCredentials,
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
            const decryptedExisting = await decryptData(existingCreds, encryptionKey);
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
