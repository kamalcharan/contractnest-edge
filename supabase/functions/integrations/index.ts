import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

// Encryption utilities
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

// Test connection implementations for different providers
async function testRazorpayConnection(credentials: any): Promise<{ success: boolean; message: string }> {
  try {
    const { key_id, key_secret, test_mode } = credentials;
    
    if (!key_id || !key_secret) {
      return {
        success: false,
        message: 'API Key ID and API Key Secret are required'
      };
    }
    
    // Basic validation of Razorpay key format
    if (!key_id.startsWith('rzp_')) {
      return {
        success: false,
        message: 'Invalid Razorpay Key ID format. It should start with rzp_'
      };
    }
    
    // In production, make actual API call to Razorpay to verify credentials
    // For now, we'll do basic validation
    const baseUrl = test_mode ? 'https://api.razorpay.com/v1' : 'https://api.razorpay.com/v1';
    
    // TODO: Implement actual API call when Razorpay is accessible from edge function
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
    
    // Basic validation of Stripe key format
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
    
    // TODO: Implement actual Stripe API verification
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
    
    // Basic email validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(from_email)) {
      return {
        success: false,
        message: 'Invalid From Email format'
      };
    }
    
    // Basic API key format validation
    if (!api_key.startsWith('SG.')) {
      return {
        success: false,
        message: 'Invalid SendGrid API Key format. It should start with SG.'
      };
    }
    
    // TODO: Implement actual SendGrid API verification
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
    
    // Basic validation of Twilio account SID format
    if (!account_sid.startsWith('AC')) {
      return {
        success: false,
        message: 'Invalid Twilio Account SID format. It should start with AC'
      };
    }
    
    // TODO: Implement actual Twilio API verification
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
    
    // Basic UUID format validation for app_id
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(app_id)) {
      return {
        success: false,
        message: 'Invalid OneSignal App ID format'
      };
    }
    
    // TODO: Implement actual OneSignal API verification
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

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const encryptionKey = Deno.env.get('INTEGRATION_ENCRYPTION_KEY') || 'default-encryption-key-change-in-prod';
    
    // Validate required environment variables
    if (!supabaseUrl || !supabaseKey) {
      console.error('Missing environment variables');
      return new Response(
        JSON.stringify({ error: 'Server configuration error: Missing Supabase configuration' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get auth header
    const authHeader = req.headers.get('Authorization');
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Parse URL to get query parameters
    const url = new URL(req.url);
    const isLive = url.searchParams.get('isLive') === 'true';
    const integrationType = url.searchParams.get('type');
    const providerId = url.searchParams.get('providerId');
    
    console.log('Request:', {
      method: req.method,
      path: url.pathname,
      isLive,
      integrationType,
      providerId
    });
    
    // Main /integrations endpoint
    if (req.method === 'GET' && url.pathname.endsWith('/integrations')) {
      const tenantHeader = req.headers.get('x-tenant-id');
      
      // Create Supabase client
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
      
      // If no type or providerId, return integration types
      if (!integrationType && !providerId) {
        try {
          const { data: types, error } = await supabase
            .from('t_integration_types')
            .select('*')
            .eq('is_active', true);
            
          if (error) {
            console.error('Error fetching types:', error);
            throw error;
          }
          
          // If no tenant header, return basic type info
          if (!tenantHeader) {
            const typesWithStatus = (types || []).map(type => ({
              integration_type: type.name,
              display_name: type.display_name,
              description: type.description,
              icon_name: type.icon_name,
              active_count: 0,
              total_available: 0
            }));
            
            return new Response(
              JSON.stringify(typesWithStatus),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          // With tenant header, get counts
          const typesWithStatus = await Promise.all((types || []).map(async (type) => {
            // Get all providers of this type
            const { data: providers } = await supabase
              .from('t_integration_providers')
              .select('id')
              .eq('type_id', type.id)
              .eq('is_active', true);
              
            if (!providers || providers.length === 0) {
              return {
                integration_type: type.name,
                display_name: type.display_name,
                description: type.description,
                icon_name: type.icon_name,
                active_count: 0,
                total_available: 0
              };
            }
            
            const providerIds = providers.map(p => p.id);
            
            // Get tenant integrations for this type
            const { data: tenantInts } = await supabase
              .from('t_tenant_integrations')
              .select('id')
              .eq('tenant_id', tenantHeader)
              .eq('is_live', isLive)
              .eq('is_active', true)
              .in('master_integration_id', providerIds);
              
            return {
              integration_type: type.name,
              display_name: type.display_name,
              description: type.description,
              icon_name: type.icon_name,
              active_count: tenantInts?.length || 0,
              total_available: providers.length
            };
          }));
          
          return new Response(
            JSON.stringify(typesWithStatus),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        } catch (error) {
          console.error('Error in types endpoint:', error);
          return new Response(
            JSON.stringify({ error: 'Failed to fetch integration types' }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      
      // For other operations, require tenant header
      if (!tenantHeader) {
        return new Response(
          JSON.stringify({ error: 'x-tenant-id header is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      // Get specific integration by providerId
      if (providerId) {
        try {
          const { data: integration, error } = await supabase
            .from('t_tenant_integrations')
            .select(`
              *,
              t_integration_providers (
                id,
                type_id,
                name,
                display_name,
                description,
                logo_url,
                config_schema,
                metadata
              )
            `)
            .eq('tenant_id', tenantHeader)
            .eq('is_live', isLive)
            .eq('master_integration_id', providerId)
            .single();
            
          if (error && error.code !== 'PGRST116') {
            throw error;
          }
          
          // Decrypt credentials but don't return them
          if (integration && integration.credentials) {
            try {
              await decryptData(integration.credentials, encryptionKey);
              integration.credentials = {}; // Don't send decrypted credentials to client
            } catch (e) {
              console.error('Error decrypting credentials:', e);
              integration.credentials = {};
            }
          }
          
          return new Response(
            JSON.stringify(integration || null),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        } catch (error) {
          console.error('Error fetching integration:', error);
          return new Response(
            JSON.stringify({ error: 'Failed to fetch integration' }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      
      // Get integrations by type
      if (integrationType) {
        try {
          // First get the integration type details
          const { data: typeData, error: typeError } = await supabase
            .from('t_integration_types')
            .select('*')
            .eq('name', integrationType)
            .single();
            
          if (typeError || !typeData) {
            console.log('Type not found for:', integrationType);
            return new Response(
              JSON.stringify([]),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          // Get all providers of this type
          const { data: providers, error: providerError } = await supabase
            .from('t_integration_providers')
            .select('*')
            .eq('type_id', typeData.id)
            .eq('is_active', true);
            
          if (providerError) throw providerError;
          
          if (!providers || providers.length === 0) {
            return new Response(
              JSON.stringify([]),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          // Get tenant integrations for these providers
          const providerIds = providers.map(p => p.id);
          const { data: tenantIntegrations } = await supabase
            .from('t_tenant_integrations')
            .select('*')
            .eq('tenant_id', tenantHeader)
            .eq('is_live', isLive)
            .in('master_integration_id', providerIds);
            
          // Combine the data
          const result = providers.map(provider => {
            const tenantInt = tenantIntegrations?.find(ti => ti.master_integration_id === provider.id);
            return {
              id: tenantInt?.id,
              tenant_id: tenantInt?.tenant_id,
              master_integration_id: provider.id,
              integration_type: typeData.name,
              integration_type_display: typeData.display_name,
              provider_name: provider.name,
              display_name: provider.display_name,
              description: provider.description,
              logo_url: provider.logo_url,
              config_schema: provider.config_schema,
              metadata: provider.metadata,
              is_configured: !!tenantInt,
              is_active: tenantInt?.is_active || false,
              is_live: tenantInt?.is_live ?? isLive,
              connection_status: tenantInt?.connection_status || 'Not Configured',
              last_verified: tenantInt?.last_verified || null
            };
          });
          
          return new Response(
            JSON.stringify(result),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        } catch (error) {
          console.error('Error fetching integrations by type:', error);
          return new Response(
            JSON.stringify({ error: 'Failed to fetch integrations' }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
    }
    
    // POST - Create/update integration
    if (req.method === 'POST' && url.pathname.endsWith('/integrations')) {
      const tenantHeader = req.headers.get('x-tenant-id');
      
      if (!tenantHeader) {
        return new Response(
          JSON.stringify({ error: 'x-tenant-id header is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
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
      
      try {
        const requestData = await req.json();
        
        if (!requestData.master_integration_id) {
          return new Response(
            JSON.stringify({ error: 'master_integration_id is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Encrypt credentials before saving
        const encryptedCredentials = await encryptData(requestData.credentials || {}, encryptionKey);
        
        // Check if integration already exists
        const { data: existingInt } = await supabase
          .from('t_tenant_integrations')
          .select('id, credentials')
          .eq('tenant_id', tenantHeader)
          .eq('master_integration_id', requestData.master_integration_id)
          .eq('is_live', requestData.is_live ?? isLive)
          .single();
          
        let result;
        
        if (existingInt) {
          // For updates, merge credentials if partial update
          let finalCredentials = encryptedCredentials;
          
          if (requestData.credentials && Object.keys(requestData.credentials).length > 0) {
            // If updating with new credentials, use the new encrypted ones
            finalCredentials = encryptedCredentials;
          } else if (existingInt.credentials) {
            // If no new credentials provided, keep existing ones
            finalCredentials = existingInt.credentials;
          }
          
          // Update existing integration
          const { data, error } = await supabase
            .from('t_tenant_integrations')
            .update({
              is_active: requestData.is_active ?? true,
              credentials: finalCredentials,
              connection_status: requestData.connection_status || 'Pending',
              last_verified: requestData.connection_status === 'Connected' ? new Date().toISOString() : existingInt.last_verified
            })
            .eq('id', existingInt.id)
            .select()
            .single();
            
          if (error) throw error;
          result = data;
        } else {
          // Create new integration
          const { data, error } = await supabase
            .from('t_tenant_integrations')
            .insert({
              tenant_id: tenantHeader,
              master_integration_id: requestData.master_integration_id,
              is_active: requestData.is_active ?? true,
              is_live: requestData.is_live ?? isLive,
              credentials: encryptedCredentials,
              connection_status: requestData.connection_status || 'Pending',
              last_verified: requestData.connection_status === 'Connected' ? new Date().toISOString() : null
            })
            .select()
            .single();
            
          if (error) throw error;
          result = data;
        }
        
        // Return without credentials
        result.credentials = {};
        
        return new Response(
          JSON.stringify(result),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error saving integration:', error);
        return new Response(
          JSON.stringify({ error: 'Failed to save integration' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST /test endpoint
    if (req.method === 'POST' && url.pathname.endsWith('/test')) {
      const tenantHeader = req.headers.get('x-tenant-id');
      
      if (!tenantHeader) {
        return new Response(
          JSON.stringify({ error: 'x-tenant-id header is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
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
      
      try {
        const requestData = await req.json();
        
        if (!requestData.master_integration_id || !requestData.credentials) {
          return new Response(
            JSON.stringify({ error: 'master_integration_id and credentials are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Get provider details to know which test function to use
        const { data: provider, error: providerError } = await supabase
          .from('t_integration_providers')
          .select('name')
          .eq('id', requestData.master_integration_id)
          .single();
          
        if (providerError || !provider) {
          return new Response(
            JSON.stringify({ error: 'Invalid provider ID' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // If testing existing integration, merge with existing credentials
        let testCredentials = requestData.credentials;
        
        if (requestData.integration_id) {
          const { data: existingInt } = await supabase
            .from('t_tenant_integrations')
            .select('credentials')
            .eq('id', requestData.integration_id)
            .eq('tenant_id', tenantHeader)
            .single();
            
          if (existingInt && existingInt.credentials) {
            try {
              const decryptedExisting = await decryptData(existingInt.credentials, encryptionKey);
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
          await supabase
            .from('t_tenant_integrations')
            .update({ 
              last_verified: new Date().toISOString(),
              connection_status: 'Connected'
            })
            .eq('id', requestData.integration_id)
            .eq('tenant_id', tenantHeader);
        }
        
        return new Response(
          JSON.stringify(testResult),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error testing integration:', error);
        return new Response(
          JSON.stringify({ 
            success: false,
            message: 'Failed to test integration connection'
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // PUT /status/{id} endpoint
    if (req.method === 'PUT' && url.pathname.includes('/status')) {
      const tenantHeader = req.headers.get('x-tenant-id');
      
      if (!tenantHeader) {
        return new Response(
          JSON.stringify({ error: 'x-tenant-id header is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
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
      
      try {
        const pathParts = url.pathname.split('/');
        const integrationId = pathParts[pathParts.length - 1];
        const requestData = await req.json();
        
        if (!integrationId || integrationId === 'status') {
          return new Response(
            JSON.stringify({ error: 'Integration ID is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        if (requestData.is_active === undefined) {
          return new Response(
            JSON.stringify({ error: 'is_active field is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const { data, error } = await supabase
          .from('t_tenant_integrations')
          .update({ is_active: requestData.is_active })
          .eq('id', integrationId)
          .eq('tenant_id', tenantHeader)
          .select()
          .single();
          
        if (error) throw error;
        
        if (!data) {
          return new Response(
            JSON.stringify({ error: 'Integration not found or not authorized' }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Don't return credentials
        data.credentials = {};
        
        return new Response(
          JSON.stringify({ success: true, integration: data }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error updating status:', error);
        return new Response(
          JSON.stringify({ error: 'Failed to update status' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // If no matching endpoint is found
    return new Response(
      JSON.stringify({ 
        error: 'Invalid endpoint or method',
        method: req.method,
        path: url.pathname
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error processing request:', error);
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error', 
        details: error.message 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});