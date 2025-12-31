// supabase/functions/FKonboarding/index.ts
// FamilyKnows Onboarding Edge Function
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS'
};

// FamilyKnows Onboarding Steps Configuration
const FK_ONBOARDING_CONFIG = {
  type: 'family',
  totalSteps: 6,
  steps: [
    { step_id: 'personal-profile', step_sequence: 1, required: true },
    { step_id: 'theme', step_sequence: 2, required: true, default_value: 'light' },
    { step_id: 'language', step_sequence: 3, required: true, default_value: 'en' },
    { step_id: 'family-space', step_sequence: 4, required: true },
    { step_id: 'storage', step_sequence: 5, required: false },
    { step_id: 'family-invite', step_sequence: 6, required: false }
  ],
  requiredSteps: ['personal-profile', 'theme', 'language', 'family-space']
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
          Authorization: authHeader
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
        if (lastSegment === 'config' || pathSegments.includes('config')) {
          return await handleGetConfig();
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
          'GET /config',
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
    console.error('FKonboarding edge function error:', error);

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

async function handleGetConfig() {
  // Return the onboarding configuration for the mobile app
  return new Response(
    JSON.stringify({
      type: FK_ONBOARDING_CONFIG.type,
      total_steps: FK_ONBOARDING_CONFIG.totalSteps,
      steps: FK_ONBOARDING_CONFIG.steps.map(s => ({
        id: s.step_id,
        sequence: s.step_sequence,
        required: s.required,
        default_value: (s as any).default_value || null
      })),
      required_steps: FK_ONBOARDING_CONFIG.requiredSteps
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

async function handleGetStatus(supabase: any, tenantId: string) {
  try {
    console.log(`Getting FK onboarding status for tenant: ${tenantId}`);

    // Fetch main onboarding record
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

    // Fetch owner info
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
    }

    // Transform step data for frontend
    const steps: any = {};
    if (stepData && stepData.length > 0) {
      stepData.forEach((step: any) => {
        const configStep = FK_ONBOARDING_CONFIG.steps.find(s => s.step_id === step.step_id);
        steps[step.step_id] = {
          id: step.step_id,
          sequence: step.step_sequence,
          status: step.status,
          is_completed: step.status === 'completed',
          is_skipped: step.status === 'skipped',
          is_required: configStep?.required || false,
          default_value: (configStep as any)?.default_value || null,
          completed_at: step.completed_at,
          updated_at: step.updated_at
        };
      });
    }

    const response = {
      needs_onboarding: !onboarding?.is_completed,
      owner: owner,
      config: {
        type: FK_ONBOARDING_CONFIG.type,
        required_steps: FK_ONBOARDING_CONFIG.requiredSteps
      },
      data: {
        is_complete: onboarding?.is_completed || false,
        current_step: onboarding?.current_step || 1,
        total_steps: onboarding?.total_steps || FK_ONBOARDING_CONFIG.totalSteps,
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
    console.log(`Initializing FK onboarding for tenant: ${tenantId}`);

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

    // Create onboarding record with FamilyKnows configuration
    const { data: onboarding, error: createError } = await supabase
      .from('t_tenant_onboarding')
      .insert({
        tenant_id: tenantId,
        onboarding_type: FK_ONBOARDING_CONFIG.type,
        total_steps: FK_ONBOARDING_CONFIG.totalSteps,
        current_step: 1,
        completed_steps: [],
        skipped_steps: [],
        step_data: {
          // Set default values for steps that have them
          theme: { value: 'light', is_dark_mode: false },
          language: { value: 'en' }
        },
        is_completed: false
      })
      .select()
      .single();

    if (createError) {
      throw new Error(`Failed to create onboarding: ${createError.message}`);
    }

    // Create step records with FamilyKnows steps
    const steps = FK_ONBOARDING_CONFIG.steps.map(step => ({
      tenant_id: tenantId,
      step_id: step.step_id,
      step_sequence: step.step_sequence,
      status: 'pending'
    }));

    const { error: stepsError } = await supabase
      .from('t_onboarding_step_status')
      .insert(steps);

    if (stepsError) {
      console.error('Error creating steps:', stepsError);
      // Non-fatal, continue
    }

    return new Response(
      JSON.stringify({
        id: onboarding.id,
        message: 'FamilyKnows onboarding initialized successfully',
        config: {
          type: FK_ONBOARDING_CONFIG.type,
          total_steps: FK_ONBOARDING_CONFIG.totalSteps,
          required_steps: FK_ONBOARDING_CONFIG.requiredSteps
        }
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

    // Validate step exists in FK config
    const stepConfig = FK_ONBOARDING_CONFIG.steps.find(s => s.step_id === stepId);
    if (!stepConfig) {
      return new Response(
        JSON.stringify({ error: `Invalid step: ${stepId}. Valid steps: ${FK_ONBOARDING_CONFIG.steps.map(s => s.step_id).join(', ')}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`Completing FK step ${stepId} for tenant: ${tenantId}`);

    // Handle step-specific data updates
    await handleStepDataUpdate(supabase, tenantId, stepId, data);

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
      // Auto-initialize for this tenant
      console.log(`No onboarding record found for tenant ${tenantId}, auto-initializing`);

      const { data: newOnboarding, error: createError } = await supabase
        .from('t_tenant_onboarding')
        .insert({
          tenant_id: tenantId,
          onboarding_type: FK_ONBOARDING_CONFIG.type,
          total_steps: FK_ONBOARDING_CONFIG.totalSteps,
          current_step: 1,
          completed_steps: [],
          skipped_steps: [],
          step_data: {},
          is_completed: false
        })
        .select()
        .single();

      if (createError) {
        console.error(`Failed to auto-initialize onboarding: ${createError.message}`);
        throw new Error('Onboarding not initialized. Please try again.');
      }

      onboarding = newOnboarding;

      // Create step records
      const steps = FK_ONBOARDING_CONFIG.steps.map(step => ({
        tenant_id: tenantId,
        step_id: step.step_id,
        step_sequence: step.step_sequence,
        status: step.step_id === stepId ? 'completed' : 'pending'
      }));

      await supabase
        .from('t_onboarding_step_status')
        .insert(steps);

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
    const allRequiredComplete = FK_ONBOARDING_CONFIG.requiredSteps.every(
      step => completedSteps.includes(step)
    );

    const isComplete = allRequiredComplete;

    const { error: updateError } = await supabase
      .from('t_tenant_onboarding')
      .update({
        completed_steps: completedSteps,
        step_data: stepData,
        current_step: nextStep,
        is_completed: isComplete,
        completed_at: isComplete ? new Date().toISOString() : null,
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
        is_complete: isComplete,
        all_required_complete: allRequiredComplete
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCompleteStep:', error);
    throw error;
  }
}

// Handle step-specific data updates to respective tables
async function handleStepDataUpdate(supabase: any, tenantId: string, stepId: string, data: any) {
  if (!data) return;

  try {
    switch (stepId) {
      case 'personal-profile':
        // Update t_user_profiles with personal data
        if (data.user_id) {
          const profileUpdate: any = {};
          if (data.first_name) profileUpdate.first_name = data.first_name;
          if (data.last_name) profileUpdate.last_name = data.last_name;
          if (data.date_of_birth) profileUpdate.date_of_birth = data.date_of_birth;
          if (data.gender) profileUpdate.gender = data.gender;
          if (data.country_code) profileUpdate.country_code = data.country_code;
          if (data.mobile_number) profileUpdate.mobile_number = data.mobile_number;

          if (Object.keys(profileUpdate).length > 0) {
            profileUpdate.updated_at = new Date().toISOString();
            await supabase
              .from('t_user_profiles')
              .update(profileUpdate)
              .eq('user_id', data.user_id);
          }
        }
        break;

      case 'theme':
        // Update t_user_profiles with theme preference
        if (data.user_id) {
          await supabase
            .from('t_user_profiles')
            .update({
              preferred_theme: data.theme || data.value || 'light',
              is_dark_mode: data.is_dark_mode || false,
              updated_at: new Date().toISOString()
            })
            .eq('user_id', data.user_id);
        }
        break;

      case 'language':
        // Update t_user_profiles with language preference
        if (data.user_id) {
          await supabase
            .from('t_user_profiles')
            .update({
              preferred_language: data.language || data.value || 'en',
              updated_at: new Date().toISOString()
            })
            .eq('user_id', data.user_id);
        }
        break;

      case 'family-space':
        // Update t_tenants with family space name
        if (data.name) {
          await supabase
            .from('t_tenants')
            .update({
              name: data.name,
              updated_at: new Date().toISOString()
            })
            .eq('id', tenantId);
        }
        break;

      case 'storage':
        // Storage setup - placeholder for future implementation
        console.log('Storage step data:', data);
        break;

      case 'family-invite':
        // Family invite - handled separately via invitation system
        console.log('Family invite step data:', data);
        break;
    }
  } catch (error) {
    console.error(`Error updating data for step ${stepId}:`, error);
    // Non-fatal - continue with step completion
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

    // Check if step is required (cannot skip required steps)
    if (FK_ONBOARDING_CONFIG.requiredSteps.includes(stepId)) {
      return new Response(
        JSON.stringify({ error: `Cannot skip required step: ${stepId}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`Skipping FK step ${stepId} for tenant: ${tenantId}`);

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

    // Get onboarding record
    const { data: onboardingData, error: fetchError } = await supabase
      .from('t_tenant_onboarding')
      .select('*')
      .eq('tenant_id', tenantId);

    if (fetchError) {
      throw new Error(`Failed to fetch onboarding: ${fetchError.message}`);
    }

    if (!onboardingData || onboardingData.length === 0) {
      return new Response(
        JSON.stringify({ error: 'Onboarding not initialized' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const onboarding = onboardingData[0];

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

    console.log(`Updating FK progress for tenant: ${tenantId}`);

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
          onboarding_type: FK_ONBOARDING_CONFIG.type,
          total_steps: FK_ONBOARDING_CONFIG.totalSteps,
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
    console.log(`Completing FK onboarding for tenant: ${tenantId}`);

    // Verify all required steps are completed
    const { data: onboardingData } = await supabase
      .from('t_tenant_onboarding')
      .select('completed_steps')
      .eq('tenant_id', tenantId)
      .single();

    if (onboardingData) {
      const completedSteps = onboardingData.completed_steps || [];
      const missingRequired = FK_ONBOARDING_CONFIG.requiredSteps.filter(
        step => !completedSteps.includes(step)
      );

      if (missingRequired.length > 0) {
        return new Response(
          JSON.stringify({
            error: 'Cannot complete onboarding. Missing required steps.',
            missing_steps: missingRequired
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

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
        message: 'FamilyKnows onboarding completed successfully'
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
