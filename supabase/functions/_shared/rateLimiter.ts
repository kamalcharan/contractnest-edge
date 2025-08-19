// supabase/functions/_shared/security/rateLimiter.ts

import { RateLimitInfo, RateLimitError } from '../catalog/catalogTypes.ts';

// Rate limit configuration per endpoint/method
export interface RateLimitConfig {
  windowSize: number; // Time window in milliseconds
  maxRequests: number; // Max requests per window
  burst?: number; // Optional burst allowance
  skipInternalRequests?: boolean; // Skip rate limiting for internal requests
}

// Rate limit entry for tracking
interface RateLimitEntry {
  count: number;
  resetTime: number;
  firstRequest: number;
  burstUsed?: number;
}

// Default rate limit configurations
export const DEFAULT_RATE_LIMITS: Record<string, RateLimitConfig> = {
  // Global limits per tenant
  'global': {
    windowSize: 60 * 1000, // 1 minute
    maxRequests: 200,
    burst: 20,
    skipInternalRequests: true
  },
  
  // Read operations (GET)
  'read': {
    windowSize: 60 * 1000, // 1 minute
    maxRequests: 300,
    burst: 50,
    skipInternalRequests: true
  },
  
  // Write operations (POST, PUT, DELETE)
  'write': {
    windowSize: 60 * 1000, // 1 minute
    maxRequests: 100,
    burst: 10,
    skipInternalRequests: true
  },
  
  // Expensive operations (search, multi-currency)
  'expensive': {
    windowSize: 60 * 1000, // 1 minute
    maxRequests: 50,
    burst: 5,
    skipInternalRequests: true
  },
  
  // Per-IP limits (stricter)
  'per-ip': {
    windowSize: 60 * 1000, // 1 minute
    maxRequests: 150,
    burst: 15,
    skipInternalRequests: false
  }
};

// Endpoint-specific rate limit mapping
export const ENDPOINT_RATE_LIMITS: Record<string, string> = {
  // Catalog operations
  'GET /': 'read',
  'GET /{id}': 'read',
  'POST /': 'write',
  'PUT /{id}': 'write',
  'DELETE /{id}': 'write',
  
  // Special operations
  'POST /restore/{id}': 'write',
  'GET /versions/{id}': 'expensive',
  
  // Multi-currency operations
  'GET /multi-currency': 'expensive',
  'GET /multi-currency/{id}': 'read',
  'POST /multi-currency': 'expensive',
  'PUT /multi-currency/{id}/{currency}': 'write',
  'DELETE /multi-currency/{id}/{currency}': 'write'
};

export class RateLimiter {
  private storage: Map<string, RateLimitEntry>;
  private cleanupInterval: number | null = null;
  private readonly cleanupIntervalMs = 5 * 60 * 1000; // 5 minutes

  constructor() {
    this.storage = new Map();
    this.startCleanupTimer();
  }

  /**
   * Start periodic cleanup of expired entries
   */
  private startCleanupTimer(): void {
    this.cleanupInterval = setInterval(() => {
      this.cleanup();
    }, this.cleanupIntervalMs);
  }

  /**
   * Stop cleanup timer (for testing)
   */
  public stopCleanupTimer(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }
  }

  /**
   * Clean up expired rate limit entries
   */
  private cleanup(): void {
    const now = Date.now();
    const expiredKeys: string[] = [];

    for (const [key, entry] of this.storage.entries()) {
      if (now > entry.resetTime) {
        expiredKeys.push(key);
      }
    }

    for (const key of expiredKeys) {
      this.storage.delete(key);
    }

    console.log(`[RateLimiter] Cleaned up ${expiredKeys.length} expired entries. Active entries: ${this.storage.size}`);
  }

  /**
   * Generate rate limit key
   */
  private generateKey(identifier: string, limitType: string): string {
    return `${limitType}:${identifier}`;
  }

  /**
   * Check if request is from internal service
   */
  private isInternalRequest(headers: Record<string, string>): boolean {
    return !!(headers['x-internal-signature'] || headers['x-internal-request']);
  }

  /**
   * Get rate limit configuration for endpoint
   */
  private getRateLimitConfig(method: string, path: string): RateLimitConfig {
    const endpoint = `${method} ${path}`;
    const limitType = ENDPOINT_RATE_LIMITS[endpoint] || 'global';
    return DEFAULT_RATE_LIMITS[limitType] || DEFAULT_RATE_LIMITS.global;
  }

  /**
   * Check rate limit for a request
   */
  public checkRateLimit(
    tenantId: string,
    ipAddress: string,
    method: string,
    path: string,
    headers: Record<string, string> = {}
  ): {
    allowed: boolean;
    rateLimitInfo: RateLimitInfo;
    error?: RateLimitError;
  } {
    const config = this.getRateLimitConfig(method, path);
    const now = Date.now();

    // Skip rate limiting for internal requests if configured
    if (config.skipInternalRequests && this.isInternalRequest(headers)) {
      return {
        allowed: true,
        rateLimitInfo: {
          limit: config.maxRequests,
          remaining: config.maxRequests,
          resetTime: now + config.windowSize,
          windowSize: config.windowSize
        }
      };
    }

    // Check both tenant-based and IP-based limits
    const tenantResult = this.checkLimit(tenantId, config, now, 'tenant');
    const ipResult = this.checkLimit(ipAddress, DEFAULT_RATE_LIMITS['per-ip'], now, 'ip');

    // Use the most restrictive limit
    const restrictiveResult = tenantResult.remaining < ipResult.remaining ? tenantResult : ipResult;

    if (!tenantResult.allowed || !ipResult.allowed) {
      const rateLimitInfo: RateLimitInfo = {
        limit: restrictiveResult.limit,
        remaining: 0,
        resetTime: restrictiveResult.resetTime,
        windowSize: restrictiveResult.windowSize
      };

      const error = new RateLimitError(
        'Rate limit exceeded. Please try again later.',
        restrictiveResult.resetTime,
        restrictiveResult.limit,
        0
      );

      return {
        allowed: false,
        rateLimitInfo,
        error
      };
    }

    return {
      allowed: true,
      rateLimitInfo: {
        limit: restrictiveResult.limit,
        remaining: restrictiveResult.remaining,
        resetTime: restrictiveResult.resetTime,
        windowSize: restrictiveResult.windowSize
      }
    };
  }

  /**
   * Check rate limit for a specific identifier and configuration
   */
  private checkLimit(
    identifier: string,
    config: RateLimitConfig,
    now: number,
    limitType: string
  ): {
    allowed: boolean;
    remaining: number;
    resetTime: number;
    limit: number;
    windowSize: number;
  } {
    const key = this.generateKey(identifier, limitType);
    const entry = this.storage.get(key);

    // If no entry exists or window has expired, create new entry
    if (!entry || now >= entry.resetTime) {
      const newEntry: RateLimitEntry = {
        count: 1,
        resetTime: now + config.windowSize,
        firstRequest: now,
        burstUsed: 0
      };
      
      this.storage.set(key, newEntry);
      
      return {
        allowed: true,
        remaining: config.maxRequests - 1,
        resetTime: newEntry.resetTime,
        limit: config.maxRequests,
        windowSize: config.windowSize
      };
    }

    // Check if we're within normal limits
    if (entry.count < config.maxRequests) {
      entry.count++;
      this.storage.set(key, entry);
      
      return {
        allowed: true,
        remaining: config.maxRequests - entry.count,
        resetTime: entry.resetTime,
        limit: config.maxRequests,
        windowSize: config.windowSize
      };
    }

    // Check if burst is available
    if (config.burst && entry.burstUsed !== undefined && entry.burstUsed < config.burst) {
      entry.burstUsed++;
      this.storage.set(key, entry);
      
      return {
        allowed: true,
        remaining: 0, // No normal requests remaining, but burst was used
        resetTime: entry.resetTime,
        limit: config.maxRequests,
        windowSize: config.windowSize
      };
    }

    // Rate limit exceeded
    return {
      allowed: false,
      remaining: 0,
      resetTime: entry.resetTime,
      limit: config.maxRequests,
      windowSize: config.windowSize
    };
  }

  /**
   * Get current rate limit status without incrementing
   */
  public getRateLimitStatus(
    identifier: string,
    limitType: string = 'tenant'
  ): RateLimitInfo | null {
    const config = DEFAULT_RATE_LIMITS[limitType] || DEFAULT_RATE_LIMITS.global;
    const key = this.generateKey(identifier, limitType);
    const entry = this.storage.get(key);
    const now = Date.now();

    if (!entry || now >= entry.resetTime) {
      return {
        limit: config.maxRequests,
        remaining: config.maxRequests,
        resetTime: now + config.windowSize,
        windowSize: config.windowSize
      };
    }

    return {
      limit: config.maxRequests,
      remaining: Math.max(0, config.maxRequests - entry.count),
      resetTime: entry.resetTime,
      windowSize: config.windowSize
    };
  }

  /**
   * Reset rate limit for identifier (admin function)
   */
  public resetRateLimit(identifier: string, limitType: string = 'tenant'): boolean {
    const key = this.generateKey(identifier, limitType);
    return this.storage.delete(key);
  }

  /**
   * Get rate limit statistics
   */
  public getStatistics(): {
    totalEntries: number;
    activeEntries: number;
    expiredEntries: number;
    memoryUsage: number;
  } {
    const now = Date.now();
    let activeEntries = 0;
    let expiredEntries = 0;

    for (const [, entry] of this.storage.entries()) {
      if (now >= entry.resetTime) {
        expiredEntries++;
      } else {
        activeEntries++;
      }
    }

    return {
      totalEntries: this.storage.size,
      activeEntries,
      expiredEntries,
      memoryUsage: this.storage.size * 100 // Rough estimate in bytes
    };
  }

  /**
   * Update rate limit configuration (for dynamic configuration)
   */
  public updateRateLimitConfig(
    limitType: string,
    config: Partial<RateLimitConfig>
  ): boolean {
    if (DEFAULT_RATE_LIMITS[limitType]) {
      DEFAULT_RATE_LIMITS[limitType] = {
        ...DEFAULT_RATE_LIMITS[limitType],
        ...config
      };
      return true;
    }
    return false;
  }

  /**
   * Check if an identifier is currently rate limited
   */
  public isRateLimited(identifier: string, limitType: string = 'tenant'): boolean {
    const key = this.generateKey(identifier, limitType);
    const entry = this.storage.get(key);
    const config = DEFAULT_RATE_LIMITS[limitType] || DEFAULT_RATE_LIMITS.global;
    const now = Date.now();

    if (!entry || now >= entry.resetTime) {
      return false;
    }

    // Check if normal limit is exceeded
    if (entry.count >= config.maxRequests) {
      // Check if burst is also exceeded
      if (config.burst && entry.burstUsed !== undefined) {
        return entry.burstUsed >= config.burst;
      }
      return true;
    }

    return false;
  }

  /**
   * Get time until rate limit resets for identifier
   */
  public getTimeUntilReset(identifier: string, limitType: string = 'tenant'): number {
    const key = this.generateKey(identifier, limitType);
    const entry = this.storage.get(key);
    const now = Date.now();

    if (!entry || now >= entry.resetTime) {
      return 0;
    }

    return entry.resetTime - now;
  }

  /**
   * Whitelist an identifier (bypass rate limiting)
   */
  private whitelist: Set<string> = new Set();

  public addToWhitelist(identifier: string): void {
    this.whitelist.add(identifier);
  }

  public removeFromWhitelist(identifier: string): void {
    this.whitelist.delete(identifier);
  }

  public isWhitelisted(identifier: string): boolean {
    return this.whitelist.has(identifier);
  }

  /**
   * Enhanced rate limit check with whitelist support
   */
  public checkRateLimitWithWhitelist(
    tenantId: string,
    ipAddress: string,
    method: string,
    path: string,
    headers: Record<string, string> = {}
  ): {
    allowed: boolean;
    rateLimitInfo: RateLimitInfo;
    error?: RateLimitError;
    whitelisted?: boolean;
  } {
    // Check whitelist first
    if (this.isWhitelisted(tenantId) || this.isWhitelisted(ipAddress)) {
      const config = this.getRateLimitConfig(method, path);
      return {
        allowed: true,
        whitelisted: true,
        rateLimitInfo: {
          limit: config.maxRequests,
          remaining: config.maxRequests,
          resetTime: Date.now() + config.windowSize,
          windowSize: config.windowSize
        }
      };
    }

    return this.checkRateLimit(tenantId, ipAddress, method, path, headers);
  }
}

// Singleton instance for Edge Function use
export const rateLimiter = new RateLimiter();

/**
 * Helper function to extract IP address from request
 */
export function getClientIP(req: Request): string {
  // Try various headers that might contain the real IP
  const forwardedFor = req.headers.get('x-forwarded-for');
  if (forwardedFor) {
    return forwardedFor.split(',')[0].trim();
  }

  const realIP = req.headers.get('x-real-ip');
  if (realIP) {
    return realIP;
  }

  const cfConnectingIP = req.headers.get('cf-connecting-ip');
  if (cfConnectingIP) {
    return cfConnectingIP;
  }

  // Fallback to a default IP (should not happen in production)
  return '127.0.0.1';
}

/**
 * Helper function to create rate limit headers for response
 */
export function createRateLimitHeaders(rateLimitInfo: RateLimitInfo): Record<string, string> {
  return {
    'X-RateLimit-Limit': rateLimitInfo.limit.toString(),
    'X-RateLimit-Remaining': rateLimitInfo.remaining.toString(),
    'X-RateLimit-Reset': rateLimitInfo.resetTime.toString(),
    'X-RateLimit-Window': rateLimitInfo.windowSize.toString()
  };
}

/**
 * Helper function to normalize path for rate limiting
 */
export function normalizePath(path: string): string {
  // Remove query parameters
  const pathOnly = path.split('?')[0];
  
  // Replace UUIDs with placeholder for consistent rate limiting
  return pathOnly.replace(
    /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/gi,
    '{id}'
  );
}