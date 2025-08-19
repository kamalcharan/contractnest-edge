// supabase/functions/_shared/catalog/catalogTypes.ts
// ✅ UPDATED: Fixed to match actual database structure and requirements

// =================================================================
// CORE TYPE DEFINITIONS
// =================================================================

// Catalog item types
export type CatalogItemType = 'service' | 'equipment' | 'spare_part' | 'asset';

// Resource types
export type ResourceType = 'team_staff' | 'equipment' | 'consumable' | 'asset' | 'partner';

// Pricing types
export type PricingType = 'fixed' | 'unit_price' | 'hourly' | 'daily';
export type ResourcePricingType = 'fixed' | 'hourly' | 'per_use' | 'daily' | 'monthly' | 'per_unit';

// Resource requirement types
export type ResourceRequirementType = 'required' | 'optional' | 'alternative';

// Status types
export type CatalogItemStatus = 'active' | 'inactive' | 'draft';
export type ResourceStatus = 'active' | 'inactive' | 'maintenance';

// Other core types
export type BillingMode = 'manual' | 'automatic' | 'scheduled';
export type ContentFormat = 'plain' | 'markdown' | 'html';
export type SortDirection = 'asc' | 'desc';
export type TaxDisplayMode = 'inclusive' | 'exclusive' | 'separate';
export type SupportedCurrency = 'INR' | 'USD' | 'EUR' | 'GBP' | 'AED' | 'SGD' | 'CAD' | 'AUD';
export type ServiceComplexityLevel = 'low' | 'medium' | 'high' | 'expert';

// ✅ UPDATED: Contact classifications for team_staff validation
export type ContactClassification = 'Buyer' | 'Seller' | 'Vendor' | 'Partner' | 'Team';

// =================================================================
// PRICING INTERFACES (UPDATED FOR JSONB STORAGE)
// =================================================================

// ✅ NEW: Multi-currency pricing stored in price_attributes JSONB
export interface CurrencyPricing {
  currency: SupportedCurrency;
  amount: number;
  is_base: boolean;
  tax_included: boolean;
  tax_rate_id?: string;
  effective_from?: string;
  effective_to?: string;
}

// ✅ UPDATED: Price attributes stored as JSONB in catalog items
export interface PriceAttributes {
  type: PricingType;
  billing_mode: BillingMode;
  resource_based_pricing?: boolean;
  resource_cost_included?: boolean;
  
  // ✅ NEW: Multi-currency support in JSONB
  currencies: CurrencyPricing[];
  
  // Legacy single currency fields (for backward compatibility)
  base_amount?: number;
  currency?: SupportedCurrency;
  
  // Pricing rules
  hourly_rate?: number;
  daily_rate?: number;
  minimum_charge?: number;
  maximum_charge?: number;
  billing_increment?: number;
}

export interface TaxConfig {
  use_tenant_default: boolean;
  display_mode?: TaxDisplayMode;
  specific_tax_rates: string[];
  tax_exempt?: boolean;
  exemption_reason?: string;
}

export interface ResourceRequirements {
  team_staff: string[]; // Array of resource IDs
  equipment: string[];
  consumables: string[];
  assets: string[];
  partners: string[];
}

export interface ServiceAttributes {
  estimated_duration?: number; // Minutes
  complexity_level: ServiceComplexityLevel;
  requires_customer_presence: boolean;
  location_requirements: string[];
  scheduling_constraints: Record<string, any>;
}

// =================================================================
// RESOURCE INTERFACES
// =================================================================

export interface ResourceTypeInfo {
  id: ResourceType;
  name: string;
  description?: string;
  icon: string;
  pricing_model: ResourcePricingType;
  requires_human_assignment: boolean;
  has_capacity_limits: boolean;
  is_active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export interface ResourceTemplate {
  id: string;
  industry_id: string;
  resource_type_id: ResourceType;
  name: string;
  description?: string;
  default_attributes: Record<string, any>;
  pricing_guidance: Record<string, any>;
  popularity_score: number;
  is_recommended: boolean;
  is_active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export interface Resource {
  id: string;
  tenant_id: string;
  is_live: boolean; // Production/Test segregation
  
  // Resource identification
  resource_type_id: ResourceType;
  name: string;
  description?: string;
  code?: string; // Internal code like 'TECH001'
  
  // Contact integration for human resources
  contact_id?: string; // Links to t_contacts for team_staff
  
  // Resource attributes
  attributes: Record<string, any>;
  availability_config: Record<string, any>;
  
  // Tenant customization
  is_custom: boolean;
  master_template_id?: string;
  
  // Status
  status: ResourceStatus;
  
  // Audit fields
  created_at: string;
  updated_at: string;
  created_by?: string;
  updated_by?: string;
}

export interface ResourcePricing {
  id: string;
  tenant_id: string;
  resource_id: string;
  is_live: boolean;
  
  // Pricing details
  pricing_type: ResourcePricingType;
  currency: SupportedCurrency;
  rate: number;
  
  // Pricing rules
  minimum_charge?: number;
  maximum_charge?: number;
  billing_increment?: number;
  
  // Tax integration
  tax_included: boolean;
  tax_rate_id?: string;
  
  // Validity
  effective_from: string; // Date
  effective_to?: string; // Date
  is_active: boolean;
  
  // Audit
  created_at: string;
  updated_at: string;
}

export interface ServiceResourceRequirement {
  id: string;
  tenant_id: string;
  is_live: boolean;
  
  service_id: string; // References catalog item
  resource_id: string; // References resource
  
  // Requirement details
  requirement_type: ResourceRequirementType;
  quantity_needed: number;
  usage_duration?: number; // Minutes
  usage_notes?: string;
  
  // Alternative grouping
  alternative_group?: string;
  
  // Cost override
  cost_override?: number;
  cost_currency?: SupportedCurrency;
  
  // Audit
  created_at: string;
  created_by?: string;
}

// =================================================================
// CATALOG INTERFACES (UPDATED)
// =================================================================

export interface CatalogItem {
  id: string;
  tenant_id: string;
  is_live: boolean; // Production/Test segregation
  
  // Item classification
  type: CatalogItemType;
  industry_id?: string;
  category_id?: string;
  
  // Basic information
  name: string;
  short_description?: string;
  
  // Rich content
  description_format: ContentFormat;
  description_content?: string;
  terms_format?: ContentFormat;
  terms_content?: string;
  
  // Service hierarchy
  parent_id?: string;
  is_variant: boolean;
  variant_attributes: Record<string, any>;
  
  // ✅ UPDATED: Resource composition (stored as JSONB)
  resource_requirements: ResourceRequirements;
  service_attributes: ServiceAttributes;
  
  // ✅ UPDATED: Pricing stored as JSONB
  price_attributes: PriceAttributes;
  tax_config: TaxConfig;
  
  // Metadata
  metadata: Record<string, any>;
  specifications: Record<string, any>;
  
  // Status
  status: CatalogItemStatus;
  
  // ✅ NEW: Search vector for full-text search
  search_vector?: string;
  
  // Audit fields
  created_at: string;
  updated_at: string;
  created_by?: string;
  updated_by?: string;
}

export interface CatalogItemDetailed extends CatalogItem {
  // Industry information
  industry_name?: string;
  industry_icon?: string;
  
  // Category information
  category_name?: string;
  category_icon?: string;
  
  // Parent information
  parent_name?: string;
  
  // ✅ NEW: Versioning information
  version_number?: number;
  is_current_version?: boolean;
  total_versions?: number;
  
  // Variant count
  variant_count: number;
  
  // Resource information
  linked_resources?: Resource[];
  resource_requirements_details?: ServiceResourceRequirement[];
  estimated_resource_cost?: number;
  
  // ✅ UPDATED: Pricing extracted from JSONB
  base_currency?: SupportedCurrency;
  base_amount?: number;
  available_currencies?: SupportedCurrency[];
  multi_currency_pricing?: CurrencyPricing[];
  
  // Computed fields
  original_id: string;
  pricing_type: PricingType;
  billing_mode: BillingMode;
  use_tenant_default_tax: boolean;
  tax_display_mode?: string;
  specific_tax_count: number;
  environment_label: string;
  effective_price?: number;
}

// ✅ NEW: Versioning support interfaces
export interface CatalogItemVersion {
  id: string;
  original_item_id: string;
  version_number: number;
  version_reason?: string;
  is_current_version: boolean;
  changes_summary?: string;
  created_at: string;
  created_by?: string;
  catalog_item: CatalogItem;
}

// =================================================================
// REQUEST INTERFACES (UPDATED)
// =================================================================

export interface CreateCatalogItemRequest {
  // Required fields
  name: string;
  type: CatalogItemType;
  price_attributes: PriceAttributes;
  
  // Optional content
  short_description?: string;
  description_content?: string;
  description_format?: ContentFormat;
  terms_content?: string;
  terms_format?: ContentFormat;
  
  // Optional service hierarchy
  parent_id?: string;
  is_variant?: boolean;
  variant_attributes?: Record<string, any>;
  
  // Resource composition
  resource_requirements?: ResourceRequirements;
  service_attributes?: ServiceAttributes;
  
  // Optional configuration
  industry_id?: string;
  category_id?: string;
  tax_config?: Partial<TaxConfig>;
  metadata?: Record<string, any>;
  specifications?: Record<string, any>;
  status?: CatalogItemStatus;
  
  // Environment
  is_live?: boolean;
  
  // Transaction support - create resources in same call
  resources?: CreateResourceRequest[];
}

export interface UpdateCatalogItemRequest {
  // ✅ NEW: Version management
  version_reason?: string;
  create_new_version?: boolean;
  
  // Updateable fields
  name?: string;
  short_description?: string;
  description_content?: string;
  description_format?: ContentFormat;
  terms_content?: string;
  terms_format?: ContentFormat;
  price_attributes?: PriceAttributes;
  tax_config?: Partial<TaxConfig>;
  metadata?: Record<string, any>;
  specifications?: Record<string, any>;
  status?: CatalogItemStatus;
  variant_attributes?: Record<string, any>;
  
  // Resource updates
  resource_requirements?: ResourceRequirements;
  service_attributes?: ServiceAttributes;
  
  // Transaction support
  add_resources?: CreateResourceRequest[];
  update_resources?: UpdateResourceRequest[];
  remove_resources?: string[]; // Resource IDs to remove
}

// ✅ NEW: Restore request interface
export interface RestoreCatalogItemRequest {
  catalog_id: string;
  restore_reason?: string;
  restore_to_version?: number;
}

export interface CreateResourceRequest {
  resource_type_id: ResourceType;
  name: string;
  description?: string;
  code?: string;
  contact_id?: string; // For team_staff resources
  attributes?: Record<string, any>;
  availability_config?: Record<string, any>;
  status?: ResourceStatus;
  
  // Pricing can be included
  pricing?: CreateResourcePricingRequest[];
}

export interface UpdateResourceRequest {
  id: string;
  name?: string;
  description?: string;
  code?: string;
  contact_id?: string;
  attributes?: Record<string, any>;
  availability_config?: Record<string, any>;
  status?: ResourceStatus;
}

export interface CreateResourcePricingRequest {
  pricing_type: ResourcePricingType;
  currency: SupportedCurrency;
  rate: number;
  minimum_charge?: number;
  maximum_charge?: number;
  billing_increment?: number;
  tax_included?: boolean;
  tax_rate_id?: string;
  effective_from?: string;
  effective_to?: string;
}

export interface UpdateResourcePricingRequest {
  id: string;
  pricing_type?: ResourcePricingType;
  currency?: SupportedCurrency;
  rate?: number;
  minimum_charge?: number;
  maximum_charge?: number;
  billing_increment?: number;
  tax_included?: boolean;
  tax_rate_id?: string;
  effective_from?: string;
  effective_to?: string;
}

export interface AddResourceRequirementRequest {
  resource_id: string;
  requirement_type: ResourceRequirementType;
  quantity_needed: number;
  usage_duration?: number;
  usage_notes?: string;
  alternative_group?: string;
  cost_override?: number;
  cost_currency?: SupportedCurrency;
}

export interface UpdateResourceRequirementRequest {
  id: string;
  requirement_type?: ResourceRequirementType;
  quantity_needed?: number;
  usage_duration?: number;
  usage_notes?: string;
  alternative_group?: string;
  cost_override?: number;
  cost_currency?: SupportedCurrency;
}

// ✅ NEW: Multi-currency pricing operations (JSONB-based)
export interface UpdateCatalogItemPricingRequest {
  catalog_id: string;
  currencies: CurrencyPricing[];
  pricing_type?: PricingType;
  billing_mode?: BillingMode;
  update_reason?: string;
}

export interface AddCurrencyToCatalogItemRequest {
  catalog_id: string;
  currency_pricing: CurrencyPricing;
}

export interface UpdateCurrencyPricingRequest {
  catalog_id: string;
  currency: SupportedCurrency;
  amount?: number;
  tax_included?: boolean;
  tax_rate_id?: string;
  effective_from?: string;
  effective_to?: string;
  update_reason?: string;
}

export interface RemoveCurrencyFromCatalogItemRequest {
  catalog_id: string;
  currency: SupportedCurrency;
  removal_reason?: string;
}

// =================================================================
// QUERY INTERFACES (UPDATED)
// =================================================================

export interface CatalogListParams {
  type?: CatalogItemType;
  includeInactive?: boolean;
  search?: string;
  page?: number;
  limit?: number;
  sortBy?: 'name' | 'created_at' | 'updated_at' | 'type';
  sortOrder?: SortDirection;
  is_live?: boolean; // Production/Test filtering
  
  // ✅ NEW: Version filtering
  current_versions_only?: boolean;
  include_versions?: boolean;
  
  // Resource-based filtering
  hasResources?: boolean;
  resourceTypes?: ResourceType[];
  complexityLevel?: ServiceComplexityLevel;
  estimatedDuration?: {
    min?: number;
    max?: number;
  };
  
  // ✅ NEW: Pricing filtering
  hasPricing?: boolean;
  currencies?: SupportedCurrency[];
  priceRange?: {
    min?: number;
    max?: number;
    currency?: SupportedCurrency;
  };
}

export interface ResourceListParams {
  resourceType?: ResourceType;
  search?: string;
  page?: number;
  limit?: number;
  sortBy?: 'name' | 'created_at' | 'resource_type_id';
  sortOrder?: SortDirection;
  is_live?: boolean;
  status?: ResourceStatus;
  hasContact?: boolean; // For team_staff resources
  hasPricing?: boolean;
  availableOnly?: boolean;
}

export interface CatalogItemQuery {
  filters?: CatalogItemFilters;
  sort?: CatalogItemSort[];
  pagination?: {
    page: number;
    limit: number;
  };
  include_related?: boolean;
  include_versions?: boolean;
  include_variants?: boolean;
  include_resources?: boolean;
}

export interface CatalogItemFilters {
  // Basic filters
  type?: CatalogItemType | CatalogItemType[];
  status?: CatalogItemStatus | CatalogItemStatus[];
  is_active?: boolean;
  is_live?: boolean; // Production/Test filtering
  
  // Text search
  search?: string;
  search_query?: string;
  
  // Service hierarchy
  parent_id?: string;
  is_variant?: boolean;
  include_variants?: boolean;
  
  // ✅ UPDATED: Pricing filters (JSONB-based)
  pricing_type?: PricingType | PricingType[];
  min_price?: number;
  max_price?: number;
  currency?: SupportedCurrency;
  currencies?: SupportedCurrency[];
  has_multi_currency?: boolean;
  
  // Resource filters
  has_resources?: boolean;
  resource_types?: ResourceType[];
  complexity_level?: ServiceComplexityLevel;
  requires_customer_presence?: boolean;
  estimated_duration?: {
    min?: number;
    max?: number;
  };
  
  // ✅ NEW: Version filters
  current_versions_only?: boolean;
  include_inactive?: boolean;
  version_number?: number;
  
  // Date filters
  created_after?: string;
  created_before?: string;
  updated_after?: string;
  updated_before?: string;
  created_by?: string;
}

export interface CatalogItemSort {
  field: 'name' | 'created_at' | 'updated_at' | 'base_amount' | 'type' | 'status';
  direction: SortDirection;
}

// =================================================================
// RESPONSE INTERFACES (UPDATED)
// =================================================================

export interface ServiceResponse<T> {
  success: boolean;
  data?: T;
  message?: string;
  error?: string;
  
  // ✅ NEW: Enhanced version info
  version_info?: {
    version_number: number;
    is_current_version: boolean;
    total_versions: number;
    version_reason?: string;
    previous_version?: number;
    next_version?: number;
  };
  
  pagination?: {
    total: number;
    page: number;
    limit: number;
    has_more: boolean;
    totalPages?: number;
  };
}

export interface CatalogListResponse {
  items: CatalogItemDetailed[];
  pagination: {
    page: number;
    limit: number;
    total: number;
    totalPages: number;
    has_more?: boolean;
  };
  resource_summary?: {
    total_resources: number;
    by_type: Record<ResourceType, number>;
    with_pricing: number;
  };
  
  // ✅ NEW: Pricing summary
  pricing_summary?: {
    total_with_pricing: number;
    currencies_used: SupportedCurrency[];
    multi_currency_items: number;
  };
}

export interface ResourceListResponse {
  resources: Resource[];
  pagination: {
    page: number;
    limit: number;
    total: number;
    totalPages: number;
  };
}

export interface ResourceDetailsResponse {
  resource: Resource;
  pricing: ResourcePricing[];
  linked_services: CatalogItemDetailed[];
  contact_info?: {
    id: string;
    name: string;
    email?: string;
    phone?: string;
    classifications: ContactClassification[];
  };
}

export interface TenantResourcesResponse {
  resources_by_type: Record<ResourceType, number>;
  total_resources: number;
  active_resources: number;
  resources_with_pricing: number;
  team_staff_with_contacts: number;
}

// ✅ NEW: Catalog item pricing responses (JSONB-based)
export interface TenantCurrenciesResponse {
  currencies: SupportedCurrency[];
  statistics: Record<string, number>;
  items_by_currency: Record<SupportedCurrency, number>;
  multi_currency_items: number;
  total_items: number;
}

export interface CatalogPricingDetailsResponse {
  catalog_id: string;
  pricing_type: PricingType;
  billing_mode: BillingMode;
  currencies: CurrencyPricing[];
  base_currency?: SupportedCurrency;
  total_currencies: number;
  has_multi_currency: boolean;
  estimated_resource_cost?: number;
}

// ✅ NEW: Version history response
export interface CatalogVersionHistoryResponse {
  original_item_id: string;
  current_version: number;
  total_versions: number;
  versions: CatalogItemVersion[];
}

// =================================================================
// ERROR HANDLING (UPDATED)
// =================================================================

export class CatalogError extends Error {
  constructor(
    message: string,
    public code: string,
    public statusCode: number = 500
  ) {
    super(message);
    this.name = 'CatalogError';
  }
}

export class ValidationError extends CatalogError {
  constructor(
    message: string,
    public validationErrors: Array<{ field: string; message: string }>
  ) {
    super(message, 'VALIDATION_ERROR', 400);
    this.name = 'ValidationError';
  }
}

export class NotFoundError extends CatalogError {
  constructor(resource: string, id: string) {
    super(`${resource} with ID ${id} not found`, 'NOT_FOUND', 404);
    this.name = 'NotFoundError';
  }
}

export class ConflictError extends CatalogError {
  constructor(message: string) {
    super(message, 'CONFLICT', 409);
    this.name = 'ConflictError';
  }
}

export class ResourceError extends CatalogError {
  constructor(message: string, code: string = 'RESOURCE_ERROR') {
    super(message, code, 400);
    this.name = 'ResourceError';
  }
}

export class ContactValidationError extends ResourceError {
  constructor(contactId: string, reason?: string) {
    super(
      `Contact ${contactId} is not eligible for team_staff resource${reason ? `: ${reason}` : ''}`, 
      'INVALID_CONTACT'
    );
    this.name = 'ContactValidationError';
  }
}

// ✅ NEW: Pricing-specific errors
export class PricingError extends CatalogError {
  constructor(message: string, code: string = 'PRICING_ERROR') {
    super(message, code, 400);
    this.name = 'PricingError';
  }
}

export class CurrencyError extends PricingError {
  constructor(currency: string, reason: string) {
    super(`Currency ${currency} error: ${reason}`, 'CURRENCY_ERROR');
    this.name = 'CurrencyError';
  }
}

// ✅ NEW: Versioning errors
export class VersionError extends CatalogError {
  constructor(message: string, code: string = 'VERSION_ERROR') {
    super(message, code, 400);
    this.name = 'VersionError';
  }
}

// =================================================================
// UTILITY FUNCTIONS AND TYPE GUARDS (UPDATED)
// =================================================================

export function isTeamStaffResource(resource: Resource): boolean {
  return resource.resource_type_id === 'team_staff';
}

export function isHumanResource(resourceType: ResourceType): boolean {
  return resourceType === 'team_staff' || resourceType === 'partner';
}

export function requiresContact(resourceType: ResourceType): boolean {
  return resourceType === 'team_staff';
}

// ✅ UPDATED: Contact classification validation
export function isValidContactClassification(classification: string): classification is ContactClassification {
  return ['Buyer', 'Seller', 'Vendor', 'Partner', 'Team'].includes(classification);
}

export function isContactEligibleForTeamStaff(classifications: string[]): boolean {
  return classifications.some(c => isValidContactClassification(c) && c === 'Team');
}

export function isCatalogItem(obj: any): obj is CatalogItem {
  return obj && typeof obj === 'object' && 
         typeof obj.id === 'string' && 
         typeof obj.tenant_id === 'string' &&
         ['service', 'equipment', 'spare_part', 'asset'].includes(obj.type);
}

export function isResource(obj: any): obj is Resource {
  return obj && typeof obj === 'object' && 
         typeof obj.id === 'string' && 
         typeof obj.tenant_id === 'string' &&
         ['team_staff', 'equipment', 'consumable', 'asset', 'partner'].includes(obj.resource_type_id);
}

export function isServiceResponse<T>(response: any): response is ServiceResponse<T> {
  return typeof response === 'object' && 
         response !== null && 
         typeof response.success === 'boolean';
}

export function validateResourceRequirements(requirements: ResourceRequirements): boolean {
  const requiredTypes: (keyof ResourceRequirements)[] = ['team_staff', 'equipment', 'consumables', 'assets', 'partners'];
  return requiredTypes.every(type => Array.isArray(requirements[type]));
}

export function validateServiceAttributes(attributes: ServiceAttributes): boolean {
  return typeof attributes.complexity_level === 'string' &&
         ['low', 'medium', 'high', 'expert'].includes(attributes.complexity_level) &&
         typeof attributes.requires_customer_presence === 'boolean' &&
         Array.isArray(attributes.location_requirements);
}

// ✅ NEW: Multi-currency validation utilities
export function validateCurrencyPricing(pricing: CurrencyPricing): { isValid: boolean; errors: string[] } {
  const errors: string[] = [];
  
  if (!pricing.currency || !['INR', 'USD', 'EUR', 'GBP', 'AED', 'SGD', 'CAD', 'AUD'].includes(pricing.currency)) {
    errors.push('Invalid currency');
  }
  
  if (typeof pricing.amount !== 'number' || pricing.amount < 0) {
    errors.push('Amount must be a positive number');
  }
  
  if (typeof pricing.is_base !== 'boolean') {
    errors.push('is_base must be a boolean');
  }
  
  if (typeof pricing.tax_included !== 'boolean') {
    errors.push('tax_included must be a boolean');
  }
  
  return { isValid: errors.length === 0, errors };
}

export function validatePriceAttributes(priceAttributes: PriceAttributes): { isValid: boolean; errors: string[] } {
  const errors: string[] = [];
  
  if (!['fixed', 'unit_price', 'hourly', 'daily'].includes(priceAttributes.type)) {
    errors.push('Invalid pricing type');
  }
  
  if (!['manual', 'automatic', 'scheduled'].includes(priceAttributes.billing_mode)) {
    errors.push('Invalid billing mode');
  }
  
  if (!Array.isArray(priceAttributes.currencies)) {
    errors.push('Currencies must be an array');
  } else {
    const baseCurrencies = priceAttributes.currencies.filter(c => c.is_base);
    if (baseCurrencies.length !== 1) {
      errors.push('Exactly one base currency is required');
    }
    
    priceAttributes.currencies.forEach((currency, index) => {
      const validation = validateCurrencyPricing(currency);
      if (!validation.isValid) {
        errors.push(`Currency ${index}: ${validation.errors.join(', ')}`);
      }
    });
  }
  
  return { isValid: errors.length === 0, errors };
}

// ✅ NEW: Versioning utilities
export function generateVersionNumber(existingVersions: number[]): number {
  return existingVersions.length > 0 ? Math.max(...existingVersions) + 1 : 1;
}

export function shouldCreateNewVersion(updateData: UpdateCatalogItemRequest): boolean {
  return updateData.create_new_version === true || 
         (updateData.name !== undefined || 
          updateData.description_content !== undefined ||
          updateData.price_attributes !== undefined);
}

// =================================================================
// CONSTANTS (UPDATED)
// =================================================================

export const PAGINATION_DEFAULTS = {
  PAGE: 1,
  LIMIT: 20,
  MAX_LIMIT: 100
} as const;

export const RESOURCE_PRICING_MODELS: Record<ResourceType, ResourcePricingType[]> = {
  'team_staff': ['hourly', 'daily', 'fixed'],
  'equipment': ['hourly', 'per_use', 'daily'],
  'consumable': ['per_unit', 'fixed'],
  'asset': ['hourly', 'daily', 'monthly'],
  'partner': ['fixed', 'hourly', 'per_use']
};

export const DEFAULT_SERVICE_ATTRIBUTES: ServiceAttributes = {
  estimated_duration: undefined,
  complexity_level: 'medium',
  requires_customer_presence: false,
  location_requirements: [],
  scheduling_constraints: {}
};

export const DEFAULT_RESOURCE_REQUIREMENTS: ResourceRequirements = {
  team_staff: [],
  equipment: [],
  consumables: [],
  assets: [],
  partners: []
};

// ✅ NEW: Contact classification constants
export const VALID_CONTACT_CLASSIFICATIONS: ContactClassification[] = [
  'Buyer', 'Seller', 'Vendor', 'Partner', 'Team'
];

export const TEAM_STAFF_ELIGIBLE_CLASSIFICATIONS: ContactClassification[] = [
  'Team', 'Partner' // Team is primary, Partner can also be team_staff
];

// ✅ NEW: Currency and pricing constants
export const SUPPORTED_CURRENCIES: SupportedCurrency[] = [
  'INR', 'USD', 'EUR', 'GBP', 'AED', 'SGD', 'CAD', 'AUD'
];

export const DEFAULT_PRICE_ATTRIBUTES: PriceAttributes = {
  type: 'fixed',
  billing_mode: 'manual',
  currencies: [{
    currency: 'INR',
    amount: 0,
    is_base: true,
    tax_included: false
  }]
};

// =================================================================
// SERVICE CONFIGURATION (UPDATED)
// =================================================================

export interface CatalogServiceConfig {
  tenant_id: string;
  user_id: string;
  is_live: boolean; // Default to true
  audit_logger?: any;
}

// =================================================================
// VALIDATION FUNCTION EXPORTS
// =================================================================

// Legacy validation functions (updated for new structure)
export function validateCurrency(currency: string): { isValid: boolean; error?: string } {
  if (!currency || typeof currency !== 'string') {
    return { isValid: false, error: 'Currency is required and must be a string' };
  }
  
  if (!SUPPORTED_CURRENCIES.includes(currency.toUpperCase() as SupportedCurrency)) {
    return { isValid: false, error: `Currency ${currency} is not supported. Supported currencies: ${SUPPORTED_CURRENCIES.join(', ')}` };
  }
  
  return { isValid: true };
}

export function validatePrice(price: number): { isValid: boolean; error?: string } {
  if (typeof price !== 'number') {
    return { isValid: false, error: 'Price must be a number' };
  }
  
  if (price < 0) {
    return { isValid: false, error: 'Price cannot be negative' };
  }
  
  if (!isFinite(price)) {
    return { isValid: false, error: 'Price must be a finite number' };
  }
  
  return { isValid: true };
}

export function validateCatalogType(type: string): { isValid: boolean; error?: string } {
  if (!type || typeof type !== 'string') {
    return { isValid: false, error: 'Catalog type is required and must be a string' };
  }
  
  if (!['service', 'equipment', 'spare_part', 'asset'].includes(type)) {
    return { isValid: false, error: 'Invalid catalog type. Must be: service, equipment, spare_part, or asset' };
  }
  
  return { isValid: true };
}

export function validatePriceType(priceType: string): { isValid: boolean; error?: string } {
  if (!priceType || typeof priceType !== 'string') {
    return { isValid: false, error: 'Price type is required and must be a string' };
  }
  
  if (!['fixed', 'unit_price', 'hourly', 'daily'].includes(priceType)) {
    return { isValid: false, error: 'Invalid price type. Must be: fixed, unit_price, hourly, or daily' };
  }
  
  return { isValid: true };
}

// =================================================================
// EXPORT ALL TYPES
// =================================================================

export type {
  // Core types
  CatalogItemType,
  ResourceType,
  PricingType,
  ResourcePricingType,
  ResourceRequirementType,
  CatalogItemStatus,
  ResourceStatus,
  BillingMode,
  ContentFormat,
  SortDirection,
  TaxDisplayMode,
  SupportedCurrency,
  ServiceComplexityLevel,
  ContactClassification,
  
  // Pricing interfaces
  CurrencyPricing,
  PriceAttributes,
  TaxConfig,
  
  // Main interfaces
  CatalogItem,
  CatalogItemDetailed,
  CatalogItemVersion,
  Resource,
  ResourcePricing,
  ServiceResourceRequirement,
  ResourceRequirements,
  ServiceAttributes,
  
  // Request interfaces
  CreateCatalogItemRequest,
  UpdateCatalogItemRequest,
  RestoreCatalogItemRequest,
  CreateResourceRequest,
  UpdateResourceRequest,
  CreateResourcePricingRequest,
  UpdateResourcePricingRequest,
  AddResourceRequirementRequest,
  UpdateResourceRequirementRequest,
  UpdateCatalogItemPricingRequest,
  AddCurrencyToCatalogItemRequest,
  UpdateCurrencyPricingRequest,
  RemoveCurrencyFromCatalogItemRequest,
  
  // Query interfaces
  CatalogListParams,
  ResourceListParams,
  CatalogItemQuery,
  CatalogItemFilters,
  CatalogItemSort,
  
  // Response interfaces
  ServiceResponse,
  CatalogListResponse,
  ResourceListResponse,
  ResourceDetailsResponse,
  TenantResourcesResponse,
  TenantCurrenciesResponse,
  CatalogPricingDetailsResponse,
  CatalogVersionHistoryResponse,
  
  // Config
  CatalogServiceConfig
};