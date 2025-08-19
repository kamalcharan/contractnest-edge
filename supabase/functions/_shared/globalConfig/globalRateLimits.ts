// File: supabase/functions/_shared/globalConfig/globalRateLimits.ts

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { TenantConfigManager } from './tenantConfigManager.ts';
import { EdgeFunction, PlanType, RateLimits } from './types.ts';

export interface RateLimitResult {
  isAllowed: boolean;
  requestsRemaining: number;
  resetTime: string;
  windowStart: string;
  windowEnd: string;
  requestsLimit: number;
  requestsMade: number;
}

export interface RateLimitRequest {
  tenant_id: string;
  user_id: string;
  edge_function: EdgeFunction;
  operation: string;
  ip_address?: string;
  user_agent?: string;
}

export class GlobalRateLimits {
  private static configManager: TenantConfigManager;

  static initialize(supabase: SupabaseClient): void {
    this.configManager = TenantConfigManager.getInstance(supabase);
    console.log('🚦 GlobalRateLimits - initialized');
  }

  /**
   * Check if a request is within rate limits
   */
  static async checkRateLimit(
    supabase: SupabaseClient,
    request: RateLimitRequest
  ): Promise<RateLimitResult> {
    console.log('🚦 GlobalRateLimits - checking rate limit:', {
      tenantId: request.tenant_id,
      edgeFunction: request.edge_function,
      operation: request.operation
    });

    try {
      // Get tenant configuration
      const { config, planType } = await this.configManager.getConfig(request.tenant_id, request.edge_function);
      
      // Get rate limit for specific operation
      const operationLimit = this.getOperationRateLimit(config.rate_limits, request.operation);
      
      if (!operationLimit) {
        console.warn('⚠️ GlobalRateLimits - no rate limit defined for operation:', request.operation);
        return this.createAllowedResult(1000, 60); // Default fallback
      }

      // Check current usage
      const usage = await this.getCurrentUsage(
        supabase,
        request.tenant_id,
        request.user_id,
        request.edge_function,
        request.operation,
        operationLimit.windowMinutes
      );

      const isAllowed = usage.requestsMade < operationLimit.requests;
      const requestsRemaining = Math.max(0, operationLimit.requests - usage.requestsMade);

      console.log('✅ GlobalRateLimits - rate limit check complete:', {
        tenantId: request.tenant_id,
        operation: request.operation,
        planType,
        isAllowed,
        requestsMade: usage.requestsMade,
        requestsLimit: operationLimit.requests,
        requestsRemaining
      });

      return {
        isAllowed,
        requestsRemaining,
        resetTime: usage.resetTime,
        windowStart: usage.windowStart,
        windowEnd: usage.windowEnd,
        requestsLimit: operationLimit.requests,
        requestsMade: usage.requestsMade
      };

    } catch (error) {
      console.error('❌ GlobalRateLimits - rate limit check failed:', error);
      
      // Fail open - allow request if we can't check limits
      return this.createAllowedResult(1000, 60);
    }
  }

  /**
   * Record a rate limit request
   */
  static async recordRequest(
    supabase: SupabaseClient,
    request: RateLimitRequest
  ): Promise<void> {
    console.log('📝 GlobalRateLimits - recording request:', {
      tenantId: request.tenant_id,
      edgeFunction: request.edge_function,
      operation: request.operation
    });

    try {
      const { error } = await supabase
        .from('edge_rate_limit_records')
        .insert({
          tenant_id: request.tenant_id,
          user_id: request.user_id,
          edge_function: request.edge_function,
          operation: request.operation,
          ip_address: request.ip_address,
          user_agent: request.user_agent,
          created_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ GlobalRateLimits - request recording error:', error);
        // Don't throw - recording failure shouldn't block the request
      } else {
        console.log('✅ GlobalRateLimits - request recorded successfully');
      }
    } catch (error) {
      console.error('❌ GlobalRateLimits - request recording failed:', error);
    }
  }

  /**
   * Get rate limits for a specific tenant and edge function
   */
  static async getRateLimits(
    tenantId: string,
    edgeFunction: EdgeFunction
  ): Promise<{ rateLimits: RateLimits; planType: PlanType }> {
    console.log('🚦 GlobalRateLimits - getting rate limits:', {
      tenantId,
      edgeFunction
    });

    try {
      const { config, planType } = await this.configManager.getConfig(tenantId, edgeFunction);
      
      console.log('✅ GlobalRateLimits - rate limits retrieved:', {
        tenantId,
        edgeFunction,
        planType
      });

      return {
        rateLimits: config.rate_limits,
        planType
      };
    } catch (error) {
      console.error('❌ GlobalRateLimits - rate limits fetch failed:', error);
      throw error;
    }
  }

  /**
   * Update rate limits for a tenant and edge function
   */
  static async updateRateLimits(
    tenantId: string,
    edgeFunction: EdgeFunction,
    rateLimits: Partial<RateLimits>
  ): Promise<void> {
    console.log('🔄 GlobalRateLimits - updating rate limits:', {
      tenantId,
      edgeFunction
    });

    try {
      await this.configManager.updateConfig(tenantId, edgeFunction, {
        rate_limits: rateLimits as RateLimits
      });

      console.log('✅ GlobalRateLimits - rate limits updated successfully');
    } catch (error) {
      console.error('❌ GlobalRateLimits - rate limits update failed:', error);
      throw error;
    }
  }

  /**
   * Check if tenant is over any rate limits
   */
  static async getTenantRateLimitStatus(
    supabase: SupabaseClient,
    tenantId: string,
    edgeFunction: EdgeFunction
  ): Promise<{
    planType: PlanType;
    operations: Array<{
      operation: string;
      requestsMade: number;
      requestsLimit: number;
      isOverLimit: boolean;
      resetTime: string;
    }>;
  }> {
    console.log('📊 GlobalRateLimits - getting tenant rate limit status:', {
      tenantId,
      edgeFunction
    });

    try {
      const { config, planType } = await this.configManager.getConfig(tenantId, edgeFunction);
      const operations = [];

      for (const [operation, limit] of Object.entries(config.rate_limits)) {
        if (limit) {
          const usage = await this.getCurrentUsage(
            supabase,
            tenantId,
            '', // Empty user_id to get tenant-wide usage
            edgeFunction,
            operation,
            limit.windowMinutes
          );

          operations.push({
            operation,
            requestsMade: usage.requestsMade,
            requestsLimit: limit.requests,
            isOverLimit: usage.requestsMade >= limit.requests,
            resetTime: usage.resetTime
          });
        }
      }

      console.log('✅ GlobalRateLimits - tenant rate limit status retrieved');

      return {
        planType,
        operations
      };
    } catch (error) {
      console.error('❌ GlobalRateLimits - tenant status fetch failed:', error);
      throw error;
    }
  }

  /**
   * Clean up old rate limit records
   */
  static async cleanupOldRecords(
    supabase: SupabaseClient,
    olderThanHours = 24
  ): Promise<number> {
    console.log('🧹 GlobalRateLimits - cleaning up old records:', {
      olderThanHours
    });

    try {
      const cutoffTime = new Date(Date.now() - (olderThanHours * 60 * 60 * 1000));

      const { data, error } = await supabase
        .from('edge_rate_limit_records')
        .delete()
        .lt('created_at', cutoffTime.toISOString());

      if (error) {
        console.error('❌ GlobalRateLimits - cleanup error:', error);
        throw error;
      }

      const deletedCount = Array.isArray(data) ? data.length : 0;
      console.log('✅ GlobalRateLimits - cleanup complete:', {
        deletedRecords: deletedCount,
        cutoffTime: cutoffTime.toISOString()
      });

      return deletedCount;
    } catch (error) {
      console.error('❌ GlobalRateLimits - cleanup failed:', error);
      throw error;
    }
  }

  // Private helper methods

  private static getOperationRateLimit(rateLimits: RateLimits, operation: string): { requests: number; windowMinutes: number } | null {
    // Direct operation match
    if (rateLimits[operation]) {
      return rateLimits[operation]!;
    }

    // Fallback mappings for common operations
    const operationMappings: Record<string, keyof RateLimits> = {
      'create_service': 'create',
      'get_service': 'read',
      'update_service': 'update',
      'delete_service': 'delete',
      'query_services': 'list',
      'search_services': 'search',
      'bulk_create': 'bulk_operations',
      'bulk_update': 'bulk_operations',
      'bulk_delete': 'bulk_operations'
    };

    const mappedOperation = operationMappings[operation];
    if (mappedOperation && rateLimits[mappedOperation]) {
      return rateLimits[mappedOperation]!;
    }

    // Final fallback to 'read' operation
    return rateLimits.read || null;
  }

  private static async getCurrentUsage(
    supabase: SupabaseClient,
    tenantId: string,
    userId: string,
    edgeFunction: EdgeFunction,
    operation: string,
    windowMinutes: number
  ): Promise<{
    requestsMade: number;
    windowStart: string;
    windowEnd: string;
    resetTime: string;
  }> {
    const windowStart = new Date(Date.now() - (windowMinutes * 60 * 1000));
    const windowEnd = new Date();
    const resetTime = new Date(windowStart.getTime() + (windowMinutes * 60 * 1000));

    let query = supabase
      .from('edge_rate_limit_records')
      .select('*', { count: 'exact' })
      .eq('tenant_id', tenantId)
      .eq('edge_function', edgeFunction)
      .eq('operation', operation)
      .gte('created_at', windowStart.toISOString())
      .lte('created_at', windowEnd.toISOString());

    // If user_id is provided, filter by user; otherwise get tenant-wide usage
    if (userId) {
      query = query.eq('user_id', userId);
    }

    const { count, error } = await query;

    if (error) {
      console.error('❌ GlobalRateLimits - usage query error:', error);
      throw error;
    }

    return {
      requestsMade: count || 0,
      windowStart: windowStart.toISOString(),
      windowEnd: windowEnd.toISOString(),
      resetTime: resetTime.toISOString()
    };
  }

  private static createAllowedResult(requests: number, windowMinutes: number): RateLimitResult {
    const now = new Date();
    const resetTime = new Date(now.getTime() + (windowMinutes * 60 * 1000));

    return {
      isAllowed: true,
      requestsRemaining: requests,
      resetTime: resetTime.toISOString(),
      windowStart: now.toISOString(),
      windowEnd: resetTime.toISOString(),
      requestsLimit: requests,
      requestsMade: 0
    };
  }
}