import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

interface TestResult {
  name: string;
  success: boolean;
  message: string;
  timestamp: string;
}

serve(async (req: Request) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Get auth header
    const authHeader = req.headers.get('Authorization');
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Authentication validation
    // Admin role validation is assumed to have been done by the API middleware
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    if (!supabaseUrl || !supabaseKey) {
      return new Response(
        JSON.stringify({ error: 'Supabase configuration missing' }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Get Firebase configuration from environment variables
    const firebaseConfig = {
      apiKey: Deno.env.get('FIREBASE_API_KEY'),
      authDomain: Deno.env.get('FIREBASE_AUTH_DOMAIN'),
      projectId: Deno.env.get('FIREBASE_PROJECT_ID'),
      storageBucket: Deno.env.get('FIREBASE_STORAGE_BUCKET'),
      messagingSenderId: Deno.env.get('FIREBASE_MESSAGING_SENDER_ID'),
      appId: Deno.env.get('FIREBASE_APP_ID')
    };

    // Check Firebase configuration
    const missingFirebaseConfig = Object.entries(firebaseConfig)
      .filter(([_, value]) => !value)
      .map(([key]) => key);

    // Get request type from URL parameters
    const url = new URL(req.url);
    const testType = url.searchParams.get('test') || 'configuration';
    
    // Parse the request body if this is a POST request
    let testRequest = {};
    if (req.method === 'POST') {
      try {
        testRequest = await req.json();
      } catch (e) {
        // If JSON parsing fails, continue with empty test request
        console.error("Error parsing request body:", e);
      }
    }

    // Initialize test results
    const results: TestResult[] = [];
    
    // Configuration test is always performed
    results.push({
      name: 'Firebase Configuration',
      success: missingFirebaseConfig.length === 0,
      message: missingFirebaseConfig.length === 0 
        ? 'All Firebase configuration variables are set'
        : `Missing configuration: ${missingFirebaseConfig.join(', ')}`,
      timestamp: new Date().toISOString()
    });

    // Prepare diagnostic response
    const diagnosticData = {
      timestamp: new Date().toISOString(),
      environment: {
        supabaseUrl: supabaseUrl ? 'Set' : 'Not set',
        supabaseKey: supabaseKey ? 'Set' : 'Not set',
        firebase: missingFirebaseConfig.length === 0 ? 'Complete' : `Missing: ${missingFirebaseConfig.join(', ')}`,
        encryptionKey: Deno.env.get('ENCRYPTION_KEY') ? 'Set' : 'Not set',
        nodeEnv: Deno.env.get('NODE_ENV') || 'Not set',
        region: Deno.env.get('REGION') || 'Not set'
      },
      firebase: {
        configured: missingFirebaseConfig.length === 0,
        missingConfig: missingFirebaseConfig.length > 0 ? missingFirebaseConfig : null,
        storageBucket: Deno.env.get('FIREBASE_STORAGE_BUCKET') || 'Not set'
      },
      request: {
        headers: Object.fromEntries(
          [...req.headers.entries()].filter(([key]) => 
            !['authorization', 'cookie'].includes(key.toLowerCase())
          )
        ),
        test: testType
      },
      results: results
    };

    // Run specific tests if requested
    switch(testType) {
      case 'configuration':
        // Just return the config status (already included in diagnosticData)
        break;
      case 'environment':
        // Already added environment variables status above
        break;
      case 'storage':
        // Add storage-specific data
        diagnosticData.firebase.storage = {
          test: 'Simulated storage test',
          status: 'This is a simulated test. Actual storage tests need to be performed client-side.',
          testTime: new Date().toISOString(),
        };
        
        results.push({
          name: 'Storage Configuration',
          success: !!firebaseConfig.storageBucket,
          message: firebaseConfig.storageBucket 
            ? `Storage bucket configured: ${firebaseConfig.storageBucket}`
            : 'Storage bucket not configured',
          timestamp: new Date().toISOString()
        });
        
        break;
      default:
        // Unknown test type
        results.push({
          name: 'Unknown Test',
          success: false,
          message: `Unknown test type: ${testType}`,
          timestamp: new Date().toISOString()
        });
    }

    return new Response(
      JSON.stringify({
        message: 'Firebase diagnostic information',
        status: 'success',
        data: diagnosticData
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      }
    );
  } catch (error) {
    console.error('Firebase diagnostic error:', error);
    
    return new Response(
      JSON.stringify({ 
        status: 'error',
        error: error instanceof Error ? error.message : String(error),
        timestamp: new Date().toISOString()
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 500 
      }
    );
  }
});

    // Get Firebase configuration from environment variables
    const firebaseConfig = {
      apiKey: Deno.env.get('FIREBASE_API_KEY'),
      authDomain: Deno.env.get('FIREBASE_AUTH_DOMAIN'),
      projectId: Deno.env.get('FIREBASE_PROJECT_ID'),
      storageBucket: Deno.env.get('FIREBASE_STORAGE_BUCKET'),
      messagingSenderId: Deno.env.get('FIREBASE_MESSAGING_SENDER_ID'),
      appId: Deno.env.get('FIREBASE_APP_ID')
    };

    // Check Firebase configuration
    const missingFirebaseConfig = Object.entries(firebaseConfig)
      .filter(([_, value]) => !value)
      .map(([key]) => key);

    // Get request type from URL parameters
    const url = new URL(req.url);
    const testType = url.searchParams.get('test');

    // Prepare diagnostic response
    const diagnosticData = {
      timestamp: new Date().toISOString(),
      environment: {
        supabaseUrl: supabaseUrl ? 'Set' : 'Not set',
        supabaseKey: supabaseKey ? 'Set' : 'Not set',
        firebase: missingFirebaseConfig.length === 0 ? 'Complete' : `Missing: ${missingFirebaseConfig.join(', ')}`,
      },
      firebase: {
        configured: missingFirebaseConfig.length === 0,
        missingConfig: missingFirebaseConfig.length > 0 ? missingFirebaseConfig : null,
        storageBucket: Deno.env.get('FIREBASE_STORAGE_BUCKET') || 'Not set'
      },
      request: {
        headers: Object.fromEntries(
          [...req.headers.entries()].filter(([key]) => 
            !['authorization', 'cookie'].includes(key.toLowerCase())
          )
        ),
        test: testType || 'None'
      }
    };

    // Run specific tests if requested
    if (testType) {
      switch(testType) {
        case 'config':
          // Just return the config status (already included in diagnosticData)
          break;
        case 'environment':
          // Add more environment variables status
          diagnosticData.environment = {
            ...diagnosticData.environment,
            encryptionKey: Deno.env.get('ENCRYPTION_KEY') ? 'Set' : 'Not set',
            nodeEnv: Deno.env.get('NODE_ENV') || 'Not set',
            region: Deno.env.get('REGION') || 'Not set'
          };
          break;
        default:
          throw new Error(`Unknown test type: ${testType}`);
      }
    }

    return new Response(
      JSON.stringify({
        message: 'Firebase diagnostic information',
        status: 'success',
        data: diagnosticData
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      }
    );
  } catch (error) {
    console.error('Firebase diagnostic error:', error);
    
    return new Response(
      JSON.stringify({ 
        status: 'error',
        error: error instanceof Error ? error.message : String(error),
        timestamp: new Date().toISOString()
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }, 
        status: 500 
      }
    );
  }
});