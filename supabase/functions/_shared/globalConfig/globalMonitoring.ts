// File: supabase/functions/_shared/globalConfig/globalMonitoring.ts

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { TenantConfigManager } from './tenantConfigManager.ts';
import { EdgeFunction, GlobalSettings } from './types.ts';

export interface OperationMetrics {
  operation_id: string;
  tenant_id: string;
  user_id?: string;
  edge_function: EdgeFunction;
  operation_type: string;
  execution_time_ms: number;
  success: boolean;
  error_code?: string;
  error_message?: string;
  request_size_bytes?: number;
  response_size_bytes?: number;
  ip_address?: string;
  user_agent?: string;
  created_at: string;
}

export interface PerformanceAlert {
  tenant_id: string;
  edge_function: EdgeFunction;
  alert_type: 'high_latency' | 'high_error_rate' | 'rate_limit_exceeded' | 'resource_usage';
  threshold_value: number;
  current_value: number;
  time_window_minutes: number;
  severity: 'low' | 'medium' | 'high' | 'critical';
  created_at: string;
}

export interface TenantMetrics {
  tenant_id: string;
  edge_function: EdgeFunction;
  time_period: string;
  total_requests: number;
  successful_requests: number;
  failed_requests: number;
  average_response_time_ms: number;
  p95_response_time_ms: number;
  error_rate_percentage: number;
  total_data_transferred_mb: number;
}

export class GlobalMonitoring {
  private static configManager: TenantConfigManager;
  private static supabase: SupabaseClient;

  static initialize(supabase: SupabaseClient, configManager: TenantConfigManager): void {
    this.supabase = supabase;
    this.configManager = configManager;
    console.log('📊 GlobalMonitoring - initialized');
  }

  /**
   * Log operation metrics
   */
  static async logOperation(metrics: OperationMetrics): Promise<void> {
    console.log('📊 GlobalMonitoring - logging operation:', {
      operationId: metrics.operation_id,
      tenantId: metrics.tenant_id,
      edgeFunction: metrics.edge_function,
      operationType: metrics.operation_type,
      executionTime: metrics.execution_time_ms,
      success: metrics.success
    });

    try {
      // Get tenant monitoring settings
      const { globalSettings } = await this.configManager.getConfig(metrics.tenant_id, metrics.edge_function);
      
      // Only log based on monitoring level
      if (!this.shouldLogOperation(globalSettings.monitoring_level, metrics)) {
        return;
      }

      const { error } = await this.supabase
        .from('edge_operation_metrics')
        .insert({
          operation_id: metrics.operation_id,
          tenant_id: metrics.tenant_id,
          user_id: metrics.user_id,
          edge_function: metrics.edge_function,
          operation_type: metrics.operation_type,
          execution_time_ms: metrics.execution_time_ms,
          success: metrics.success,
          error_code: metrics.error_code,
          error_message: metrics.error_message,
          request_size_bytes: metrics.request_size_bytes,
          response_size_bytes: metrics.response_size_bytes,
          ip_address: metrics.ip_address,
          user_agent: metrics.user_agent,
          created_at: metrics.created_at
        });

      if (error) {
        console.error('❌ GlobalMonitoring - operation logging error:', error);
        // Don't throw - logging failure shouldn't affect the operation
      } else {
        console.log('✅ GlobalMonitoring - operation logged successfully');
      }

      // Check for performance alerts
      await this.checkPerformanceAlerts(metrics);

    } catch (error) {
      console.error('❌ GlobalMonitoring - operation logging failed:', error);
    }
  }

  /**
   * Get tenant metrics for a time period
   */
  static async getTenantMetrics(
    tenantId: string,
    edgeFunction: EdgeFunction,
    timePeriod: 'hour' | 'day' | 'week' | 'month'
  ): Promise<TenantMetrics | null> {
    console.log('📊 GlobalMonitoring - getting tenant metrics:', {
      tenantId,
      edgeFunction,
      timePeriod
    });

    try {
      const timeWindow = this.getTimeWindow(timePeriod);
      
      const { data, error } = await this.supabase
        .rpc('get_tenant_metrics', {
          p_tenant_id: tenantId,
          p_edge_function: edgeFunction,
          p_start_time: timeWindow.start,
          p_end_time: timeWindow.end
        });

      if (error) {
        console.error('❌ GlobalMonitoring - metrics fetch error:', error);
        throw error;
      }

      if (!data || data.length === 0) {
        return null;
      }

      const metrics = data[0] as TenantMetrics;
      
      console.log('✅ GlobalMonitoring - tenant metrics retrieved:', {
        tenantId,
        edgeFunction,
        totalRequests: metrics.total_requests,
        errorRate: metrics.error_rate_percentage,
        avgResponseTime: metrics.average_response_time_ms
      });

      return metrics;

    } catch (error) {
      console.error('❌ GlobalMonitoring - tenant metrics fetch failed:', error);
      return null;
    }
  }

  /**
   * Get performance alerts for a tenant
   */
  static async getPerformanceAlerts(
    tenantId: string,
    edgeFunction?: EdgeFunction,
    severity?: 'low' | 'medium' | 'high' | 'critical'
  ): Promise<PerformanceAlert[]> {
    console.log('📊 GlobalMonitoring - getting performance alerts:', {
      tenantId,
      edgeFunction,
      severity
    });

    try {
      let query = this.supabase
        .from('edge_performance_alerts')
        .select('*')
        .eq('tenant_id', tenantId)
        .order('created_at', { ascending: false });

      if (edgeFunction) {
        query = query.eq('edge_function', edgeFunction);
      }

      if (severity) {
        query = query.eq('severity', severity);
      }

      const { data, error } = await query.limit(100);

      if (error) {
        console.error('❌ GlobalMonitoring - alerts fetch error:', error);
        throw error;
      }

      console.log('✅ GlobalMonitoring - performance alerts retrieved:', {
        tenantId,
        alertsCount: data?.length || 0
      });

      return data || [];

    } catch (error) {
      console.error('❌ GlobalMonitoring - performance alerts fetch failed:', error);
      return [];
    }
  }

  /**
   * Create custom metric
   */
  static async recordCustomMetric(
    tenantId: string,
    edgeFunction: EdgeFunction,
    metricName: string,
    value: number,
    unit: string = 'count',
    tags: Record<string, string> = {}
  ): Promise<void> {
    console.log('📊 GlobalMonitoring - recording custom metric:', {
      tenantId,
      edgeFunction,
      metricName,
      value,
      unit
    });

    try {
      const { error } = await this.supabase
        .from('edge_custom_metrics')
        .insert({
          tenant_id: tenantId,
          edge_function: edgeFunction,
          metric_name: metricName,
          value,
          unit,
          tags,
          created_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ GlobalMonitoring - custom metric recording error:', error);
      } else {
        console.log('✅ GlobalMonitoring - custom metric recorded successfully');
      }

    } catch (error) {
      console.error('❌ GlobalMonitoring - custom metric recording failed:', error);
    }
  }

  /**
   * Get real-time system health
   */
  static async getSystemHealth(): Promise<{
    overall_status: 'healthy' | 'degraded' | 'unhealthy';
    edge_functions: Array<{
      edge_function: EdgeFunction;
      status: 'healthy' | 'degraded' | 'unhealthy';
      avg_response_time_ms: number;
      error_rate_percentage: number;
      requests_per_minute: number;
    }>;
    last_updated: string;
  }> {
    console.log('📊 GlobalMonitoring - getting system health');

    try {
      const { data, error } = await this.supabase
        .rpc('get_system_health');

      if (error) {
        console.error('❌ GlobalMonitoring - system health fetch error:', error);
        throw error;
      }

      console.log('✅ GlobalMonitoring - system health retrieved');

      return data || {
        overall_status: 'healthy',
        edge_functions: [],
        last_updated: new Date().toISOString()
      };

    } catch (error) {
      console.error('❌ GlobalMonitoring - system health fetch failed:', error);
      
      return {
        overall_status: 'unhealthy',
        edge_functions: [],
        last_updated: new Date().toISOString()
      };
    }
  }

  /**
   * Create performance dashboard data
   */
  static async getDashboardData(
    tenantId: string,
    timePeriod: 'hour' | 'day' | 'week' | 'month'
  ): Promise<{
    summary: {
      total_requests: number;
      success_rate: number;
      avg_response_time: number;
      total_errors: number;
    };
    by_edge_function: Array<{
      edge_function: EdgeFunction;
      requests: number;
      success_rate: number;
      avg_response_time: number;
      errors: number;
    }>;
    recent_alerts: PerformanceAlert[];
    top_errors: Array<{
      error_code: string;
      count: number;
      last_seen: string;
    }>;
  }> {
    console.log('📊 GlobalMonitoring - getting dashboard data:', {
      tenantId,
      timePeriod
    });

    try {
      const timeWindow = this.getTimeWindow(timePeriod);
      
      const [summaryData, functionData, alertsData, errorsData] = await Promise.all([
        this.getTenantSummary(tenantId, timeWindow),
        this.getFunctionBreakdown(tenantId, timeWindow),
        this.getPerformanceAlerts(tenantId),
        this.getTopErrors(tenantId, timeWindow)
      ]);

      console.log('✅ GlobalMonitoring - dashboard data retrieved');

      return {
        summary: summaryData,
        by_edge_function: functionData,
        recent_alerts: alertsData.slice(0, 10), // Last 10 alerts
        top_errors: errorsData
      };

    } catch (error) {
      console.error('❌ GlobalMonitoring - dashboard data fetch failed:', error);
      
      return {
        summary: { total_requests: 0, success_rate: 0, avg_response_time: 0, total_errors: 0 },
        by_edge_function: [],
        recent_alerts: [],
        top_errors: []
      };
    }
  }

  /**
   * Cleanup old monitoring data
   */
  static async cleanupOldData(
    olderThanDays: number = 30
  ): Promise<{
    metrics_deleted: number;
    alerts_deleted: number;
    custom_metrics_deleted: number;
  }> {
    console.log('🧹 GlobalMonitoring - cleaning up old data:', {
      olderThanDays
    });

    try {
      const cutoffDate = new Date(Date.now() - (olderThanDays * 24 * 60 * 60 * 1000));

      const [metricsResult, alertsResult, customMetricsResult] = await Promise.all([
        this.supabase
          .from('edge_operation_metrics')
          .delete()
          .lt('created_at', cutoffDate.toISOString()),
        
        this.supabase
          .from('edge_performance_alerts')
          .delete()
          .lt('created_at', cutoffDate.toISOString()),
        
        this.supabase
          .from('edge_custom_metrics')
          .delete()
          .lt('created_at', cutoffDate.toISOString())
      ]);

      const result = {
        metrics_deleted: Array.isArray(metricsResult.data) ? metricsResult.data.length : 0,
        alerts_deleted: Array.isArray(alertsResult.data) ? alertsResult.data.length : 0,
        custom_metrics_deleted: Array.isArray(customMetricsResult.data) ? customMetricsResult.data.length : 0
      };

      console.log('✅ GlobalMonitoring - cleanup complete:', result);

      return result;

    } catch (error) {
      console.error('❌ GlobalMonitoring - cleanup failed:', error);
      
      return {
        metrics_deleted: 0,
        alerts_deleted: 0,
        custom_metrics_deleted: 0
      };
    }
  }

  // Private helper methods

  private static shouldLogOperation(monitoringLevel: string, metrics: OperationMetrics): boolean {
    switch (monitoringLevel) {
      case 'basic':
        // Only log errors and very slow operations
        return !metrics.success || metrics.execution_time_ms > 5000;
      
      case 'standard':
        // Log errors and operations above 1 second
        return !metrics.success || metrics.execution_time_ms > 1000;
      
      case 'advanced':
        // Log all operations
        return true;
      
      default:
        return true;
    }
  }

  private static async checkPerformanceAlerts(metrics: OperationMetrics): Promise<void> {
    try {
      const { globalSettings } = await this.configManager.getConfig(metrics.tenant_id, metrics.edge_function);
      
      // High latency alert
      if (metrics.execution_time_ms > 10000) { // 10 seconds
        await this.createAlert({
          tenant_id: metrics.tenant_id,
          edge_function: metrics.edge_function,
          alert_type: 'high_latency',
          threshold_value: 10000,
          current_value: metrics.execution_time_ms,
          time_window_minutes: 1,
          severity: metrics.execution_time_ms > 30000 ? 'critical' : 'high',
          created_at: new Date().toISOString()
        });
      }

      // Error rate monitoring (would require more complex logic in production)
      if (!metrics.success) {
        // This is simplified - in production you'd check error rate over time
        console.log('⚠️ GlobalMonitoring - operation failed, monitoring error rate');
      }

    } catch (error) {
      console.error('❌ GlobalMonitoring - performance alert check failed:', error);
    }
  }

  private static async createAlert(alert: PerformanceAlert): Promise<void> {
    try {
      const { error } = await this.supabase
        .from('edge_performance_alerts')
        .insert(alert);

      if (error) {
        console.error('❌ GlobalMonitoring - alert creation error:', error);
      } else {
        console.log('🚨 GlobalMonitoring - performance alert created:', {
          tenantId: alert.tenant_id,
          alertType: alert.alert_type,
          severity: alert.severity
        });
      }
    } catch (error) {
      console.error('❌ GlobalMonitoring - alert creation failed:', error);
    }
  }

  private static getTimeWindow(timePeriod: 'hour' | 'day' | 'week' | 'month'): { start: string; end: string } {
    const end = new Date();
    const start = new Date();

    switch (timePeriod) {
      case 'hour':
        start.setHours(start.getHours() - 1);
        break;
      case 'day':
        start.setDate(start.getDate() - 1);
        break;
      case 'week':
        start.setDate(start.getDate() - 7);
        break;
      case 'month':
        start.setMonth(start.getMonth() - 1);
        break;
    }

    return {
      start: start.toISOString(),
      end: end.toISOString()
    };
  }

  private static async getTenantSummary(tenantId: string, timeWindow: { start: string; end: string }) {
    // Simplified implementation - in production this would be a database view or stored procedure
    const { data, error } = await this.supabase
      .from('edge_operation_metrics')
      .select('success, execution_time_ms')
      .eq('tenant_id', tenantId)
      .gte('created_at', timeWindow.start)
      .lte('created_at', timeWindow.end);

    if (error || !data) {
      return { total_requests: 0, success_rate: 0, avg_response_time: 0, total_errors: 0 };
    }

    const total = data.length;
    const successful = data.filter(r => r.success).length;
    const avgTime = data.reduce((sum, r) => sum + r.execution_time_ms, 0) / total;

    return {
      total_requests: total,
      success_rate: total > 0 ? (successful / total) * 100 : 0,
      avg_response_time: avgTime || 0,
      total_errors: total - successful
    };
  }

  private static async getFunctionBreakdown(tenantId: string, timeWindow: { start: string; end: string }) {
    // Simplified implementation
    const { data, error } = await this.supabase
      .from('edge_operation_metrics')
      .select('edge_function, success, execution_time_ms')
      .eq('tenant_id', tenantId)
      .gte('created_at', timeWindow.start)
      .lte('created_at', timeWindow.end);

    if (error || !data) {
      return [];
    }

    // Group by edge function
    const grouped = data.reduce((acc: any, record) => {
      const func = record.edge_function;
      if (!acc[func]) {
        acc[func] = { requests: 0, successful: 0, totalTime: 0 };
      }
      acc[func].requests++;
      if (record.success) acc[func].successful++;
      acc[func].totalTime += record.execution_time_ms;
      return acc;
    }, {});

    return Object.entries(grouped).map(([func, stats]: [string, any]) => ({
      edge_function: func as EdgeFunction,
      requests: stats.requests,
      success_rate: (stats.successful / stats.requests) * 100,
      avg_response_time: stats.totalTime / stats.requests,
      errors: stats.requests - stats.successful
    }));
  }

  private static async getTopErrors(tenantId: string, timeWindow: { start: string; end: string }) {
    // Simplified implementation
    const { data, error } = await this.supabase
      .from('edge_operation_metrics')
      .select('error_code, created_at')
      .eq('tenant_id', tenantId)
      .eq('success', false)
      .not('error_code', 'is', null)
      .gte('created_at', timeWindow.start)
      .lte('created_at', timeWindow.end);

    if (error || !data) {
      return [];
    }

    // Count errors by code
    const errorCounts = data.reduce((acc: any, record) => {
      const code = record.error_code;
      if (!acc[code]) {
        acc[code] = { count: 0, last_seen: record.created_at };
      }
      acc[code].count++;
      if (record.created_at > acc[code].last_seen) {
        acc[code].last_seen = record.created_at;
      }
      return acc;
    }, {});

    return Object.entries(errorCounts)
      .map(([code, data]: [string, any]) => ({
        error_code: code,
        count: data.count,
        last_seen: data.last_seen
      }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 10);
  }
}