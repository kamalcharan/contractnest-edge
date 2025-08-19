// File: supabase/functions/_shared/globalConfig/types.ts

export type PlanType = 'starter' | 'professional' | 'enterprise';
export type EdgeFunction = 'service-catalog' | 'contacts' | 'invoice' | 'user-management' | 'payments' | 'analytics' | 'booking' | 'notifications';

export interface GlobalTenantConfiguration {
  tenant_id: string;
  edge_function: EdgeFunction;
  plan_type: PlanType;
  config: EdgeFunctionConfig;
  created_at: string;
  updated_at: string;
  is_active: boolean;
}

export interface EdgeFunctionConfig {
  rate_limits: RateLimits;
  validation_limits: ValidationLimits;
  bulk_operation_limits?: BulkOperationLimits;
  cache_settings: CacheSettings;
  feature_flags: FeatureFlags;
  security_settings: SecuritySettings;
}

export interface RateLimits {
  // Core operations (all edge functions have these)
  create: { requests: number; windowMinutes: number };
  read: { requests: number; windowMinutes: number };
  update: { requests: number; windowMinutes: number };
  delete: { requests: number; windowMinutes: number };
  list: { requests: number; windowMinutes: number };
  
  // Optional operations (function-specific)
  bulk_operations?: { requests: number; windowMinutes: number };
  search?: { requests: number; windowMinutes: number };
  export?: { requests: number; windowMinutes: number };
  import?: { requests: number; windowMinutes: number };
  
  // Function-specific operations (can be extended per function)
  [key: string]: { requests: number; windowMinutes: number } | undefined;
}

export interface ValidationLimits {
  max_name_length: number;
  max_description_length: number;
  max_items_per_request: number;
  max_search_results: number;
  max_file_size_mb: number;
  max_array_length: number;
  max_string_length: number;
  max_number_value: number;
}

export interface BulkOperationLimits {
  max_items_per_bulk: number;
  max_bulk_operations_per_hour: number;
  max_concurrent_bulk_jobs: number;
  max_file_size_mb: number;
  supported_formats: string[];
  timeout_minutes: number;
}

export interface CacheSettings {
  default_ttl_minutes: number;
  list_ttl_minutes: number;
  item_ttl_minutes: number;
  search_ttl_minutes: number;
  max_cache_size: number;
  cleanup_interval_minutes: number;
  enable_cache: boolean;
}

export interface FeatureFlags {
  enable_advanced_features: boolean;
  enable_bulk_operations: boolean;
  enable_export: boolean;
  enable_import: boolean;
  enable_analytics: boolean;
  enable_audit_trail: boolean;
  enable_real_time: boolean;
  enable_webhooks: boolean;
  [key: string]: boolean;
}

export interface SecuritySettings {
  require_hmac: boolean;
  hmac_algorithms: string[];
  max_request_size_mb: number;
  allowed_origins: string[];
  rate_limit_by_ip: boolean;
  enable_request_logging: boolean;
  log_sensitive_data: boolean;
  require_ssl: boolean;
}

export interface GlobalSettings {
  tenant_id: string;
  plan_type: PlanType;
  max_concurrent_requests: number;
  request_timeout_seconds: number;
  security_level: 'basic' | 'standard' | 'enhanced';
  audit_level: 'minimal' | 'standard' | 'comprehensive';
  monitoring_level: 'basic' | 'standard' | 'advanced';
  created_at: string;
  updated_at: string;
  is_active: boolean;
}

export interface TenantContext {
  tenant_id: string;
  user_id: string;
  edge_function: EdgeFunction;
  is_live: boolean;
  request_id: string;
  ip_address?: string;
  user_agent?: string;
}

export interface ConfigCache {
  [key: string]: {
    config: EdgeFunctionConfig;
    globalSettings: GlobalSettings;
    cachedAt: number;
    ttl: number;
  };
}

// Default configurations by plan type
export const DEFAULT_CONFIGS: Record<PlanType, EdgeFunctionConfig> = {
  starter: {
    rate_limits: {
      create: { requests: 50, windowMinutes: 60 },
      read: { requests: 100, windowMinutes: 60 },
      update: { requests: 75, windowMinutes: 60 },
      delete: { requests: 25, windowMinutes: 60 },
      list: { requests: 200, windowMinutes: 60 },
      search: { requests: 100, windowMinutes: 60 },
      bulk_operations: { requests: 5, windowMinutes: 60 }
    },
    validation_limits: {
      max_name_length: 100,
      max_description_length: 500,
      max_items_per_request: 50,
      max_search_results: 100,
      max_file_size_mb: 10,
      max_array_length: 50,
      max_string_length: 1000,
      max_number_value: 999999
    },
    bulk_operation_limits: {
      max_items_per_bulk: 100,
      max_bulk_operations_per_hour: 5,
      max_concurrent_bulk_jobs: 1,
      max_file_size_mb: 25,
      supported_formats: ['json', 'csv'],
      timeout_minutes: 10
    },
    cache_settings: {
      default_ttl_minutes: 5,
      list_ttl_minutes: 3,
      item_ttl_minutes: 10,
      search_ttl_minutes: 2,
      max_cache_size: 500,
      cleanup_interval_minutes: 10,
      enable_cache: true
    },
    feature_flags: {
      enable_advanced_features: false,
      enable_bulk_operations: true,
      enable_export: false,
      enable_import: false,
      enable_analytics: false,
      enable_audit_trail: false,
      enable_real_time: false,
      enable_webhooks: false
    },
    security_settings: {
      require_hmac: true,
      hmac_algorithms: ['sha256'],
      max_request_size_mb: 10,
      allowed_origins: [],
      rate_limit_by_ip: true,
      enable_request_logging: true,
      log_sensitive_data: false,
      require_ssl: true
    }
  },
  
  professional: {
    rate_limits: {
      create: { requests: 200, windowMinutes: 60 },
      read: { requests: 500, windowMinutes: 60 },
      update: { requests: 300, windowMinutes: 60 },
      delete: { requests: 100, windowMinutes: 60 },
      list: { requests: 1000, windowMinutes: 60 },
      search: { requests: 500, windowMinutes: 60 },
      bulk_operations: { requests: 25, windowMinutes: 60 }
    },
    validation_limits: {
      max_name_length: 255,
      max_description_length: 2000,
      max_items_per_request: 200,
      max_search_results: 500,
      max_file_size_mb: 50,
      max_array_length: 200,
      max_string_length: 5000,
      max_number_value: 999999999
    },
    bulk_operation_limits: {
      max_items_per_bulk: 1000,
      max_bulk_operations_per_hour: 25,
      max_concurrent_bulk_jobs: 3,
      max_file_size_mb: 100,
      supported_formats: ['json', 'csv', 'xlsx'],
      timeout_minutes: 30
    },
    cache_settings: {
      default_ttl_minutes: 15,
      list_ttl_minutes: 10,
      item_ttl_minutes: 30,
      search_ttl_minutes: 5,
      max_cache_size: 2000,
      cleanup_interval_minutes: 5,
      enable_cache: true
    },
    feature_flags: {
      enable_advanced_features: true,
      enable_bulk_operations: true,
      enable_export: true,
      enable_import: true,
      enable_analytics: true,
      enable_audit_trail: true,
      enable_real_time: false,
      enable_webhooks: false
    },
    security_settings: {
      require_hmac: true,
      hmac_algorithms: ['sha256', 'sha512'],
      max_request_size_mb: 50,
      allowed_origins: [],
      rate_limit_by_ip: true,
      enable_request_logging: true,
      log_sensitive_data: false,
      require_ssl: true
    }
  },
  
  enterprise: {
    rate_limits: {
      create: { requests: 1000, windowMinutes: 60 },
      read: { requests: 2500, windowMinutes: 60 },
      update: { requests: 1500, windowMinutes: 60 },
      delete: { requests: 500, windowMinutes: 60 },
      list: { requests: 5000, windowMinutes: 60 },
      search: { requests: 2500, windowMinutes: 60 },
      bulk_operations: { requests: 100, windowMinutes: 60 }
    },
    validation_limits: {
      max_name_length: 500,
      max_description_length: 10000,
      max_items_per_request: 1000,
      max_search_results: 2000,
      max_file_size_mb: 500,
      max_array_length: 1000,
      max_string_length: 50000,
      max_number_value: 999999999999
    },
    bulk_operation_limits: {
      max_items_per_bulk: 10000,
      max_bulk_operations_per_hour: 100,
      max_concurrent_bulk_jobs: 10,
      max_file_size_mb: 1000,
      supported_formats: ['json', 'csv', 'xlsx', 'xml'],
      timeout_minutes: 120
    },
    cache_settings: {
      default_ttl_minutes: 30,
      list_ttl_minutes: 20,
      item_ttl_minutes: 60,
      search_ttl_minutes: 15,
      max_cache_size: 10000,
      cleanup_interval_minutes: 3,
      enable_cache: true
    },
    feature_flags: {
      enable_advanced_features: true,
      enable_bulk_operations: true,
      enable_export: true,
      enable_import: true,
      enable_analytics: true,
      enable_audit_trail: true,
      enable_real_time: true,
      enable_webhooks: true
    },
    security_settings: {
      require_hmac: true,
      hmac_algorithms: ['sha256', 'sha512'],
      max_request_size_mb: 500,
      allowed_origins: [],
      rate_limit_by_ip: false,
      enable_request_logging: true,
      log_sensitive_data: false,
      require_ssl: true
    }
  }
};

export const DEFAULT_GLOBAL_SETTINGS: Record<PlanType, Omit<GlobalSettings, 'tenant_id' | 'created_at' | 'updated_at'>> = {
  starter: {
    plan_type: 'starter',
    max_concurrent_requests: 10,
    request_timeout_seconds: 30,
    security_level: 'basic',
    audit_level: 'minimal',
    monitoring_level: 'basic',
    is_active: true
  },
  professional: {
    plan_type: 'professional',
    max_concurrent_requests: 50,
    request_timeout_seconds: 60,
    security_level: 'standard',
    audit_level: 'standard',
    monitoring_level: 'standard',
    is_active: true
  },
  enterprise: {
    plan_type: 'enterprise',
    max_concurrent_requests: 200,
    request_timeout_seconds: 120,
    security_level: 'enhanced',
    audit_level: 'comprehensive',
    monitoring_level: 'advanced',
    is_active: true
  }
};

// Error types
export interface ConfigError {
  code: string;
  message: string;
  context?: Record<string, any>;
}

export const CONFIG_ERROR_CODES = {
  TENANT_NOT_FOUND: 'TENANT_NOT_FOUND',
  CONFIG_NOT_FOUND: 'CONFIG_NOT_FOUND',
  INVALID_EDGE_FUNCTION: 'INVALID_EDGE_FUNCTION',
  INVALID_PLAN_TYPE: 'INVALID_PLAN_TYPE',
  CONFIG_LOAD_ERROR: 'CONFIG_LOAD_ERROR',
  CACHE_ERROR: 'CACHE_ERROR',
  DATABASE_ERROR: 'DATABASE_ERROR'
} as const;