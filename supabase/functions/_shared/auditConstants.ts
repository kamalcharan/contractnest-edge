// supabase/functions/_shared/auditConstants.ts
// Shared audit constants for Edge Functions
// Extended with Tax Management actions

/**
 * Audit action constants - all possible actions that can be audited
 */
export const AuditActions = {
  // Auth Actions (existing)
  LOGIN: 'LOGIN',
  LOGOUT: 'LOGOUT',
  PASSWORD_CHANGE: 'PASSWORD_CHANGE',
  PASSWORD_RESET: 'PASSWORD_RESET',
  UNAUTHORIZED_ACCESS: 'UNAUTHORIZED_ACCESS',
  
  // Storage Actions (existing)
  STORAGE_SETUP: 'STORAGE_SETUP',
  STORAGE_STATS_VIEW: 'STORAGE_STATS_VIEW',
  FILE_UPLOAD: 'FILE_UPLOAD',
  FILE_DELETE: 'FILE_DELETE',
  FILE_DOWNLOAD: 'FILE_DOWNLOAD',
  FILE_LIST: 'FILE_LIST',
  STORAGE_QUOTA_EXCEEDED: 'STORAGE_QUOTA_EXCEEDED',
  
  // Security Actions (existing)
  RATE_LIMIT_EXCEEDED: 'RATE_LIMIT_EXCEEDED',
  INVALID_SIGNATURE: 'INVALID_SIGNATURE',
  SUSPICIOUS_ACTIVITY: 'SUSPICIOUS_ACTIVITY',
  
  // System Actions (existing)
  SYSTEM_ERROR: 'SYSTEM_ERROR',
  REQUEST_ERROR: 'REQUEST_ERROR',
  NOT_FOUND: 'NOT_FOUND',
  
  // Tax Management Actions (NEW - added for tax functionality)
  TAX_SETTINGS_VIEW: 'TAX_SETTINGS_VIEW',
  TAX_SETTINGS_CREATE: 'TAX_SETTINGS_CREATE',
  TAX_SETTINGS_UPDATE: 'TAX_SETTINGS_UPDATE',
  TAX_RATE_CREATE: 'TAX_RATE_CREATE',
  TAX_RATE_UPDATE: 'TAX_RATE_UPDATE',
  TAX_RATE_DELETE: 'TAX_RATE_DELETE',
  TAX_RATE_VIEW: 'TAX_RATE_VIEW',
  TAX_RATE_LIST: 'TAX_RATE_LIST',
  TAX_RATE_ACTIVATE: 'TAX_RATE_ACTIVATE',
  TAX_RATE_DEACTIVATE: 'TAX_RATE_DEACTIVATE',
  TAX_DEFAULT_CHANGE: 'TAX_DEFAULT_CHANGE',
  TAX_DISPLAY_MODE_CHANGE: 'TAX_DISPLAY_MODE_CHANGE',
  TAX_SEQUENCE_UPDATE: 'TAX_SEQUENCE_UPDATE',
  
  // Add more as needed
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
  
  // Tax Resources (NEW - added for tax functionality)
  TAX_SETTINGS: 'tax_settings',
  TAX_RATES: 'tax_rates',
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
    AuditActions.TAX_RATE_DELETE, // Tax deletion is critical for compliance
  ];
  
  const warningActions = [
    AuditActions.UNAUTHORIZED_ACCESS,
    AuditActions.RATE_LIMIT_EXCEEDED,
    AuditActions.STORAGE_QUOTA_EXCEEDED,
    AuditActions.STORAGE_SETUP,
    AuditActions.TAX_DEFAULT_CHANGE, // Important for pricing
    AuditActions.TAX_DISPLAY_MODE_CHANGE, // Important for pricing
  ];
  
  const errorActions = [
    AuditActions.INVALID_SIGNATURE,
    AuditActions.REQUEST_ERROR,
  ];
  
  if (criticalActions.includes(action)) return AuditSeverity.CRITICAL;
  if (warningActions.includes(action)) return AuditSeverity.WARNING;
  if (errorActions.includes(action)) return AuditSeverity.ERROR;
  
  return AuditSeverity.INFO;
};

/**
 * Helper to determine if an action should trigger alerts
 */
export const shouldAlert = (action: AuditAction, severity: AuditSeverityLevel): boolean => {
  // Always alert on critical
  if (severity === AuditSeverity.CRITICAL) return true;
  
  // Alert on specific warning actions
  const alertableWarnings: AuditAction[] = [
    AuditActions.UNAUTHORIZED_ACCESS,
    AuditActions.SUSPICIOUS_ACTIVITY,
    AuditActions.TAX_RATE_DELETE,
    AuditActions.TAX_DEFAULT_CHANGE,
  ];
  
  return severity === AuditSeverity.WARNING && alertableWarnings.includes(action);
};

/**
 * Action groups for categorization
 */
export const ActionGroups = {
  AUTH: [
    AuditActions.LOGIN,
    AuditActions.LOGOUT,
    AuditActions.PASSWORD_CHANGE,
    AuditActions.PASSWORD_RESET,
    AuditActions.UNAUTHORIZED_ACCESS,
  ],
  
  STORAGE: [
    AuditActions.STORAGE_SETUP,
    AuditActions.STORAGE_STATS_VIEW,
    AuditActions.FILE_UPLOAD,
    AuditActions.FILE_DELETE,
    AuditActions.FILE_DOWNLOAD,
    AuditActions.FILE_LIST,
    AuditActions.STORAGE_QUOTA_EXCEEDED,
  ],
  
  SECURITY: [
    AuditActions.UNAUTHORIZED_ACCESS,
    AuditActions.RATE_LIMIT_EXCEEDED,
    AuditActions.SUSPICIOUS_ACTIVITY,
  ],
  
  SYSTEM: [
    AuditActions.SYSTEM_ERROR,
    AuditActions.REQUEST_ERROR,
    AuditActions.NOT_FOUND,
  ],
  
  // Tax Management Group (NEW)
  TAX_MANAGEMENT: [
    AuditActions.TAX_SETTINGS_VIEW,
    AuditActions.TAX_SETTINGS_CREATE,
    AuditActions.TAX_SETTINGS_UPDATE,
    AuditActions.TAX_RATE_CREATE,
    AuditActions.TAX_RATE_UPDATE,
    AuditActions.TAX_RATE_DELETE,
    AuditActions.TAX_RATE_VIEW,
    AuditActions.TAX_RATE_LIST,
    AuditActions.TAX_RATE_ACTIVATE,
    AuditActions.TAX_RATE_DEACTIVATE,
    AuditActions.TAX_DEFAULT_CHANGE,
    AuditActions.TAX_DISPLAY_MODE_CHANGE,
    AuditActions.TAX_SEQUENCE_UPDATE,
  ],
};

/**
 * Resource-to-Action mapping for validation
 */
export const ResourceActionMap = {
  [AuditResources.AUTH]: ActionGroups.AUTH,
  [AuditResources.STORAGE]: ActionGroups.STORAGE,
  [AuditResources.SYSTEM]: ActionGroups.SYSTEM,
  
  // Tax Resource Mappings (NEW)
  [AuditResources.TAX_SETTINGS]: ActionGroups.TAX_MANAGEMENT,
  [AuditResources.TAX_RATES]: ActionGroups.TAX_MANAGEMENT,
} as const;

/**
 * Validate if an action is appropriate for a resource
 */
export const isValidActionForResource = (action: AuditAction, resource: AuditResource): boolean => {
  const validActions = ResourceActionMap[resource];
  return validActions ? validActions.includes(action) : true; // Allow unknown combinations
};