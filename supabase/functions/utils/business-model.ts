// /supabase/functions/utils/business-model.ts

/**
 * Business Model Utilities - Simplified Version Management
 */

/**
 * Validates plan data for creation or update
 */
export function validatePlanData(planData: any, isUpdate = false): { valid: boolean; errors?: string[] } {
  const errors: string[] = [];
  
  if (!isUpdate) {
    if (!planData.name) {
      errors.push('Plan name is required');
    }
    
    if (!planData.plan_type) {
      errors.push('Plan type is required');
    } else if (!['Per User', 'Per Contract'].includes(planData.plan_type)) {
      errors.push('Plan type must be "Per User" or "Per Contract"');
    }
    
    if (!planData.default_currency_code) {
      errors.push('Default currency code is required');
    }
    
    if (!planData.supported_currencies || !Array.isArray(planData.supported_currencies) || planData.supported_currencies.length === 0) {
      errors.push('At least one supported currency is required');
    }
  }
  
  if (planData.default_currency_code && planData.supported_currencies) {
    if (!planData.supported_currencies.includes(planData.default_currency_code)) {
      errors.push('Default currency must be included in supported currencies');
    }
  }
  
  if (planData.trial_duration !== undefined) {
    if (typeof planData.trial_duration !== 'number' || planData.trial_duration < 0) {
      errors.push('Trial duration must be a non-negative number');
    }
  }
  
  return {
    valid: errors.length === 0,
    errors: errors.length > 0 ? errors : undefined
  };
}

/**
 * Validates version data for creation
 * ENHANCED: Now checks currency consistency when supported_currencies is provided
 */
export function validateVersionData(versionData: any): { valid: boolean; errors?: string[] } {
  const errors: string[] = [];
  
  // Extract supported currencies if provided (for edit validation)
  const supportedCurrencies = versionData.supported_currencies || [];
  const hasCurrencyInfo = supportedCurrencies.length > 0;
  
  if (!versionData.plan_id) {
    errors.push('Plan ID is required');
  }
  
  if (!versionData.version_number) {
    errors.push('Version number is required');
  } else {
    const versionRegex = /^\d+\.\d+$/;
    if (!versionRegex.test(versionData.version_number)) {
      errors.push('Version number must be in format X.Y (e.g., 1.0, 1.1, 2.0)');
    }
  }
  
  if (!versionData.created_by) {
    errors.push('Created by is required');
  }
  
  if (!versionData.changelog || versionData.changelog.trim().length < 5) {
    errors.push('Changelog must be at least 5 characters long');
  }
  
  // Validate tiers
  if (!versionData.tiers || !Array.isArray(versionData.tiers) || versionData.tiers.length === 0) {
    errors.push('At least one pricing tier is required');
  } else {
    for (let i = 0; i < versionData.tiers.length; i++) {
      const tier = versionData.tiers[i];
      
      if (!tier.tier_id) {
        errors.push(`Tier ${i + 1}: tier_id is required`);
      }
      
      if (tier.min_value === undefined || tier.min_value === null) {
        errors.push(`Tier ${i + 1}: min_value is required`);
      }
      
      if (!tier.label) {
        errors.push(`Tier ${i + 1}: label is required`);
      }
      
      if (!tier.prices || Object.keys(tier.prices).length === 0) {
        errors.push(`Tier ${i + 1}: At least one currency price is required`);
      } else if (hasCurrencyInfo) {
        // Check that all supported currencies have prices
        const missingCurrencies = supportedCurrencies.filter(
          (currency: string) => tier.prices[currency] === undefined || tier.prices[currency] === null
        );
        if (missingCurrencies.length > 0) {
          errors.push(`Tier ${i + 1}: Missing prices for currencies: ${missingCurrencies.join(', ')}`);
        }
      }
    }
  }
  
  // Validate features
  if (!versionData.features || !Array.isArray(versionData.features)) {
    errors.push('Features must be an array');
  } else {
    const featureIds = new Set();
    for (let i = 0; i < versionData.features.length; i++) {
      const feature = versionData.features[i];
      
      if (!feature.feature_id) {
        errors.push(`Feature ${i + 1}: feature_id is required`);
      } else if (featureIds.has(feature.feature_id)) {
        errors.push(`Feature ${i + 1}: Duplicate feature ID: ${feature.feature_id}`);
      } else {
        featureIds.add(feature.feature_id);
      }
      
      if (feature.enabled === undefined) {
        errors.push(`Feature ${i + 1}: enabled flag is required`);
      }
      
      if (feature.limit === undefined) {
        errors.push(`Feature ${i + 1}: limit is required`);
      }
      
      if (feature.is_special_feature && !feature.prices) {
        errors.push(`Feature ${i + 1}: Special features must have prices defined`);
      } else if (feature.is_special_feature && feature.prices && hasCurrencyInfo) {
        // Check that special features have prices for all supported currencies
        const missingCurrencies = supportedCurrencies.filter(
          (currency: string) => feature.prices[currency] === undefined || feature.prices[currency] === null
        );
        if (missingCurrencies.length > 0) {
          errors.push(`Feature ${feature.name || i + 1}: Missing prices for currencies: ${missingCurrencies.join(', ')}`);
        }
      }
    }
  }
  
  // Validate notifications
  if (!versionData.notifications || !Array.isArray(versionData.notifications)) {
    errors.push('Notifications must be an array');
  } else {
    const notifCombos = new Set();
    for (let i = 0; i < versionData.notifications.length; i++) {
      const notification = versionData.notifications[i];
      
      if (!notification.notif_type) {
        errors.push(`Notification ${i + 1}: notif_type is required`);
      }
      
      if (!notification.category) {
        errors.push(`Notification ${i + 1}: category is required`);
      }
      
      const combo = `${notification.notif_type}-${notification.category}`;
      if (notifCombos.has(combo)) {
        errors.push(`Notification ${i + 1}: Duplicate method-category combination: ${combo}`);
      } else {
        notifCombos.add(combo);
      }
      
      if (notification.enabled === undefined) {
        errors.push(`Notification ${i + 1}: enabled flag is required`);
      }
      
      if (!notification.prices || Object.keys(notification.prices).length === 0) {
        errors.push(`Notification ${i + 1}: At least one currency price is required`);
      } else if (hasCurrencyInfo) {
        // Check that all supported currencies have prices
        const missingCurrencies = supportedCurrencies.filter(
          (currency: string) => notification.prices[currency] === undefined || notification.prices[currency] === null
        );
        if (missingCurrencies.length > 0) {
          errors.push(`Notification ${notification.notif_type || i + 1}: Missing prices for currencies: ${missingCurrencies.join(', ')}`);
        }
      }
    }
  }
  
  return {
    valid: errors.length === 0,
    errors: errors.length > 0 ? errors : undefined
  };
}

/**
 * Check if a version number already exists for a plan
 */
export async function checkVersionExists(
  supabase: any, 
  planId: string, 
  versionNumber: string
): Promise<boolean> {
  const { data, error } = await supabase
    .from('t_bm_plan_version')
    .select('version_id')
    .eq('plan_id', planId)
    .eq('version_number', versionNumber)
    .single();
    
  if (error && error.code !== 'PGRST116') {
    throw error;
  }
  
  return !!data;
}

/**
 * Get the next suggested version number
 */
export async function getNextVersionNumber(
  supabase: any,
  planId: string
): Promise<string> {
  const { data: versions, error } = await supabase
    .from('t_bm_plan_version')
    .select('version_number')
    .eq('plan_id', planId)
    .order('created_at', { ascending: false });
    
  if (error) {
    throw error;
  }
  
  if (!versions || versions.length === 0) {
    return '1.0';
  }
  
  let maxMajor = 0;
  let maxMinor = 0;
  
  versions.forEach(v => {
    const parts = v.version_number.split('.');
    const major = parseInt(parts[0]) || 0;
    const minor = parseInt(parts[1]) || 0;
    
    if (major > maxMajor || (major === maxMajor && minor > maxMinor)) {
      maxMajor = major;
      maxMinor = minor;
    }
  });
  
  return `${maxMajor}.${maxMinor + 1}`;
}

/**
 * Transforms plan data for edit form
 */
export function transformPlanForEdit(plan: any, activeVersion: any): any {
  return {
    // Plan metadata (read-only in edit)
    plan_id: plan.plan_id,
    name: plan.name,
    description: plan.description,
    plan_type: plan.plan_type,
    trial_duration: plan.trial_duration,
    is_visible: plan.is_visible,
    default_currency_code: plan.default_currency_code,
    supported_currencies: plan.supported_currencies,
    
    // Current version info
    current_version_id: activeVersion.version_id,
    current_version_number: activeVersion.version_number,
    
    // Version data to edit
    tiers: activeVersion.tiers || [],
    features: activeVersion.features || [],
    notifications: activeVersion.notifications || [],
    
    // For new version
    next_version_number: '', // Will be suggested or user input
    effective_date: new Date().toISOString().split('T')[0],
    changelog: '',
    
    // Stats
    subscriber_count: plan.subscriber_count || 0
  };
}

/**
 * Creates a new version from edit data
 */
export function createVersionFromEdit(editData: any, userId: string): any {
  return {
    plan_id: editData.plan_id,
    version_number: editData.next_version_number,
    is_active: false, // Always create as draft
    effective_date: editData.effective_date || new Date().toISOString(),
    changelog: editData.changelog,
    created_by: userId,
    tiers: editData.tiers || [],
    features: editData.features || [],
    notifications: editData.notifications || []
  };
}

/**
 * Check if plan has active tenants
 * TODO: Implement when tenant subscriptions are ready
 */
export async function checkPlanHasActiveTenants(
  supabase: any,
  planId: string
): Promise<boolean> {
  // TODO: Implement when tenant subscription table is ready
  return false;
}

/**
 * Get tenant count for a specific version
 * TODO: Implement when tenant subscriptions are ready
 */
export async function getVersionTenantCount(
  supabase: any,
  versionId: string
): Promise<number> {
  // TODO: Implement when tenant subscription table is ready
  return 0;
}
