//supabase/functions/_shared/serviceCatalog/serviceCatalogCache.ts

interface CacheEntry<T> {
  data: T;
  timestamp: number;
  ttl: number;
  hits: number;
  lastAccessed: number;
  tags: string[];
}

interface CacheStats {
  total_entries: number;
  hits: number;
  misses: number;
  hit_rate: number;
  memory_usage_mb: number;
  oldest_entry: number;
  newest_entry: number;
}

export class ServiceCatalogCache {
  private static instance: ServiceCatalogCache;
  private cache: Map<string, CacheEntry<any>> = new Map();
  private stats = {
    hits: 0,
    misses: 0,
    sets: 0,
    deletes: 0,
    evictions: 0
  };

  private readonly MAX_CACHE_SIZE = 1000;
  private readonly DEFAULT_TTL = 15 * 60 * 1000; // 15 minutes
  private readonly CLEANUP_INTERVAL = 5 * 60 * 1000; // 5 minutes
  private cleanupTimer?: number;

  constructor() {
    this.startCleanupTimer();
    console.log('🗄️ Cache - ServiceCatalogCache initialized');
  }

  static getInstance(): ServiceCatalogCache {
    if (!ServiceCatalogCache.instance) {
      ServiceCatalogCache.instance = new ServiceCatalogCache();
    }
    return ServiceCatalogCache.instance;
  }

  async get<T>(key: string): Promise<T | null> {
    console.log('🗄️ Cache - attempting to get:', { key: this.maskKey(key) });

    const entry = this.cache.get(key);
    
    if (!entry) {
      this.stats.misses++;
      console.log('❌ Cache - cache miss:', { key: this.maskKey(key) });
      return null;
    }

    const now = Date.now();
    
    if (now > entry.timestamp + entry.ttl) {
      this.cache.delete(key);
      this.stats.misses++;
      this.stats.evictions++;
      console.log('⏰ Cache - entry expired and removed:', { key: this.maskKey(key) });
      return null;
    }

    entry.hits++;
    entry.lastAccessed = now;
    this.stats.hits++;
    
    console.log('✅ Cache - cache hit:', { 
      key: this.maskKey(key), 
      hits: entry.hits,
      age_minutes: Math.round((now - entry.timestamp) / 60000)
    });

    return entry.data;
  }

  async set<T>(key: string, data: T, ttl?: number, tags: string[] = []): Promise<void> {
    console.log('🗄️ Cache - setting cache entry:', { 
      key: this.maskKey(key), 
      ttl_minutes: Math.round((ttl || this.DEFAULT_TTL) / 60000),
      tags: tags.length
    });

    if (this.cache.size >= this.MAX_CACHE_SIZE) {
      this.evictLeastUsed();
    }

    const now = Date.now();
    const entry: CacheEntry<T> = {
      data,
      timestamp: now,
      ttl: ttl || this.DEFAULT_TTL,
      hits: 0,
      lastAccessed: now,
      tags
    };

    this.cache.set(key, entry);
    this.stats.sets++;

    console.log('✅ Cache - entry cached successfully:', { 
      key: this.maskKey(key),
      cache_size: this.cache.size 
    });
  }

  async delete(key: string): Promise<boolean> {
    console.log('🗄️ Cache - deleting cache entry:', { key: this.maskKey(key) });

    const deleted = this.cache.delete(key);
    
    if (deleted) {
      this.stats.deletes++;
      console.log('✅ Cache - entry deleted successfully:', { key: this.maskKey(key) });
    } else {
      console.log('⚠️ Cache - entry not found for deletion:', { key: this.maskKey(key) });
    }

    return deleted;
  }

  async invalidateByTag(tag: string): Promise<number> {
    console.log('🗄️ Cache - invalidating entries by tag:', { tag });

    let invalidated = 0;
    
    for (const [key, entry] of this.cache.entries()) {
      if (entry.tags.includes(tag)) {
        this.cache.delete(key);
        invalidated++;
      }
    }

    console.log('✅ Cache - tag invalidation complete:', { 
      tag, 
      invalidated_count: invalidated,
      remaining_entries: this.cache.size 
    });

    return invalidated;
  }

  async invalidateByPattern(pattern: string): Promise<number> {
    console.log('🗄️ Cache - invalidating entries by pattern:', { pattern });

    let invalidated = 0;
    const regex = new RegExp(pattern);
    
    for (const key of this.cache.keys()) {
      if (regex.test(key)) {
        this.cache.delete(key);
        invalidated++;
      }
    }

    console.log('✅ Cache - pattern invalidation complete:', { 
      pattern, 
      invalidated_count: invalidated,
      remaining_entries: this.cache.size 
    });

    return invalidated;
  }

  async clear(): Promise<void> {
    console.log('🗄️ Cache - clearing all cache entries');

    const previousSize = this.cache.size;
    this.cache.clear();

    console.log('✅ Cache - all entries cleared:', { 
      previous_size: previousSize,
      current_size: this.cache.size 
    });
  }

  async getStats(): Promise<CacheStats> {
    const entries = Array.from(this.cache.values());
    const now = Date.now();
    
    const stats: CacheStats = {
      total_entries: this.cache.size,
      hits: this.stats.hits,
      misses: this.stats.misses,
      hit_rate: this.stats.hits + this.stats.misses > 0 
        ? this.stats.hits / (this.stats.hits + this.stats.misses) 
        : 0,
      memory_usage_mb: this.estimateMemoryUsage(),
      oldest_entry: entries.length > 0 ? Math.min(...entries.map(e => e.timestamp)) : now,
      newest_entry: entries.length > 0 ? Math.max(...entries.map(e => e.timestamp)) : now
    };

    console.log('📊 Cache - stats retrieved:', stats);
    return stats;
  }

  private evictLeastUsed(): void {
    console.log('🗄️ Cache - evicting least used entries');

    let leastUsedKey: string | null = null;
    let leastUsedScore = Infinity;

    for (const [key, entry] of this.cache.entries()) {
      const score = entry.hits / (Date.now() - entry.lastAccessed + 1);
      
      if (score < leastUsedScore) {
        leastUsedScore = score;
        leastUsedKey = key;
      }
    }

    if (leastUsedKey) {
      this.cache.delete(leastUsedKey);
      this.stats.evictions++;
      console.log('✅ Cache - least used entry evicted:', { 
        key: this.maskKey(leastUsedKey),
        score: leastUsedScore 
      });
    }
  }

  private startCleanupTimer(): void {
    console.log('🗄️ Cache - starting cleanup timer');

    this.cleanupTimer = setInterval(() => {
      this.cleanupExpiredEntries();
    }, this.CLEANUP_INTERVAL) as unknown as number;
  }

  private cleanupExpiredEntries(): void {
    console.log('🧹 Cache - cleaning up expired entries');

    const now = Date.now();
    let cleanedCount = 0;

    for (const [key, entry] of this.cache.entries()) {
      if (now > entry.timestamp + entry.ttl) {
        this.cache.delete(key);
        cleanedCount++;
      }
    }

    if (cleanedCount > 0) {
      this.stats.evictions += cleanedCount;
      console.log('✅ Cache - expired entries cleaned:', { 
        cleaned_count: cleanedCount,
        remaining_entries: this.cache.size 
      });
    }
  }

  private estimateMemoryUsage(): number {
    try {
      const cacheString = JSON.stringify(Array.from(this.cache.entries()));
      return Math.round((cacheString.length * 2) / (1024 * 1024)); // Rough estimate in MB
    } catch (error) {
      console.warn('⚠️ Cache - memory usage estimation failed:', error);
      return 0;
    }
  }

  private maskKey(key: string): string {
    if (key.length <= 8) {
      return key;
    }
    return key.substring(0, 4) + '***' + key.substring(key.length - 4);
  }

  destroy(): void {
    console.log('🗄️ Cache - destroying cache instance');

    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
    }
    
    this.cache.clear();
    console.log('✅ Cache - cache instance destroyed');
  }
}

export class ServiceCatalogCacheKeys {
  
  static readonly PREFIXES = {
    SERVICE: 'service',
    SERVICES_LIST: 'services_list',
    MASTER_DATA: 'master_data',
    RESOURCES: 'resources',
    SERVICE_RESOURCES: 'service_resources',
    PRICING: 'pricing',
    CATEGORIES: 'categories',
    INDUSTRIES: 'industries'
  };

  static service(serviceId: string, tenantId: string, isLive: boolean): string {
    return `${this.PREFIXES.SERVICE}:${tenantId}:${isLive}:${serviceId}`;
  }

  static servicesList(tenantId: string, isLive: boolean, filtersHash: string): string {
    return `${this.PREFIXES.SERVICES_LIST}:${tenantId}:${isLive}:${filtersHash}`;
  }

  static masterData(tenantId: string, isLive: boolean): string {
    return `${this.PREFIXES.MASTER_DATA}:${tenantId}:${isLive}`;
  }

  static resources(tenantId: string, isLive: boolean, filtersHash: string): string {
    return `${this.PREFIXES.RESOURCES}:${tenantId}:${isLive}:${filtersHash}`;
  }

  static serviceResources(serviceId: string, tenantId: string, isLive: boolean): string {
    return `${this.PREFIXES.SERVICE_RESOURCES}:${tenantId}:${isLive}:${serviceId}`;
  }

  static pricing(serviceId: string, tenantId: string, isLive: boolean): string {
    return `${this.PREFIXES.PRICING}:${tenantId}:${isLive}:${serviceId}`;
  }

  static categories(tenantId: string, isLive: boolean): string {
    return `${this.PREFIXES.CATEGORIES}:${tenantId}:${isLive}`;
  }

  static industries(tenantId: string, isLive: boolean): string {
    return `${this.PREFIXES.INDUSTRIES}:${tenantId}:${isLive}`;
  }

  static getTags(tenantId: string, isLive: boolean, resourceType?: string): string[] {
    const baseTags = [`tenant:${tenantId}`, `env:${isLive ? 'live' : 'test'}`];
    
    if (resourceType) {
      baseTags.push(`type:${resourceType}`);
    }

    return baseTags;
  }
}

export class CacheManager {
  private cache: ServiceCatalogCache;

  constructor() {
    this.cache = ServiceCatalogCache.getInstance();
  }

  async cacheWithFallback<T>(
    key: string,
    fallbackFn: () => Promise<T>,
    ttl?: number,
    tags?: string[]
  ): Promise<T> {
    console.log('🔄 CacheManager - cache with fallback:', { 
      key: this.maskKey(key),
      has_fallback: !!fallbackFn,
      ttl_minutes: ttl ? Math.round(ttl / 60000) : 'default'
    });

    try {
      const cached = await this.cache.get<T>(key);
      
      if (cached !== null) {
        console.log('✅ CacheManager - returning cached data');
        return cached;
      }

      console.log('🔄 CacheManager - cache miss, executing fallback');
      const data = await fallbackFn();
      
      await this.cache.set(key, data, ttl, tags || []);
      console.log('✅ CacheManager - fallback data cached');
      
      return data;
    } catch (error) {
      console.error('❌ CacheManager - cache with fallback error:', error);
      
      try {
        console.log('🔄 CacheManager - attempting fallback without caching');
        return await fallbackFn();
      } catch (fallbackError) {
        console.error('❌ CacheManager - fallback also failed:', fallbackError);
        throw fallbackError;
      }
    }
  }

  async invalidateServiceCache(serviceId: string, tenantId: string): Promise<void> {
    console.log('🗑️ CacheManager - invalidating service cache:', { 
      serviceId, 
      tenantId 
    });

    const patterns = [
      `service:${tenantId}:.*:${serviceId}`,
      `services_list:${tenantId}:.*`,
      `service_resources:${tenantId}:.*:${serviceId}`,
      `pricing:${tenantId}:.*:${serviceId}`
    ];

    let totalInvalidated = 0;
    
    for (const pattern of patterns) {
      const invalidated = await this.cache.invalidateByPattern(pattern);
      totalInvalidated += invalidated;
    }

    console.log('✅ CacheManager - service cache invalidated:', { 
      serviceId,
      tenantId,
      total_invalidated: totalInvalidated 
    });
  }

  async invalidateTenantCache(tenantId: string): Promise<void> {
    console.log('🗑️ CacheManager - invalidating tenant cache:', { tenantId });

    const tag = `tenant:${tenantId}`;
    const invalidated = await this.cache.invalidateByTag(tag);

    console.log('✅ CacheManager - tenant cache invalidated:', { 
      tenantId,
      invalidated_count: invalidated 
    });
  }

  async warmupCache(tenantId: string, isLive: boolean): Promise<void> {
    console.log('🔥 CacheManager - warming up cache:', { tenantId, isLive });

    try {
      const warmupTasks = [
        this.warmupMasterData(tenantId, isLive),
        this.warmupPopularServices(tenantId, isLive)
      ];

      await Promise.allSettled(warmupTasks);
      console.log('✅ CacheManager - cache warmup complete');
    } catch (error) {
      console.error('❌ CacheManager - cache warmup error:', error);
    }
  }

  private async warmupMasterData(tenantId: string, isLive: boolean): Promise<void> {
    console.log('🔥 CacheManager - warming up master data');
    
    const key = ServiceCatalogCacheKeys.masterData(tenantId, isLive);
    const tags = ServiceCatalogCacheKeys.getTags(tenantId, isLive, 'master_data');
    
    const mockMasterData = {
      categories: [],
      industries: [],
      currencies: [],
      tax_rates: []
    };

    await this.cache.set(key, mockMasterData, 30 * 60 * 1000, tags); // 30 minutes
    console.log('✅ CacheManager - master data warmed up');
  }

  private async warmupPopularServices(tenantId: string, isLive: boolean): Promise<void> {
    console.log('🔥 CacheManager - warming up popular services');

    const popularFiltersHash = this.hashFilters({ 
      is_active: true, 
      limit: 20, 
      offset: 0,
      sort_by: 'usage_count',
      sort_direction: 'desc'
    });

    const key = ServiceCatalogCacheKeys.servicesList(tenantId, isLive, popularFiltersHash);
    const tags = ServiceCatalogCacheKeys.getTags(tenantId, isLive, 'services_list');
    
    const mockServicesData = {
      items: [],
      total_count: 0,
      page_info: {
        has_next_page: false,
        has_prev_page: false,
        current_page: 1,
        total_pages: 0
      }
    };

    await this.cache.set(key, mockServicesData, 10 * 60 * 1000, tags); // 10 minutes
    console.log('✅ CacheManager - popular services warmed up');
  }

  private hashFilters(filters: any): string {
    const sortedFilters = Object.keys(filters)
      .sort()
      .reduce((result: any, key) => {
        result[key] = filters[key];
        return result;
      }, {});

    const filtersString = JSON.stringify(sortedFilters);
    
    let hash = 0;
    for (let i = 0; i < filtersString.length; i++) {
      const char = filtersString.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    
    return Math.abs(hash).toString(36);
  }

  private maskKey(key: string): string {
    if (key.length <= 8) {
      return key;
    }
    return key.substring(0, 4) + '***' + key.substring(key.length - 4);
  }

  async getStats(): Promise<CacheStats> {
    return await this.cache.getStats();
  }

  async clearAll(): Promise<void> {
    await this.cache.clear();
  }
}