// supabase/functions/onboarding/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS'
};

// Rate limiting storage (in-memory for Edge functions)
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Environment validation
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');
    
    if (!supabaseUrl || !supabaseKey) {
      console.error('Missing environment variables');
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Extract headers
    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    const idempotencyKey = req.headers.get('idempotency-key');
    
    // Basic validation
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (!tenantId) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Verify internal signature for write operations
    if (internalSignature && internalSecret && req.method !== 'GET') {
      const requestBody = await req.clone().text();
      const isValidSignature = await verifyInternalSignature(requestBody, internalSignature, internalSecret);
      
      if (!isValidSignature) {
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Rate limiting check
    const rateLimitResult = await checkRateLimit(tenantId);
    if (!rateLimitResult.allowed) {
      return new Response(
        JSON.stringify({ 
          error: 'Rate limit exceeded',
          retryAfter: Math.ceil((rateLimitResult.resetTime - Date.now()) / 1000)
        }),
        { 
          status: 429, 
          headers: { 
            ...corsHeaders, 
            'Content-Type': 'application/json',
            'Retry-After': Math.ceil((rateLimitResult.resetTime - Date.now()) / 1000).toString()
          } 
        }
      );
    }
    
    // Create Supabase client with the user's token for RLS
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { 
        headers: { 
          Authorization: authHeader  // This ensures RLS uses the user's context
        } 
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    // Parse URL and route
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];
    
    // Route handling
    switch (req.method) {
      case 'GET':
        if (lastSegment === 'status' || pathSegments.includes('status')) {
          return await handleGetStatus(supabase, tenantId);
        }
        break;
        
      case 'POST':
        if (lastSegment === 'initialize' || pathSegments.includes('initialize')) {
          return await handleInitialize(supabase, tenantId);
        }
        if (lastSegment === 'complete-step' || pathSegments.includes('complete-step')) {
          const body = await req.json();
          return await handleCompleteStep(supabase, tenantId, body, idempotencyKey);
        }
        if (lastSegment === 'complete' || pathSegments.includes('complete')) {
          return await handleCompleteOnboarding(supabase, tenantId);
        }
        break;
        
      case 'PUT':
        if (lastSegment === 'skip-step' || pathSegments.includes('skip-step')) {
          const body = await req.json();
          return await handleSkipStep(supabase, tenantId, body);
        }
        if (lastSegment === 'update-progress' || pathSegments.includes('update-progress')) {
          const body = await req.json();
          return await handleUpdateProgress(supabase, tenantId, body);
        }
        break;
    }
    
    // Invalid endpoint
    return new Response(
      JSON.stringify({ 
        error: 'Invalid endpoint',
        availableEndpoints: [
          'GET /status',
          'POST /initialize',
          'POST /complete-step',
          'PUT /skip-step',
          'PUT /update-progress',
          'POST /complete'
        ]
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error: any) {
    console.error('Onboarding edge function error:', error);
    
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error',
        message: error.message,
        requestId: crypto.randomUUID()
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// ==========================================
// REQUEST HANDLERS
// ==========================================

async function handleGetStatus(supabase: any, tenantId: string) {
  try {
    console.log(`Getting onboarding status for tenant: ${tenantId}`);

    // Fetch main onboarding record - handle no record case
    const { data: onboardingData, error: onboardingError } = await supabase
      .from('t_tenant_onboarding')
      .select('*')
      .eq('tenant_id', tenantId);

    if (onboardingError) {
      throw new Error(`Failed to fetch onboarding: ${onboardingError.message}`);
    }

    const onboarding = onboardingData && onboardingData.length > 0 ? onboardingData[0] : null;

    // Fetch step statuses
    const { data: stepData, error: stepsError } = await supabase
      .from('t_onboarding_step_status')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('step_sequence', { ascending: true });

    if (stepsError) {
      throw new Error(`Failed to fetch steps: ${stepsError.message}`);
    }

    // Fetch owner info from tenant (for non-owners to see who to contact)
    let owner = null;
    try {
      const { data: tenantData } = await supabase
        .from('t_tenants')
        .select('created_by')
        .eq('id', tenantId)
        .single();

      if (tenantData?.created_by) {
        const { data: ownerProfile } = await supabase
          .from('t_user_profiles')
          .select('first_name, last_name, email')
          .eq('user_id', tenantData.created_by)
          .single();

        if (ownerProfile) {
          owner = {
            name: `${ownerProfile.first_name || ''} ${ownerProfile.last_name || ''}`.trim(),
            email: ownerProfile.email
          };
        }
      }
    } catch (ownerError) {
      console.warn('Could not fetch owner info:', ownerError);
      // Non-fatal - continue without owner info
    }

    // Transform step data for frontend
    const steps: any = {};
    if (stepData && stepData.length > 0) {
      stepData.forEach((step: any) => {
        steps[step.step_id] = {
          id: step.step_id,
          sequence: step.step_sequence,
          status: step.status,
          is_completed: step.status === 'completed',
          is_skipped: step.status === 'skipped',
          completed_at: step.completed_at,
          updated_at: step.updated_at
        };
      });
    }

    const response = {
      needs_onboarding: !onboarding?.is_completed,
      owner: owner,  // Owner info for non-owners to see who to contact
      data: {
        is_complete: onboarding?.is_completed || false,
        current_step: onboarding?.current_step || 1,
        total_steps: onboarding?.total_steps || 6,
        completed_steps: onboarding?.completed_steps || [],
        skipped_steps: onboarding?.skipped_steps || [],
        step_data: onboarding?.step_data || {},
        steps: steps
      }
    };

    return new Response(
      JSON.stringify(response),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetStatus:', error);
    throw error;
  }
}

async function handleInitialize(supabase: any, tenantId: string) {
  try {
    console.log(`Initializing onboarding for tenant: ${tenantId}`);
    
    // Check if already exists
    const { data: existingData } = await supabase
      .from('t_tenant_onboarding')
      .select('id, is_completed')
      .eq('tenant_id', tenantId);
    
    if (existingData && existingData.length > 0) {
      return new Response(
        JSON.stringify({ 
          message: 'Onboarding already initialized',
          id: existingData[0].id,
          is_completed: existingData[0].is_completed
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Create onboarding record
    const { data: onboarding, error: createError } = await supabase
      .from('t_tenant_onboarding')
      .insert({
        tenant_id: tenantId,
        onboarding_type: 'business',
        total_steps: 6,
        current_step: 1,
        completed_steps: [],
        skipped_steps: [],
        step_data: {},
        is_completed: false
      })
      .select()
      .single();
      
    if (createError) {
      throw new Error(`Failed to create onboarding: ${createError.message}`);
    }
    
    // Create step records
    const steps = [
      { tenant_id: tenantId, step_id: 'user-profile', step_sequence: 1, status: 'pending' },
      { tenant_id: tenantId, step_id: 'business-profile', step_sequence: 2, status: 'pending' },
      { tenant_id: tenantId, step_id: 'data-setup', step_sequence: 3, status: 'pending' },
      { tenant_id: tenantId, step_id: 'storage', step_sequence: 4, status: 'pending' },
      { tenant_id: tenantId, step_id: 'team', step_sequence: 5, status: 'pending' },
      { tenant_id: tenantId, step_id: 'tour', step_sequence: 6, status: 'pending' }
    ];
    
    const { error: stepsError } = await supabase
      .from('t_onboarding_step_status')
      .insert(steps);
      
    if (stepsError) {
      console.error('Error creating steps:', stepsError);
      // Non-fatal, steps might already exist from trigger
    }
    
    return new Response(
      JSON.stringify({
        id: onboarding.id,
        message: 'Onboarding initialized successfully'
      }),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleInitialize:', error);
    throw error;
  }
}

async function handleCompleteStep(supabase: any, tenantId: string, body: any, idempotencyKey: string | null) {
  try {
    const { stepId, data } = body;
    
    if (!stepId) {
      return new Response(
        JSON.stringify({ error: 'stepId is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    console.log(`Completing step ${stepId} for tenant: ${tenantId}`);
    
    // Update step status
    const { error: stepError } = await supabase
      .from('t_onboarding_step_status')
      .update({ 
        status: 'completed',
        completed_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq('tenant_id', tenantId)
      .eq('step_id', stepId);
      
    if (stepError) {
      throw new Error(`Failed to update step: ${stepError.message}`);
    }
    
    // Get or create onboarding record
    let onboarding;
    const { data: onboardingData, error: fetchError } = await supabase
      .from('t_tenant_onboarding')
      .select('*')
      .eq('tenant_id', tenantId);
      
    if (fetchError) {
      throw new Error(`Failed to fetch onboarding: ${fetchError.message}`);
    }
    
    if (!onboardingData || onboardingData.length === 0) {
      // No onboarding record exists - likely a legacy tenant
      console.log(`No onboarding record found for tenant ${tenantId}, initializing for legacy tenant`);
      
      // Auto-initialize for legacy tenants
      const { data: newOnboarding, error: createError } = await supabase
        .from('t_tenant_onboarding')
        .insert({
          tenant_id: tenantId,
          onboarding_type: 'business',
          total_steps: 6,
          current_step: 1,
          completed_steps: [],
          skipped_steps: [],
          step_data: {},
          is_completed: false
        })
        .select()
        .single();
        
      if (createError) {
        // If insert fails due to RLS, it means we can't auto-create
        // This could happen if the user doesn't have proper permissions
        console.error(`Failed to auto-initialize onboarding: ${createError.message}`);
        throw new Error('Onboarding not initialized. Please contact support.');
      }
      
      onboarding = newOnboarding;
      
      // Also create the step records for legacy tenant
      const steps = [
        { tenant_id: tenantId, step_id: 'user-profile', step_sequence: 1, status: 'pending' },
        { tenant_id: tenantId, step_id: 'business-profile', step_sequence: 2, status: 'pending' },
        { tenant_id: tenantId, step_id: 'data-setup', step_sequence: 3, status: 'pending' },
        { tenant_id: tenantId, step_id: 'storage', step_sequence: 4, status: 'pending' },
        { tenant_id: tenantId, step_id: 'team', step_sequence: 5, status: 'pending' },
        { tenant_id: tenantId, step_id: 'tour', step_sequence: 6, status: 'pending' }
      ];
      
      await supabase
        .from('t_onboarding_step_status')
        .insert(steps);
      
      console.log('Successfully initialized onboarding for legacy tenant');
    } else {
      onboarding = onboardingData[0];
    }
    
    // Update main onboarding record
    const completedSteps = [...(onboarding.completed_steps || [])];
    if (!completedSteps.includes(stepId)) {
      completedSteps.push(stepId);
    }
    
    const stepData = { ...(onboarding.step_data || {}), [stepId]: data };
    const nextStep = onboarding.current_step < onboarding.total_steps 
      ? onboarding.current_step + 1 
      : onboarding.current_step;
    
    // Check if all required steps are completed
    const requiredSteps = ['user-profile', 'business-profile'];
    const allRequiredComplete = requiredSteps.every(step => completedSteps.includes(step));
    
    const { error: updateError } = await supabase
      .from('t_tenant_onboarding')
      .update({
        completed_steps: completedSteps,
        step_data: stepData,
        current_step: nextStep,
        is_completed: completedSteps.length >= onboarding.total_steps || allRequiredComplete,
        completed_at: (completedSteps.length >= onboarding.total_steps || allRequiredComplete) 
          ? new Date().toISOString() 
          : null,
        updated_at: new Date().toISOString()
      })
      .eq('tenant_id', tenantId);
      
    if (updateError) {
      throw new Error(`Failed to update onboarding: ${updateError.message}`);
    }
    
    return new Response(
      JSON.stringify({ 
        success: true,
        message: `Step ${stepId} completed`,
        current_step: nextStep,
        completed_steps: completedSteps,
        is_complete: completedSteps.length >= onboarding.total_steps || allRequiredComplete
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCompleteStep:', error);
    throw error;
  }
}

async function handleSkipStep(supabase: any, tenantId: string, body: any) {
  try {
    const { stepId } = body;
    
    if (!stepId) {
      return new Response(
        JSON.stringify({ error: 'stepId is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if step is required
    const requiredSteps = ['user-profile', 'business-profile'];
    if (requiredSteps.includes(stepId)) {
      return new Response(
        JSON.stringify({ error: `Cannot skip required step: ${stepId}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    console.log(`Skipping step ${stepId} for tenant: ${tenantId}`);
    
    // Update step status
    const { error: stepError } = await supabase
      .from('t_onboarding_step_status')
      .update({ 
        status: 'skipped',
        updated_at: new Date().toISOString()
      })
      .eq('tenant_id', tenantId)
      .eq('step_id', stepId);
      
    if (stepError) {
      throw new Error(`Failed to update step: ${stepError.message}`);
    }
    
    // Get or create onboarding record
    let onboarding;
    const { data: onboardingData, error: fetchError } = await supabase
      .from('t_tenant_onboarding')
      .select('*')
      .eq('tenant_id', tenantId);
      
    if (fetchError) {
      throw new Error(`Failed to fetch onboarding: ${fetchError.message}`);
    }
    
    if (!onboardingData || onboardingData.length === 0) {
      // Create onboarding record if it doesn't exist
      const { data: newOnboarding, error: createError } = await supabase
        .from('t_tenant_onboarding')
        .insert({
          tenant_id: tenantId,
          onboarding_type: 'business',
          total_steps: 6,
          current_step: 1,
          completed_steps: [],
          skipped_steps: [],
          step_data: {},
          is_completed: false
        })
        .select()
        .single();
        
      if (createError) {
        throw new Error(`Failed to create onboarding: ${createError.message}`);
      }
      
      onboarding = newOnboarding;
    } else {
      onboarding = onboardingData[0];
    }
    
    const skippedSteps = [...(onboarding.skipped_steps || [])];
    if (!skippedSteps.includes(stepId)) {
      skippedSteps.push(stepId);
    }
    
    const nextStep = onboarding.current_step < onboarding.total_steps 
      ? onboarding.current_step + 1 
      : onboarding.current_step;
    
    const { error: updateError } = await supabase
      .from('t_tenant_onboarding')
      .update({
        skipped_steps: skippedSteps,
        current_step: nextStep,
        updated_at: new Date().toISOString()
      })
      .eq('tenant_id', tenantId);
      
    if (updateError) {
      throw new Error(`Failed to update onboarding: ${updateError.message}`);
    }
    
    return new Response(
      JSON.stringify({ 
        success: true,
        message: `Step ${stepId} skipped`,
        current_step: nextStep,
        skipped_steps: skippedSteps
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleSkipStep:', error);
    throw error;
  }
}

async function handleUpdateProgress(supabase: any, tenantId: string, body: any) {
  try {
    const { current_step, step_data } = body;
    
    console.log(`Updating progress for tenant: ${tenantId}`);
    
    // First check if onboarding exists
    const { data: onboardingData } = await supabase
      .from('t_tenant_onboarding')
      .select('*')
      .eq('tenant_id', tenantId);
    
    if (!onboardingData || onboardingData.length === 0) {
      // Create if doesn't exist
      const { error: createError } = await supabase
        .from('t_tenant_onboarding')
        .insert({
          tenant_id: tenantId,
          onboarding_type: 'business',
          total_steps: 6,
          current_step: current_step || 1,
          completed_steps: [],
          skipped_steps: [],
          step_data: step_data || {},
          is_completed: false
        });
        
      if (createError) {
        throw new Error(`Failed to create onboarding: ${createError.message}`);
      }
      
      return new Response(
        JSON.stringify({ 
          success: true,
          message: 'Progress initialized and updated'
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    const onboarding = onboardingData[0];
    const updateData: any = {
      updated_at: new Date().toISOString()
    };
    
    if (current_step !== undefined) {
      updateData.current_step = current_step;
    }
    
    if (step_data !== undefined) {
      updateData.step_data = { ...(onboarding.step_data || {}), ...step_data };
    }
    
    const { error } = await supabase
      .from('t_tenant_onboarding')
      .update(updateData)
      .eq('tenant_id', tenantId);
      
    if (error) {
      throw new Error(`Failed to update progress: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify({ 
        success: true,
        message: 'Progress updated'
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleUpdateProgress:', error);
    throw error;
  }
}

async function handleCompleteOnboarding(supabase: any, tenantId: string) {
  try {
    console.log(`Completing onboarding for tenant: ${tenantId}`);
    
    const { error } = await supabase
      .from('t_tenant_onboarding')
      .update({
        is_completed: true,
        completed_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq('tenant_id', tenantId);
      
    if (error) {
      throw new Error(`Failed to complete onboarding: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify({ 
        success: true,
        message: 'Onboarding completed successfully'
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCompleteOnboarding:', error);
    throw error;
  }
}

// ==========================================
// UTILITY FUNCTIONS
// ==========================================

async function verifyInternalSignature(body: string, signature: string, secret: string): Promise<boolean> {
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

async function checkRateLimit(tenantId: string): Promise<{
  allowed: boolean;
  limit: number;
  remaining: number;
  resetTime: number;
}> {
  const key = tenantId;
  const now = Date.now();
  const windowMs = 60000; // 1 minute window
  const maxRequests = 100; // 100 requests per minute
  
  // Clean up expired entries
  for (const [cacheKey, value] of rateLimitStore.entries()) {
    if (now > value.resetTime) {
      rateLimitStore.delete(cacheKey);
    }
  }
  
  const current = rateLimitStore.get(key) || { count: 0, resetTime: now + windowMs };
  
  if (now > current.resetTime) {
    current.count = 0;
    current.resetTime = now + windowMs;
  }
  
  current.count++;
  rateLimitStore.set(key, current);
  
  return {
    allowed: current.count <= maxRequests,
    limit: maxRequests,
    remaining: Math.max(0, maxRequests - current.count),
    resetTime: current.resetTime
  };
}