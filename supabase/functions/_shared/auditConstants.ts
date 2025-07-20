// supabase/functions/_shared/auditConstants.ts
// Shared audit constants for Edge Functions - UPDATED with Business Model actions

/**
 * Audit action constants - all possible actions that can be audited
 */
export const AuditActions = {
  // Auth Actions
  LOGIN: 'LOGIN',
  LOGOUT: 'LOGOUT',
  PASSWORD_CHANGE: 'PASSWORD_CHANGE',
  PASSWORD_RESET: 'PASSWORD_RESET',
  UNAUTHORIZED_ACCESS: 'UNAUTHORIZED_ACCESS',
  
  // Storage Actions
  STORAGE_SETUP: 'STORAGE_SETUP',
  STORAGE_STATS_VIEW: 'STORAGE_STATS_VIEW',
  FILE_UPLOAD: 'FILE_UPLOAD',
  FILE_DELETE: 'FILE_DELETE',
  FILE_DOWNLOAD: 'FILE_DOWNLOAD',
  FILE_LIST: 'FILE_LIST',
  STORAGE_QUOTA_EXCEEDED: 'STORAGE_QUOTA_EXCEEDED',
  
  // Security Actions
  RATE_LIMIT_EXCEEDED: 'RATE_LIMIT_EXCEEDED',
  INVALID_SIGNATURE: 'INVALID_SIGNATURE',
  SUSPICIOUS_ACTIVITY: 'SUSPICIOUS_ACTIVITY',
  
  // System Actions
  SYSTEM_ERROR: 'SYSTEM_ERROR',
  REQUEST_ERROR: 'REQUEST_ERROR',
  NOT_FOUND: 'NOT_FOUND',

  // ==================
  // BUSINESS MODEL ACTIONS (NEW)
  // ==================
  
  // Plan Management
  PLAN_CREATE: 'PLAN_CREATE',
  PLAN_UPDATE: 'PLAN_UPDATE',
  PLAN_DELETE: 'PLAN_DELETE',
  PLAN_ARCHIVE: 'PLAN_ARCHIVE',
  PLAN_VISIBILITY_TOGGLE: 'PLAN_VISIBILITY_TOGGLE',
  PLAN_VIEW: 'PLAN_VIEW',
  PLAN_EDIT_START: 'PLAN_EDIT_START',
  PLAN_LIST_VIEW: 'PLAN_LIST_VIEW',
  
  // Plan Version Management
  PLAN_VERSION_CREATE: 'PLAN_VERSION_CREATE',
  PLAN_VERSION_ACTIVATE: 'PLAN_VERSION_ACTIVATE',
  PLAN_VERSION_VIEW: 'PLAN_VERSION_VIEW',
  PLAN_VERSION_LIST: 'PLAN_VERSION_LIST',
  
  // Pricing & Tiers
  PRICING_TIER_UPDATE: 'PRICING_TIER_UPDATE',
  PRICING_CURRENCY_UPDATE: 'PRICING_CURRENCY_UPDATE',
  
  // Features Configuration
  FEATURE_CONFIGURE: 'FEATURE_CONFIGURE',
  FEATURE_LIMIT_UPDATE: 'FEATURE_LIMIT_UPDATE',
  FEATURE_PRICING_UPDATE: 'FEATURE_PRICING_UPDATE',
  
  // Top-up Configuration (NEW)
  TOPUP_OPTION_ADD: 'TOPUP_OPTION_ADD',
  TOPUP_OPTION_UPDATE: 'TOPUP_OPTION_UPDATE',
  TOPUP_OPTION_REMOVE: 'TOPUP_OPTION_REMOVE',
  TOPUP_PRICING_UPDATE: 'TOPUP_PRICING_UPDATE',
  
  // Notifications Configuration
  NOTIFICATION_CONFIGURE: 'NOTIFICATION_CONFIGURE',
  NOTIFICATION_CREDITS_UPDATE: 'NOTIFICATION_CREDITS_UPDATE',
  
  // Validation & Business Rules
  PLAN_VALIDATION_FAILED: 'PLAN_VALIDATION_FAILED',
  TOPUP_VALIDATION_FAILED: 'TOPUP_VALIDATION_FAILED',
  BUSINESS_RULE_VIOLATION: 'BUSINESS_RULE_VIOLATION',
  
} as const;

/**
 * Audit resource types
 */
export const AuditResources = {
  AUTH: 'auth',
  USERS: 'users',
  STORAGE: 'storage',
  TENANTS: 'tenants',
  SYSTEM: 'system',
  AUDIT: 'audit',
  
  // Business Model Resources (NEW)
  PLANS: 'plans',
  PLAN_VERSIONS: 'plan_versions',
  PRICING_TIERS: 'pricing_tiers',
  PLAN_FEATURES: 'plan_features',
  PLAN_NOTIFICATIONS: 'plan_notifications',
  TOPUP_OPTIONS: 'topup_options', // NEW
  BUSINESS_MODEL: 'business_model',
} as const;

/**
 * Audit severity levels
 */
export const AuditSeverity = {
  INFO: 'info',
  WARNING: 'warning',
  ERROR: 'error',
  CRITICAL: 'critical'
} as const;

// Type definitions
export type AuditAction = typeof AuditActions[keyof typeof AuditActions];
export type AuditResource = typeof AuditResources[keyof typeof AuditResources];
export type AuditSeverityLevel = typeof AuditSeverity[keyof typeof AuditSeverity];

/**
 * Helper to determine default severity for an action
 */
export const getDefaultSeverity = (action: AuditAction): AuditSeverityLevel => {
  const criticalActions = [
    AuditActions.SYSTEM_ERROR,
    AuditActions.SUSPICIOUS_ACTIVITY,
    AuditActions.PLAN_DELETE,           // NEW
    AuditActions.PLAN_ARCHIVE,          // NEW
    AuditActions.PLAN_VERSION_ACTIVATE, // NEW - affects live tenants
  ];
  
  const warningActions = [
    AuditActions.UNAUTHORIZED_ACCESS,
    AuditActions.RATE_LIMIT_EXCEEDED,
    AuditActions.STORAGE_QUOTA_EXCEEDED,
    AuditActions.STORAGE_SETUP,
    // Business Model warnings (NEW)
    AuditActions.PLAN_CREATE,
    AuditActions.PLAN_UPDATE,
    AuditActions.PLAN_VERSION_CREATE,
    AuditActions.PLAN_VISIBILITY_TOGGLE,
    AuditActions.PRICING_TIER_UPDATE,
    AuditActions.TOPUP_OPTION_ADD,
    AuditActions.TOPUP_OPTION_UPDATE,
    AuditActions.TOPUP_PRICING_UPDATE,
    AuditActions.FEATURE_PRICING_UPDATE,
  ];
  
  const errorActions = [
    AuditActions.INVALID_SIGNATURE,
    AuditActions.REQUEST_ERROR,
    // Business Model errors (NEW)
    AuditActions.PLAN_VALIDATION_FAILED,
    AuditActions.TOPUP_VALIDATION_FAILED,
    AuditActions.BUSINESS_RULE_VIOLATION,
  ];
  
  if (criticalActions.includes(action)) return AuditSeverity.CRITICAL;
  if (warningActions.includes(action)) return AuditSeverity.WARNING;
  if (errorActions.includes(action)) return AuditSeverity.ERROR;
  
  return AuditSeverity.INFO;
};

