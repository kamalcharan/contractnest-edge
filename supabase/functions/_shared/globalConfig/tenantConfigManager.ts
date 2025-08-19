// File: supabase/functions/_shared/globalConfig/tenantConfigManager.ts

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import {
  GlobalTenantConfiguration,
  EdgeFunctionConfig,
  GlobalSettings,
  TenantContext,
  ConfigCache,
  EdgeFunction,
  PlanType,
  ConfigError,
  DEFAULT_CONFIGS,
  DEFAULT_GLOBAL_SETTINGS,
  CONFIG_ERROR_CODES
} from './types.ts';

export class TenantConfigManager {
  private static instance: TenantConfigManager;
  private cache: ConfigCache = {};
  private readonly CACHE_TTL = 15 * 60 * 1000; // 15 minutes
  private readonly MAX_CACHE_SIZE = 1000;

  constructor(private supabase: SupabaseClient) {
    console.log('🏗️ TenantConfigManager - initialized');
  }

  static getInstance(supabase: SupabaseClient): TenantConfigManager {
    if (!TenantConfigManager.instance) {
      TenantConfigManager.instance = new TenantConfigManager(supabase);
    }
    return TenantConfigManager.instance;
  }

  /**
   * Get configuration for a specific tenant and edge function
   */
  async getConfig(tenantId: string, edgeFunction: EdgeFunction): Promise<{
    config: EdgeFunctionConfig;
    globalSettings: GlobalSettings;
    planType: PlanType;
  }> {
    console.log('🔧 TenantConfigManager - getting config:', {
      tenantId,
      edgeFunction
    });

    const cacheKey = `${tenantId}:${edgeFunction}`;

    // Check cache first
    const cached = this.getCachedConfig(cacheKey);
    if (cached) {
      console.log('✅ TenantConfigManager - config retrieved from cache');
      return {
        config: cached.config,
        globalSettings: cached.globalSettings,
        planType: cached.globalSettings.plan_type
      };
    }

    try {
      // Fetch from database
      const [edgeConfig, globalConfig] = await Promise.all([
        this.fetchEdgeFunctionConfig(tenantId, edgeFunction),
        this.fetchGlobalSettings(tenantId)
      ]);

      const planType = globalConfig?.plan_type || 'professional';
      const config = edgeConfig?.config || this.getDefaultConfig(edgeFunction, planType);
      const globalSettings = globalConfig || this.getDefaultGlobalSettings(tenantId, planType);

      // Cache the result
      this.setCachedConfig(cacheKey, config, globalSettings);

      console.log('✅ TenantConfigManager - config retrieved from database:', {
        tenantId,
        edgeFunction,
        planType,
        configSource: edgeConfig ? 'database' : 'default',
        globalSource: globalConfig ? 'database' : 'default'
      });

      return { config, globalSettings, planType };

    } catch (error) {
      console.error('❌ TenantConfigManager - config fetch error:', error);
      
      // Fallback to defaults
      const planType: PlanType = 'professional';
      const config = this.getDefaultConfig(edgeFunction, planType);
      const globalSettings = this.getDefaultGlobalSettings(tenantId, planType);

      return { config, globalSettings, planType };
    }
  }

  /**
   * Get configuration for multiple edge functions at once
   */
  async getMultipleConfigs(tenantId: string, edgeFunctions: EdgeFunction[]): Promise<{
    configs: Record<EdgeFunction, EdgeFunctionConfig>;
    globalSettings: GlobalSettings;
    planType: PlanType;
  }> {
    console.log('🔧 TenantConfigManager - getting multiple configs:', {
      tenantId,
      edgeFunctions
    });

    const configs: Record<EdgeFunction, EdgeFunctionConfig> = {} as any;
    let globalSettings: GlobalSettings;
    let planType: PlanType;

    // Get global settings once
    const globalConfig = await this.fetchGlobalSettings(tenantId);
    planType = globalConfig?.plan_type || 'professional';
    globalSettings = globalConfig || this.getDefaultGlobalSettings(tenantId, planType);

    // Get configs for each edge function
    for (const edgeFunction of edgeFunctions) {
      const cacheKey = `${tenantId}:${edgeFunction}`;
      const cached = this.getCachedConfig(cacheKey);
      
      if (cached) {
        configs[edgeFunction] = cached.config;
      } else {
        try {
          const edgeConfig = await this.fetchEdgeFunctionConfig(tenantId, edgeFunction);
          const config = edgeConfig?.config || this.getDefaultConfig(edgeFunction, planType);
          configs[edgeFunction] = config;
          
          // Cache it
          this.setCachedConfig(cacheKey, config, globalSettings);
        } catch (error) {
          console.warn(`⚠️ TenantConfigManager - error loading config for ${edgeFunction}:`, error);
          configs[edgeFunction] = this.getDefaultConfig(edgeFunction, planType);
        }
      }
    }

    console.log('✅ TenantConfigManager - multiple configs retrieved:', {
      tenantId,
      configsCount: Object.keys(configs).length,
      planType
    });

    return { configs, globalSettings, planType };
  }

  /**
   * Update configuration for a tenant and edge function
   */
  async updateConfig(
    tenantId: string,
    edgeFunction: EdgeFunction,
    config: Partial<EdgeFunctionConfig>,
    planType?: PlanType
  ): Promise<void> {
    console.log('🔄 TenantConfigManager - updating config:', {
      tenantId,
      edgeFunction,
      planType
    });

    try {
      const { error } = await this.supabase
        .from('edge_tenant_configurations')
        .upsert({
          tenant_id: tenantId,
          edge_function: edgeFunction,
          plan_type: planType || 'professional',
          config,
          updated_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ TenantConfigManager - config update error:', error);
        throw error;
      }

      // Invalidate cache
      const cacheKey = `${tenantId}:${edgeFunction}`;
      delete this.cache[cacheKey];

      console.log('✅ TenantConfigManager - config updated successfully');

    } catch (error) {
      console.error('❌ TenantConfigManager - config update failed:', error);
      throw error;
    }
  }

  /**
   * Update global settings for a tenant
   */
  async updateGlobalSettings(
    tenantId: string,
    settings: Partial<Omit<GlobalSettings, 'tenant_id' | 'created_at' | 'updated_at'>>
  ): Promise<void> {
    console.log('🔄 TenantConfigManager - updating global settings:', {
      tenantId
    });

    try {
      const { error } = await this.supabase
        .from('edge_global_settings')
        .upsert({
          tenant_id: tenantId,
          ...settings,
          updated_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ TenantConfigManager - global settings update error:', error);
        throw error;
      }

      // Invalidate all cache entries for this tenant
      this.invalidateTenantCache(tenantId);

      console.log('✅ TenantConfigManager - global settings updated successfully');

    } catch (error) {
      console.error('❌ TenantConfigManager - global settings update failed:', error);
      throw error;
    }
  }

  /**
   * Create default configuration for a new tenant
   */
  async initializeTenantConfig(tenantId: string, planType: PlanType): Promise<void> {
    console.log('🏗️ TenantConfigManager - initializing tenant config:', {
      tenantId,
      planType
    });

    try {
      // Create global settings
      const { error: globalError } = await this.supabase
        .from('edge_global_settings')
        .insert({
          tenant_id: tenantId,
          ...DEFAULT_GLOBAL_SETTINGS[planType],
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        });

      if (globalError) {
        console.error('❌ TenantConfigManager - global settings creation error:', globalError);
        throw globalError;
      }

      console.log('✅ TenantConfigManager - tenant config initialized successfully');

    } catch (error) {
      console.error('❌ TenantConfigManager - tenant config initialization failed:', error);
      throw error;
    }
  }

  /**
   * Check if a tenant has custom configuration
   */
  async hasCustomConfig(tenantId: string, edgeFunction: EdgeFunction): Promise<boolean> {
    try {
      const { data, error } = await this.supabase
        .from('edge_tenant_configurations')
        .select('tenant_id')
        .eq('tenant_id', tenantId)
        .eq('edge_function', edgeFunction)
        .eq('is_active', true)
        .single();

      if (error && error.code !== 'PGRST116') {
        throw error;
      }

      return !!data;
    } catch (error) {
      console.error('❌ TenantConfigManager - custom config check failed:', error);
      return false;
    }
  }

  /**
   * Get all edge functions for a tenant
   */
  async getTenantEdgeFunctions(tenantId: string): Promise<EdgeFunction[]> {
    try {
      const { data, error } = await this.supabase
        .from('edge_tenant_configurations')
        .select('edge_function')
        .eq('tenant_id', tenantId)
        .eq('is_active', true);

      if (error) {
        throw error;
      }

      return data?.map(row => row.edge_function as EdgeFunction) || [];
    } catch (error) {
      console.error('❌ TenantConfigManager - edge functions fetch failed:', error);
      return [];
    }
  }

  /**
   * Invalidate cache for a specific tenant
   */
  invalidateTenantCache(tenantId: string): void {
    console.log('🗑️ TenantConfigManager - invalidating tenant cache:', { tenantId });

    const keysToDelete = Object.keys(this.cache).filter(key => key.startsWith(`${tenantId}:`));
    keysToDelete.forEach(key => delete this.cache[key]);

    console.log('✅ TenantConfigManager - tenant cache invalidated:', {
      tenantId,
      keysRemoved: keysToDelete.length
    });
  }

  /**
   * Clear all cache
   */
  clearCache(): void {
    console.log('🗑️ TenantConfigManager - clearing all cache');
    this.cache = {};
    console.log('✅ TenantConfigManager - all cache cleared');
  }

  /**
   * Get cache statistics
   */
  getCacheStats(): {
    totalEntries: number;
    cacheHits: number;
    cacheMisses: number;
    oldestEntry: number;
    newestEntry: number;
  } {
    const entries = Object.values(this.cache);
    const now = Date.now();

    return {
      totalEntries: entries.length,
      cacheHits: 0, // TODO: Implement cache hit/miss tracking
      cacheMisses: 0,
      oldestEntry: entries.length > 0 ? Math.min(...entries.map(e => e.cachedAt)) : now,
      newestEntry: entries.length > 0 ? Math.max(...entries.map(e => e.cachedAt)) : now
    };
  }

  // Private methods

  private async fetchEdgeFunctionConfig(tenantId: string, edgeFunction: EdgeFunction): Promise<GlobalTenantConfiguration | null> {
    const { data, error } = await this.supabase
      .from('edge_tenant_configurations')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('edge_function', edgeFunction)
      .eq('is_active', true)
      .single();

    if (error && error.code !== 'PGRST116') {
      throw error;
    }

    return data;
  }

  private async fetchGlobalSettings(tenantId: string): Promise<GlobalSettings | null> {
    const { data, error } = await this.supabase
      .from('edge_global_settings')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .single();

    if (error && error.code !== 'PGRST116') {
      throw error;
    }

    return data;
  }

  private getDefaultConfig(edgeFunction: EdgeFunction, planType: PlanType): EdgeFunctionConfig {
    // You can customize defaults per edge function here
    const baseConfig = DEFAULT_CONFIGS[planType];
    
    // Edge function specific customizations
    switch (edgeFunction) {
      case 'service-catalog':
        return {
          ...baseConfig,
          rate_limits: {
            ...baseConfig.rate_limits,
            search: { requests: baseConfig.rate_limits.list.requests * 2, windowMinutes: 60 }
          }
        };
      case 'contacts':
        return {
          ...baseConfig,
          bulk_operation_limits: {
            ...baseConfig.bulk_operation_limits!,
            max_items_per_bulk: baseConfig.bulk_operation_limits!.max_items_per_bulk * 2
          }
        };
      default:
        return baseConfig;
    }
  }

  private getDefaultGlobalSettings(tenantId: string, planType: PlanType): GlobalSettings {
    return {
      tenant_id: tenantId,
      ...DEFAULT_GLOBAL_SETTINGS[planType],
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };
  }

  private getCachedConfig(cacheKey: string): { config: EdgeFunctionConfig; globalSettings: GlobalSettings } | null {
    const cached = this.cache[cacheKey];
    
    if (!cached) {
      return null;
    }

    const now = Date.now();
    if (now > cached.cachedAt + cached.ttl) {
      delete this.cache[cacheKey];
      return null;
    }

    return {
      config: cached.config,
      globalSettings: cached.globalSettings
    };
  }

  private setCachedConfig(cacheKey: string, config: EdgeFunctionConfig, globalSettings: GlobalSettings): void {
    // Evict oldest entries if cache is full
    if (Object.keys(this.cache).length >= this.MAX_CACHE_SIZE) {
      this.evictOldestCacheEntry();
    }

    this.cache[cacheKey] = {
      config,
      globalSettings,
      cachedAt: Date.now(),
      ttl: this.CACHE_TTL
    };
  }

  private evictOldestCacheEntry(): void {
    let oldestKey: string | null = null;
    let oldestTime = Date.now();

    for (const [key, entry] of Object.entries(this.cache)) {
      if (entry.cachedAt < oldestTime) {
        oldestTime = entry.cachedAt;
        oldestKey = key;
      }
    }

    if (oldestKey) {
      delete this.cache[oldestKey];
    }
  }
}