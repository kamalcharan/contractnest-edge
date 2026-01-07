// supabase/functions/FKauth/index.ts
// FamilyKnows Authentication Edge Function
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createAdminClient, createAuthClient } from './utils/supabase.ts';
import { corsHeaders, handleCors } from './utils/cors.ts';

// Import all handlers
import {
  handleRegister,
  handleRegisterWithInvitation,
  handleCompleteRegistration
} from './handlers/registration.ts';
import {
  handleLogin,
  handleSignout,
  handleTokenRefresh
} from './handlers/authentication.ts';
import {
  handleResetPassword,
  handleChangePassword,
  handleVerifyPassword
} from './handlers/password.ts';
import {
  handleGetUserProfile
} from './handlers/profile.ts';
import { handleUpdatePreferences } from './handlers/preferences.ts';

serve(async (req) => {
  console.log('FKauth function called:', req.method, req.url);

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return handleCors();
  }

  try {
    // Parse URL to get the route
    const url = new URL(req.url);
    const pathParts = url.pathname.split('/').filter(Boolean);

    // Find 'FKauth' in the path and get the next part
    const authIndex = pathParts.indexOf('FKauth');
    const path = authIndex !== -1 && pathParts[authIndex + 1] ? pathParts[authIndex + 1] : '';

    console.log('Full path:', url.pathname);
    console.log('Path parts:', pathParts);
    console.log('Extracted path:', path);

    // Parse request body if present
    let data = {};
    if (req.method !== 'GET' && req.body) {
      try {
        const bodyText = await req.text();
        console.log('Raw request body:', bodyText);
        if (bodyText) {
          data = JSON.parse(bodyText);
          console.log('Parsed request data:', data);
        }
      } catch (e) {
        console.error('Error parsing request body:', e);
        return new Response(
          JSON.stringify({ error: 'Invalid JSON in request body', details: e.message }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Create Supabase clients with error handling
    let supabaseAdmin;
    try {
      console.log('Creating Supabase admin client...');
      supabaseAdmin = createAdminClient();
      console.log('Supabase admin client created successfully');
    } catch (e) {
      console.error('Error creating supabase admin client:', e);
      return new Response(
        JSON.stringify({
          error: 'Failed to initialize database connection',
          details: e.message
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const authHeader = req.headers.get('Authorization');
    console.log('Authorization header present:', !!authHeader);

    // Route to appropriate handler
    console.log(`Routing to handler for path: ${path}`);

    switch (path) {
      // Registration routes
      case 'register':
        console.log('Calling handleRegister');
        return await handleRegister(supabaseAdmin, data);

      case 'register-with-invitation':
        console.log('Calling handleRegisterWithInvitation');
        return await handleRegisterWithInvitation(supabaseAdmin, data);

      case 'complete-registration':
        console.log('Calling handleCompleteRegistration');
        return await handleCompleteRegistration(supabaseAdmin, authHeader, data);

      // Authentication routes
      case 'login':
        console.log('Calling handleLogin with data:', data);
        return await handleLogin(supabaseAdmin, data, req);

      case 'signout':
        console.log('Calling handleSignout');
        return await handleSignout(createAuthClient(authHeader));

      case 'refresh-token':
        console.log('Calling handleTokenRefresh');
        return await handleTokenRefresh(supabaseAdmin, data);

      // Password routes
      case 'reset-password':
        console.log('Calling handleResetPassword');
        return await handleResetPassword(supabaseAdmin, data);

      case 'change-password':
        console.log('Calling handleChangePassword');
        return await handleChangePassword(createAuthClient(authHeader), data);

      case 'verify-password':
        console.log('Calling handleVerifyPassword');
        return await handleVerifyPassword(supabaseAdmin, authHeader, data);

      // Profile routes
      case 'user':
        console.log('Calling handleGetUserProfile');
        return await handleGetUserProfile(supabaseAdmin, authHeader, req);

      // Preferences route
      case 'preferences':
        console.log('Calling handleUpdatePreferences');
        return await handleUpdatePreferences(supabaseAdmin, authHeader, data, req);

      // 404 for unknown routes
      default:
        console.error('Unknown FKauth route:', path);
        return new Response(
          JSON.stringify({
            error: `Unknown FKauth route: ${path}`,
            availableRoutes: [
              'register',
              'register-with-invitation',
              'complete-registration',
              'login',
              'signout',
              'refresh-token',
              'reset-password',
              'change-password',
              'verify-password',
              'user',
              'preferences'
            ]
          }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
    }
  } catch (error: any) {
    console.error('=== ERROR IN FKAUTH FUNCTION ===');
    console.error('Error type:', error.constructor.name);
    console.error('Error message:', error.message);
    console.error('Error stack:', error.stack);
    console.error('================================');

    return new Response(
      JSON.stringify({
        error: error.message || 'Internal server error',
        type: error.constructor.name
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
