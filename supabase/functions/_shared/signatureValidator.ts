// supabase/functions/_shared/security/signatureValidator.ts

import { SignatureValidationResult, SecurityError } from '../catalog/catalogTypes.ts';

// Signature validation configuration
export interface SignatureConfig {
  algorithm: 'SHA-256' | 'SHA-512';
  timestampToleranceMs: number; // How old can timestamps be
  enableTimestampValidation: boolean;
  enableReplayProtection: boolean;
  debugMode: boolean;
}

// Default signature configuration
export const DEFAULT_SIGNATURE_CONFIG: SignatureConfig = {
  algorithm: 'SHA-256',
  timestampToleranceMs: 5 * 60 * 1000, // 5 minutes
  enableTimestampValidation: true,
  enableReplayProtection: true,
  debugMode: false // Set to true for development
};

// Request signature info
export interface RequestSignatureInfo {
  signature: string;
  timestamp?: string;
  correlationId?: string;
  algorithm: string;
  bodyHash?: string;
}

// Signature validation context
export interface ValidationContext {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;
  timestamp: number;
  clientIP?: string;
}

export class SignatureValidator {
  private config: SignatureConfig;
  private replayCache: Set<string> = new Set(); // Simple replay protection
  private cleanupInterval: number | null = null;

  constructor(config: Partial<SignatureConfig> = {}) {
    this.config = { ...DEFAULT_SIGNATURE_CONFIG, ...config };
    
    if (this.config.enableReplayProtection) {
      this.startReplayCleanup();
    }
  }

  /**
   * Start periodic cleanup of replay cache
   */
  private startReplayCleanup(): void {
    this.cleanupInterval = setInterval(() => {
      // Clear the entire cache periodically for memory management
      // In production, you might want a more sophisticated approach
      this.replayCache.clear();
      if (this.config.debugMode) {
        console.log('[SignatureValidator] Cleaned replay protection cache');
      }
    }, this.config.timestampToleranceMs);
  }

  /**
   * Stop cleanup timer
   */
  public stopCleanup(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }
  }

  /**
   * Generate HMAC signature for given payload and secret
   */
  public async generateSignature(
    payload: string, 
    secret: string, 
    algorithm: string = this.config.algorithm
  ): Promise<string> {
    try {
      const encoder = new TextEncoder();
      const key = await crypto.subtle.importKey(
        'raw',
        encoder.encode(secret),
        { name: 'HMAC', hash: algorithm },
        false,
        ['sign']
      );
      
      const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
      const hashArray = Array.from(new Uint8Array(signature));
      return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    } catch (error) {
      throw new SecurityError(`Failed to generate signature: ${error.message}`, 'SIGNATURE_GENERATION_ERROR');
    }
  }

  /**
   * Extract signature information from request headers
   */
  public extractSignatureInfo(headers: Record<string, string>): RequestSignatureInfo | null {
    const signature = headers['x-internal-signature'];
    
    if (!signature) {
      return null;
    }

    return {
      signature,
      timestamp: headers['x-request-timestamp'],
      correlationId: headers['x-correlation-id'],
      algorithm: headers['x-signature-algorithm'] || this.config.algorithm,
      bodyHash: headers['x-body-hash']
    };
  }

  /**
   * Validate request timestamp
   */
  private validateTimestamp(timestamp: string): { isValid: boolean; error?: string } {
    if (!this.config.enableTimestampValidation) {
      return { isValid: true };
    }

    if (!timestamp) {
      return { isValid: false, error: 'Timestamp is required for signature validation' };
    }

    const requestTime = parseInt(timestamp, 10);
    if (isNaN(requestTime)) {
      return { isValid: false, error: 'Invalid timestamp format' };
    }

    const now = Date.now();
    const timeDiff = Math.abs(now - requestTime);

    if (timeDiff > this.config.timestampToleranceMs) {
      return { 
        isValid: false, 
        error: `Request timestamp is too old. Difference: ${timeDiff}ms, Tolerance: ${this.config.timestampToleranceMs}ms` 
      };
    }

    return { isValid: true };
  }

  /**
   * Check for replay attacks
   */
  private checkReplayProtection(signatureInfo: RequestSignatureInfo, context: ValidationContext): { isValid: boolean; error?: string } {
    if (!this.config.enableReplayProtection) {
      return { isValid: true };
    }

    // Create a unique request identifier
    const requestId = `${signatureInfo.signature}-${signatureInfo.timestamp}-${context.method}-${context.path}`;
    
    if (this.replayCache.has(requestId)) {
      return { isValid: false, error: 'Potential replay attack detected' };
    }

    // Add to cache
    this.replayCache.add(requestId);
    return { isValid: true };
  }

  /**
   * Create signature payload from request context
   */
  private createSignaturePayload(context: ValidationContext, includeTimestamp: boolean = true): string {
    const parts = [
      context.method,
      context.path,
      context.body
    ];

    if (includeTimestamp && context.headers['x-request-timestamp']) {
      parts.push(context.headers['x-request-timestamp']);
    }

    // Add correlation ID if present for additional security
    if (context.headers['x-correlation-id']) {
      parts.push(context.headers['x-correlation-id']);
    }

    return parts.join('|');
  }

  /**
   * Enhanced signature validation with comprehensive checks
   */
  public async validateSignature(
    secret: string,
    context: ValidationContext
  ): Promise<SignatureValidationResult> {
    const startTime = Date.now();
    
    try {
      // Extract signature information
      const signatureInfo = this.extractSignatureInfo(context.headers);
      
      if (!signatureInfo) {
        return {
          isValid: false,
          error: 'No signature found in request headers',
          algorithm: this.config.algorithm,
          timestamp: startTime
        };
      }

      if (this.config.debugMode) {
        console.log('[SignatureValidator] Validating signature:', {
          hasSignature: !!signatureInfo.signature,
          hasTimestamp: !!signatureInfo.timestamp,
          algorithm: signatureInfo.algorithm,
          bodyLength: context.body.length,
          method: context.method,
          path: context.path
        });
      }

      // Validate timestamp
      if (signatureInfo.timestamp) {
        const timestampValidation = this.validateTimestamp(signatureInfo.timestamp);
        if (!timestampValidation.isValid) {
          return {
            isValid: false,
            error: timestampValidation.error,
            algorithm: signatureInfo.algorithm,
            timestamp: startTime
          };
        }
      }

      // Check for replay attacks
      const replayValidation = this.checkReplayProtection(signatureInfo, context);
      if (!replayValidation.isValid) {
        return {
          isValid: false,
          error: replayValidation.error,
          algorithm: signatureInfo.algorithm,
          timestamp: startTime
        };
      }

      // Create payload for signature verification
      const payload = this.createSignaturePayload(context);
      
      if (this.config.debugMode) {
        console.log('[SignatureValidator] Signature payload:', {
          payload: payload.substring(0, 100) + '...',
          payloadLength: payload.length,
          expectedSignature: signatureInfo.signature.substring(0, 16) + '...'
        });
      }

      // Generate expected signature
      const expectedSignature = await this.generateSignature(
        payload, 
        secret, 
        signatureInfo.algorithm
      );

      // Compare signatures
      const isValid = signatureInfo.signature === expectedSignature;

      if (!isValid && this.config.debugMode) {
        console.log('[SignatureValidator] Signature mismatch:', {
          expected: expectedSignature.substring(0, 16) + '...',
          received: signatureInfo.signature.substring(0, 16) + '...',
          payloadPreview: payload.substring(0, 200)
        });
      }

      return {
        isValid,
        error: isValid ? undefined : 'Signature validation failed',
        algorithm: signatureInfo.algorithm,
        timestamp: startTime
      };

    } catch (error) {
      console.error('[SignatureValidator] Validation error:', error);
      return {
        isValid: false,
        error: `Signature validation error: ${error.message}`,
        algorithm: this.config.algorithm,
        timestamp: startTime
      };
    }
  }

  /**
   * Validate signature with automatic body reading (fixes req.clone() issue)
   */
  public async validateRequestSignature(
    req: Request,
    secret: string,
    additionalContext: { method: string; path: string; clientIP?: string } = {
      method: req.method,
      path: new URL(req.url).pathname
    }
  ): Promise<SignatureValidationResult> {
    try {
      // Read body only once to avoid conflicts
      const body = await req.text();
      
      // Convert headers to record
      const headers: Record<string, string> = {};
      req.headers.forEach((value, key) => {
        headers[key] = value;
      });

      const context: ValidationContext = {
        method: additionalContext.method,
        path: additionalContext.path,
        headers,
        body,
        timestamp: Date.now(),
        clientIP: additionalContext.clientIP
      };

      return await this.validateSignature(secret, context);
    } catch (error) {
      return {
        isValid: false,
        error: `Failed to read request for validation: ${error.message}`,
        algorithm: this.config.algorithm,
        timestamp: Date.now()
      };
    }
  }

  /**
   * Create signature headers for outgoing requests
   */
  public async createSignatureHeaders(
    method: string,
    path: string,
    body: string,
    secret: string,
    correlationId?: string
  ): Promise<Record<string, string>> {
    const timestamp = Date.now().toString();
    const headers: Record<string, string> = {
      'x-request-timestamp': timestamp,
      'x-signature-algorithm': this.config.algorithm
    };

    if (correlationId) {
      headers['x-correlation-id'] = correlationId;
    }

    // Create context for signature generation
    const context: ValidationContext = {
      method,
      path,
      headers,
      body,
      timestamp: parseInt(timestamp, 10)
    };

    const payload = this.createSignaturePayload(context);
    const signature = await this.generateSignature(payload, secret);
    
    headers['x-internal-signature'] = signature;

    // Optional: Add body hash for additional integrity
    if (body.length > 0) {
      headers['x-body-hash'] = await this.generateBodyHash(body);
    }

    return headers;
  }

  /**
   * Generate body hash for integrity checking
   */
  private async generateBodyHash(body: string): Promise<string> {
    const encoder = new TextEncoder();
    const data = encoder.encode(body);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  }

  /**
   * Verify body hash if present
   */
  private async verifyBodyHash(body: string, expectedHash: string): Promise<boolean> {
    try {
      const actualHash = await this.generateBodyHash(body);
      return actualHash === expectedHash;
    } catch {
      return false;
    }
  }

  /**
   * Get validation statistics
   */
  public getStatistics(): {
    replayCacheSize: number;
    config: SignatureConfig;
    algorithmsSupported: string[];
  } {
    return {
      replayCacheSize: this.replayCache.size,
      config: this.config,
      algorithmsSupported: ['SHA-256', 'SHA-512']
    };
  }

  /**
   * Update configuration
   */
  public updateConfig(newConfig: Partial<SignatureConfig>): void {
    this.config = { ...this.config, ...newConfig };
    
    // Restart replay cleanup if enabled/disabled
    if (this.config.enableReplayProtection && !this.cleanupInterval) {
      this.startReplayCleanup();
    } else if (!this.config.enableReplayProtection && this.cleanupInterval) {
      this.stopCleanup();
    }
  }

  /**
   * Clear replay cache (admin function)
   */
  public clearReplayCache(): void {
    this.replayCache.clear();
  }

  /**
   * Generate correlation ID for request tracking
   */
  public static generateCorrelationId(): string {
    return `sig_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }

  /**
   * Validate secret strength
   */
  public static validateSecretStrength(secret: string): { isStrong: boolean; warnings: string[] } {
    const warnings: string[] = [];
    
    if (secret.length < 32) {
      warnings.push('Secret should be at least 32 characters long');
    }
    
    if (!/[a-z]/.test(secret)) {
      warnings.push('Secret should contain lowercase letters');
    }
    
    if (!/[A-Z]/.test(secret)) {
      warnings.push('Secret should contain uppercase letters');
    }
    
    if (!/[0-9]/.test(secret)) {
      warnings.push('Secret should contain numbers');
    }
    
    if (!/[^a-zA-Z0-9]/.test(secret)) {
      warnings.push('Secret should contain special characters');
    }

    return {
      isStrong: warnings.length === 0,
      warnings
    };
  }
}

// Singleton instance for Edge Function use
export const signatureValidator = new SignatureValidator();

/**
 * Helper function for Edge Function integration
 */
export async function validateInternalSignature(
  req: Request,
  secret: string,
  method?: string,
  path?: string
): Promise<SignatureValidationResult> {
  if (!secret) {
    return {
      isValid: false,
      error: 'No internal signing secret configured',
      algorithm: 'SHA-256',
      timestamp: Date.now()
    };
  }

  const url = new URL(req.url);
  return await signatureValidator.validateRequestSignature(req, secret, {
    method: method || req.method,
    path: path || url.pathname
  });
}

/**
 * Helper function to create signed request headers
 */
export async function createSignedHeaders(
  method: string,
  path: string,
  body: string,
  secret: string,
  correlationId?: string
): Promise<Record<string, string>> {
  if (!secret) {
    throw new SecurityError('No internal signing secret configured', 'MISSING_SECRET');
  }

  return await signatureValidator.createSignatureHeaders(
    method,
    path,
    body,
    secret,
    correlationId || SignatureValidator.generateCorrelationId()
  );
}

/**
 * Middleware function for Edge Function signature validation
 */
export async function validateSignatureMiddleware(
  req: Request,
  secret: string,
  skipMethods: string[] = ['GET', 'OPTIONS']
): Promise<{ isValid: boolean; error?: string; headers?: Record<string, string> }> {
  // Skip validation for specified methods
  if (skipMethods.includes(req.method)) {
    return { isValid: true };
  }

  const result = await validateInternalSignature(req, secret);
  
  if (!result.isValid) {
    return {
      isValid: false,
      error: result.error,
      headers: {
        'X-Signature-Error': result.error || 'Unknown signature error',
        'X-Signature-Algorithm': result.algorithm
      }
    };
  }

  return { isValid: true };
}

// Development helper functions
export const DevHelpers = {
  /**
   * Generate test signature for development
   */
  async generateTestSignature(
    method: string,
    path: string,
    body: string,
    secret: string
  ): Promise<{ signature: string; headers: Record<string, string> }> {
    const headers = await createSignedHeaders(method, path, body, secret);
    return {
      signature: headers['x-internal-signature'],
      headers
    };
  },

  /**
   * Debug signature validation
   */
  async debugValidation(
    req: Request,
    secret: string
  ): Promise<{ validation: SignatureValidationResult; debugInfo: any }> {
    const validator = new SignatureValidator({ ...DEFAULT_SIGNATURE_CONFIG, debugMode: true });
    const validation = await validator.validateRequestSignature(req, secret);
    
    return {
      validation,
      debugInfo: {
        method: req.method,
        url: req.url,
        hasSignature: !!req.headers.get('x-internal-signature'),
        hasTimestamp: !!req.headers.get('x-request-timestamp'),
        timestamp: req.headers.get('x-request-timestamp'),
        algorithm: req.headers.get('x-signature-algorithm') || 'SHA-256'
      }
    };
  }
};