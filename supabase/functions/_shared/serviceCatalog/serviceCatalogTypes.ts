export interface ServiceCatalogItemData {
  service_name: string;
  description?: string;
  sku?: string;
  category_id: string;
  industry_id: string;
  pricing_config: ServicePricingConfig;
  service_attributes?: Record<string, any>;
  duration_minutes?: number;
  is_active?: boolean;
  sort_order?: number;
  required_resources?: RequiredResource[];
  tags?: string[];
}

export interface ServicePricingConfig {
  base_price: number;
  currency: string;
  pricing_model: 'fixed' | 'tiered' | 'dynamic';
  tiers?: PricingTier[];
  tax_inclusive?: boolean;
  billing_cycle?: 'one_time' | 'hourly' | 'daily' | 'weekly' | 'monthly' | 'yearly';
  discount_rules?: DiscountRule[];
}

export interface PricingTier {
  min_quantity: number;
  max_quantity?: number;
  price: number;
  discount_percentage?: number;
}

export interface DiscountRule {
  rule_name: string;
  condition: string;
  action: string;
  value?: number;
  is_active: boolean;
}

export interface RequiredResource {
  resource_id: string;
  quantity?: number;
  is_optional?: boolean;
  alternative_resources?: string[];
  skill_requirements?: string[];
}

export interface ServiceCatalogItem extends ServiceCatalogItemData {
  id: string;
  tenant_id: string;
  slug: string;
  created_at: string;
  updated_at: string;
  created_by: string;
  updated_by: string;
  is_live: boolean;
  category_name?: string;
  industry_name?: string;
  resource_count?: number;
  avg_rating?: number;
  usage_count?: number;
}

export interface ServiceCatalogFilters {
  search_term?: string;
  category_id?: string;
  industry_id?: string;
  is_active?: boolean;
  price_min?: number;
  price_max?: number;
  currency?: string;
  has_resources?: boolean;
  duration_min?: number;
  duration_max?: number;
  tags?: string[];
  sort_by?: 'name' | 'price' | 'created_at' | 'sort_order' | 'usage_count' | 'avg_rating';
  sort_direction?: 'asc' | 'desc';
  limit?: number;
  offset?: number;
}

export interface ServiceCatalogResponse {
  items: ServiceCatalogItem[];
  total_count: number;
  page_info: {
    has_next_page: boolean;
    has_prev_page: boolean;
    current_page: number;
    total_pages: number;
  };
  filters_applied: ServiceCatalogFilters;
}

export interface ServiceResourceAssociation {
  service_id: string;
  resource_id: string;
  quantity?: number;
  is_required?: boolean;
  skill_match_score?: number;
  estimated_cost?: number;
}

export interface BulkServiceOperation {
  items: ServiceCatalogItemData[];
  batch_id?: string;
  operation_type: 'create' | 'update' | 'delete';
  validation_mode?: 'strict' | 'lenient';
  continue_on_error?: boolean;
}

export interface BulkOperationResult {
  success_count: number;
  error_count: number;
  total_count: number;
  successful_items: string[];
  failed_items: BulkOperationError[];
  batch_id: string;
  processing_time_ms: number;
}

export interface BulkOperationError {
  item_index: number;
  item_data: ServiceCatalogItemData;
  error_code: string;
  error_message: string;
  field_errors?: Record<string, string>;
}

export interface ServicePricingUpdate {
  service_id: string;
  pricing_config: ServicePricingConfig;
  effective_date?: string;
  reason?: string;
  apply_to_existing_contracts?: boolean;
}

export interface MasterDataResponse {
  categories: CategoryMaster[];
  industries: IndustryMaster[];
  currencies: CurrencyOption[];
  tax_rates: TaxRateOption[];
}

export interface CategoryMaster {
  id: string;
  name: string;
  description?: string;
  icon?: string;
  parent_id?: string;
  level: number;
  sort_order: number;
  is_active: boolean;
  service_count?: number;
}

export interface IndustryMaster {
  id: string;
  name: string;
  description?: string;
  icon?: string;
  common_pricing_rules?: DiscountRule[];
  compliance_requirements?: string[];
  is_active: boolean;
  sort_order: number;
}

export interface CurrencyOption {
  code: string;
  name: string;
  symbol: string;
  decimal_places: number;
  is_default?: boolean;
}

export interface TaxRateOption {
  id: string;
  name: string;
  rate: number;
  is_default: boolean;
  is_active: boolean;
}

export interface ResourceSearchFilters {
  skills?: string[];
  location_type?: 'onsite' | 'remote' | 'hybrid';
  availability_start?: string;
  availability_end?: string;
  cost_min?: number;
  cost_max?: number;
  rating_min?: number;
  experience_years?: number;
  certification_required?: boolean;
  limit?: number;
  offset?: number;
}

export interface AvailableResource {
  id: string;
  name: string;
  type: string;
  skills: string[];
  hourly_rate?: number;
  currency?: string;
  location_type: string;
  availability_score: number;
  rating: number;
  experience_years: number;
  certifications: string[];
  is_available: boolean;
  next_available_date?: string;
}

export interface ResourceSearchResponse {
  resources: AvailableResource[];
  total_count: number;
  matching_criteria: {
    skill_matches: number;
    location_matches: number;
    availability_matches: number;
    cost_matches: number;
  };
  search_filters: ResourceSearchFilters;
}

export interface ServiceResourceSummary {
  service_id: string;
  service_name: string;
  associated_resources: {
    resource_id: string;
    resource_name: string;
    resource_type: string;
    quantity: number;
    is_required: boolean;
    skill_match_score: number;
    estimated_cost: number;
  }[];
  total_resources: number;
  total_estimated_cost: number;
  resource_availability_score: number;
  available_alternatives: AvailableResource[];
}

export interface EnvironmentContext {
  tenant_id: string;
  user_id: string;
  is_live: boolean;
  request_id: string;
  timestamp: string;
  ip_address?: string;
  user_agent?: string;
}

export interface AuditTrail {
  operation_id: string;
  operation_type: string;
  table_name: string;
  record_id: string;
  old_values?: Record<string, any>;
  new_values?: Record<string, any>;
  environment_context: EnvironmentContext;
  execution_time_ms: number;
  success: boolean;
  error_details?: string;
}

export interface ServiceCatalogError {
  code: string;
  message: string;
  field?: string;
  value?: any;
  context?: Record<string, any>;
}

export interface ServiceCatalogApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: ServiceCatalogError;
  metadata?: {
    request_id: string;
    execution_time_ms: number;
    environment: 'live' | 'test';
    cache_hit?: boolean;
    rate_limit?: {
      remaining: number;
      reset_time: string;
    };
  };
}

export interface IdempotencyRecord {
  key: string;
  operation_type: string;
  request_hash: string;
  response_data: any;
  created_at: string;
  expires_at: string;
  tenant_id: string;
  user_id: string;
}

export interface RateLimitInfo {
  requests_made: number;
  requests_limit: number;
  window_start: string;
  window_end: string;
  reset_time: string;
  is_limited: boolean;
}

export interface SecurityContext {
  hmac_verified: boolean;
  tenant_verified: boolean;
  user_verified: boolean;
  rate_limit_passed: boolean;
  idempotency_checked: boolean;
  request_signature: string;
  security_headers: Record<string, string>;
}

export interface DatabaseTransaction {
  id: string;
  started_at: string;
  operations: string[];
  row_locks: string[];
  isolation_level: string;
  status: 'active' | 'committed' | 'rolled_back';
}

export interface ServiceCatalogMetrics {
  total_services: number;
  active_services: number;
  services_by_category: Record<string, number>;
  services_by_industry: Record<string, number>;
  avg_service_price: number;
  most_used_services: {
    service_id: string;
    service_name: string;
    usage_count: number;
  }[];
  recent_activities: {
    operation: string;
    service_name: string;
    timestamp: string;
    user_id: string;
  }[];
}

export type ServiceCatalogOperation = 
  | 'create_service'
  | 'get_service'
  | 'update_service'
  | 'delete_service'
  | 'query_services'
  | 'bulk_create_services'
  | 'bulk_update_services'
  | 'associate_resources'
  | 'get_service_resources'
  | 'update_pricing'
  | 'get_master_data'
  | 'get_available_resources';

export const SERVICE_CATALOG_ERROR_CODES = {
  VALIDATION_ERROR: 'VALIDATION_ERROR',
  NOT_FOUND: 'NOT_FOUND',
  DUPLICATE_SKU: 'DUPLICATE_SKU',
  DUPLICATE_NAME: 'DUPLICATE_NAME',
  INVALID_CATEGORY: 'INVALID_CATEGORY',
  INVALID_INDUSTRY: 'INVALID_INDUSTRY',
  INVALID_PRICING: 'INVALID_PRICING',
  RESOURCE_NOT_FOUND: 'RESOURCE_NOT_FOUND',
  INSUFFICIENT_PERMISSIONS: 'INSUFFICIENT_PERMISSIONS',
  RATE_LIMIT_EXCEEDED: 'RATE_LIMIT_EXCEEDED',
  IDEMPOTENCY_CONFLICT: 'IDEMPOTENCY_CONFLICT',
  TRANSACTION_ERROR: 'TRANSACTION_ERROR',
  EXTERNAL_API_ERROR: 'EXTERNAL_API_ERROR',
  SYSTEM_ERROR: 'SYSTEM_ERROR'
} as const;

export const PRICING_MODELS = {
  FIXED: 'fixed',
  TIERED: 'tiered',
  DYNAMIC: 'dynamic'
} as const;

export const BILLING_CYCLES = {
  ONE_TIME: 'one_time',
  HOURLY: 'hourly',
  DAILY: 'daily',
  WEEKLY: 'weekly',
  MONTHLY: 'monthly',
  YEARLY: 'yearly'
} as const;

export const RESOURCE_LOCATION_TYPES = {
  ONSITE: 'onsite',
  REMOTE: 'remote',
  HYBRID: 'hybrid'
} as const;

export const SERVICE_SORT_OPTIONS = {
  NAME: 'name',
  PRICE: 'price',
  CREATED_AT: 'created_at',
  SORT_ORDER: 'sort_order',
  USAGE_COUNT: 'usage_count',
  AVG_RATING: 'avg_rating'
} as const;

export const SORT_DIRECTIONS = {
  ASC: 'asc',
  DESC: 'desc'
} as const;

export const VALIDATION_LIMITS = {
  MAX_SERVICES_PER_BULK: 100,
  MAX_RESOURCES_PER_SERVICE: 50,
  MAX_PRICING_TIERS: 20,
  MAX_TAGS_PER_SERVICE: 10,
  MAX_SEARCH_RESULTS: 1000,
  MIN_SERVICE_NAME_LENGTH: 2,
  MAX_SERVICE_NAME_LENGTH: 255,
  MAX_DESCRIPTION_LENGTH: 2000,
  MAX_SKU_LENGTH: 100
} as const;