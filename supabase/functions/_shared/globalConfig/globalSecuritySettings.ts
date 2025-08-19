// File: supabase/functions/_shared/globalConfig/globalSecuritySettings.ts

import { TenantConfigManager } from './tenantConfigManager.ts';
import { EdgeFunction, SecuritySettings, GlobalSettings } from './types.ts';

export interface SecurityValidationResult {
  isValid: boolean;
  errors: string[];
  warnings: string[];
  securityLevel: string;
}

export interface RequestContext {
  tenant_id: string;
  user_id?: string;
  edge_function: EdgeFunction;
  request: Request;
  body?: string;
  ip_address?: string;
  user_agent?: string;
}

export class GlobalSecuritySettings {
  private static configManager: TenantConfigManager;

  static initialize(configManager: TenantConfigManager): void {
    this.configManager = configManager;
    console.log('🔐 GlobalSecuritySettings - initialized');
  }

  /**
   * Validate request security requirements
   */
  static async validateRequest(context: RequestContext): Promise<SecurityValidationResult> {
    console.log('🔐 GlobalSecuritySettings - validating request:', {
      tenantId: context.tenant_id,
      edgeFunction: context.edge_function,
      hasBody: !!context.body,
      ipAddress: context.ip_address
    });

    const errors: string[] = [];
    const warnings: string[] = [];

    try {
      const { config, globalSettings } = await this.configManager.getConfig(context.tenant_id, context.edge_function);
      const securitySettings = config.security_settings;

      // Check SSL requirement
      if (securitySettings.require_ssl && !this.isSSLRequest(context.request)) {
        errors.push('SSL/HTTPS is required for this endpoint');
      }

      // Check request size limits
      if (context.body && this.getRequestSizeInMB(context.body) > securitySettings.max_request_size_mb) {
        errors.push(`Request size exceeds limit of ${securitySettings.max_request_size_mb}MB`);
      }

      // Check HMAC signature if required
      if (securitySettings.require_hmac) {
        const hmacResult = await this.validateHMACSignature(context, securitySettings);
        if (!hmacResult.isValid) {
          errors.push(hmacResult.error || 'HMAC signature validation failed');
        }
      }

      // Check allowed origins
      if (securitySettings.allowed_origins.length > 0) {
        const originResult = this.validateOrigin(context.request, securitySettings.allowed_origins);
        if (!originResult.isValid) {
          errors.push('Request origin not allowed');
        }
      }

      // Check for malicious patterns
      const threatResult = this.checkSecurityThreats(context);
      errors.push(...threatResult.threats);
      warnings.push(...threatResult.warnings);

      // Global security level checks
      const globalSecurityResult = this.validateGlobalSecurity(context, globalSettings);
      errors.push(...globalSecurityResult.errors);
      warnings.push(...globalSecurityResult.warnings);

      const isValid = errors.length === 0;

      console.log('✅ GlobalSecuritySettings - validation complete:', {
        tenantId: context.tenant_id,
        isValid,
        errorsCount: errors.length,
        warningsCount: warnings.length,
        securityLevel: globalSettings.security_level
      });

      return {
        isValid,
        errors,
        warnings,
        securityLevel: globalSettings.security_level
      };

    } catch (error) {
      console.error('❌ GlobalSecuritySettings - validation failed:', error);
      
      return {
        isValid: false,
        errors: ['Security validation failed'],
        warnings: [],
        securityLevel: 'unknown'
      };
    }
  }

  /**
   * Validate HMAC signature
   */
  static async validateHMACSignature(
    context: RequestContext,
    securitySettings: SecuritySettings
  ): Promise<{ isValid: boolean; error?: string }> {
    console.log('🔐 GlobalSecuritySettings - validating HMAC signature');

    try {
      const signature = context.request.headers.get('x-signature-sha256');
      const signingSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

      if (!signature) {
        return { isValid: false, error: 'Missing HMAC signature' };
      }

      if (!signingSecret) {
        return { isValid: false, error: 'HMAC verification not configured' };
      }

      // Check if algorithm is allowed
      const signatureAlgorithm = signature.startsWith('sha256=') ? 'sha256' : 
                                signature.startsWith('sha512=') ? 'sha512' : 'unknown';

      if (!securitySettings.hmac_algorithms.includes(signatureAlgorithm)) {
        return { isValid: false, error: `HMAC algorithm ${signatureAlgorithm} not allowed` };
      }

      const expectedSignature = await this.generateHMACSignature(
        context.body || '',
        signingSecret,
        signatureAlgorithm
      );

      const providedSignature = signature.replace(`${signatureAlgorithm}=`, '');
      const isValid = this.constantTimeCompare(expectedSignature, providedSignature);

      console.log('✅ GlobalSecuritySettings - HMAC validation complete:', {
        isValid,
        algorithm: signatureAlgorithm
      });

      return {
        isValid,
        error: isValid ? undefined : 'Invalid HMAC signature'
      };

    } catch (error) {
      console.error('❌ GlobalSecuritySettings - HMAC validation error:', error);
      return { isValid: false, error: 'HMAC validation failed' };
    }
  }

  /**
   * Check for security threats in request
   */
  static checkSecurityThreats(context: RequestContext): {
    threats: string[];
    warnings: string[];
  } {
    console.log('🔐 GlobalSecuritySettings - checking security threats');

    const threats: string[] = [];
    const warnings: string[] = [];

    // Check request body for threats
    if (context.body) {
      const sqlInjectionResult = this.checkSQLInjection(context.body);
      if (!sqlInjectionResult.isSafe) {
        threats.push('Potential SQL injection detected');
      }

      const xssResult = this.checkXSSThreats(context.body);
      if (!xssResult.isSafe) {
        threats.push('Potential XSS attack detected');
      }

      const commandInjectionResult = this.checkCommandInjection(context.body);
      if (!commandInjectionResult.isSafe) {
        threats.push('Potential command injection detected');
      }
    }

    // Check headers for threats
    const headerThreats = this.checkHeaderThreats(context.request);
    threats.push(...headerThreats.threats);
    warnings.push(...headerThreats.warnings);

    // Check for suspicious patterns in user agent
    if (context.user_agent) {
      const userAgentResult = this.analyzeUserAgent(context.user_agent);
      warnings.push(...userAgentResult.warnings);
    }

    console.log('✅ GlobalSecuritySettings - security threats check complete:', {
      threatsFound: threats.length,
      warningsFound: warnings.length
    });

    return { threats, warnings };
  }

  /**
   * Sanitize input data
   */
  static sanitizeInput(
    input: string,
    options: {
      maxLength?: number;
      allowedPattern?: RegExp;
      removeHtml?: boolean;
      removeScripts?: boolean;
    } = {}
  ): string {
    console.log('🔐 GlobalSecuritySettings - sanitizing input:', {
      inputLength: input.length,
      maxLength: options.maxLength,
      hasPattern: !!options.allowedPattern
    });

    let sanitized = input.trim();

    // Apply length limit
    if (options.maxLength) {
      sanitized = sanitized.substring(0, options.maxLength);
    }

    // Remove HTML if requested
    if (options.removeHtml) {
      sanitized = sanitized.replace(/<[^>]*>/g, '');
    }

    // Remove script tags and javascript
    if (options.removeScripts) {
      sanitized = sanitized
        .replace(/<script[\s\S]*?>[\s\S]*?<\/script>/gi, '')
        .replace(/javascript:/gi, '')
        .replace(/on\w+\s*=/gi, '');
    }

    // Apply allowed pattern
    if (options.allowedPattern && !options.allowedPattern.test(sanitized)) {
      console.warn('⚠️ GlobalSecuritySettings - input does not match allowed pattern');
      return '';
    }

    // Basic XSS prevention
    sanitized = sanitized
      .replace(/[<>]/g, '')
      .replace(/javascript:/gi, '')
      .replace(/data:/gi, '')
      .replace(/vbscript:/gi, '');

    console.log('✅ GlobalSecuritySettings - input sanitized:', {
      originalLength: input.length,
      sanitizedLength: sanitized.length
    });

    return sanitized;
  }

  /**
   * Generate security headers for response
   */
  static async getSecurityHeaders(
    tenantId: string,
    edgeFunction: EdgeFunction
  ): Promise<Record<string, string>> {
    console.log('🔐 GlobalSecuritySettings - generating security headers');

    try {
      const { config, globalSettings } = await this.configManager.getConfig(tenantId, edgeFunction);
      
      const headers: Record<string, string> = {
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'X-XSS-Protection': '1; mode=block',
        'Referrer-Policy': 'strict-origin-when-cross-origin',
        'Permissions-Policy': 'geolocation=(), microphone=(), camera=()',
        'X-Security-Level': globalSettings.security_level
      };

      // Add Content Security Policy based on security level
      switch (globalSettings.security_level) {
        case 'enhanced':
          headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'";
          headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains; preload';
          break;
        case 'standard':
          headers['Content-Security-Policy'] = "default-src 'self'";
          headers['Strict-Transport-Security'] = 'max-age=31536000';
          break;
        case 'basic':
        default:
          headers['Content-Security-Policy'] = "default-src 'self' 'unsafe-inline'";
          break;
      }

      console.log('✅ GlobalSecuritySettings - security headers generated:', {
        headersCount: Object.keys(headers).length,
        securityLevel: globalSettings.security_level
      });

      return headers;
    } catch (error) {
      console.error('❌ GlobalSecuritySettings - security headers generation failed:', error);
      
      // Return basic security headers as fallback
      return {
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'X-XSS-Protection': '1; mode=block'
      };
    }
  }

  // Private helper methods

  private static isSSLRequest(request: Request): boolean {
    const url = new URL(request.url);
    return url.protocol === 'https:';
  }

  private static getRequestSizeInMB(body: string): number {
    return new Blob([body]).size / (1024 * 1024);
  }

  private static async generateHMACSignature(
    message: string,
    secret: string,
    algorithm: string = 'sha256'
  ): Promise<string> {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(message);

    const hashAlgorithm = algorithm === 'sha512' ? 'SHA-512' : 'SHA-256';

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: hashAlgorithm },
      false,
      ['sign']
    );

    const signature = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const hashArray = Array.from(new Uint8Array(signature));
    const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

    return hashHex;
  }

  private static constantTimeCompare(a: string, b: string): boolean {
    if (a.length !== b.length) {
      return false;
    }

    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }

    return result === 0;
  }

  private static validateOrigin(request: Request, allowedOrigins: string[]): { isValid: boolean } {
    const origin = request.headers.get('origin');
    
    if (!origin) {
      return { isValid: true }; // Allow requests without origin (e.g., same-origin)
    }

    return {
      isValid: allowedOrigins.length === 0 || allowedOrigins.includes(origin)
    };
  }

  private static checkSQLInjection(input: string): { isSafe: boolean; threats: string[] } {
    const sqlPatterns = [
      /(\b(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC|EXECUTE)\b)/i,
      /(\bUNION\b.*\bSELECT\b)/i,
      /(\b(OR|AND)\b.*['"].*['"].*=.*['"].*['"])/i,
      /(;.*--)|(\/\*.*\*\/)/,
      /(\bxp_|\bsp_)/i,
      /(\b(INFORMATION_SCHEMA|SYSOBJECTS|SYSCOLUMNS)\b)/i
    ];

    const threats: string[] = [];
    
    sqlPatterns.forEach((pattern, index) => {
      if (pattern.test(input)) {
        threats.push(`SQL_PATTERN_${index + 1}`);
      }
    });

    return { isSafe: threats.length === 0, threats };
  }

  private static checkXSSThreats(input: string): { isSafe: boolean; threats: string[] } {
    const xssPatterns = [
      /<script[\s\S]*?>[\s\S]*?<\/script>/gi,
      /<iframe[\s\S]*?>[\s\S]*?<\/iframe>/gi,
      /javascript:/gi,
      /on\w+\s*=/gi,
      /<img[\s\S]*?onerror[\s\S]*?>/gi,
      /eval\s*\(/gi,
      /document\.cookie/gi,
      /window\.location/gi
    ];

    const threats: string[] = [];
    
    xssPatterns.forEach((pattern, index) => {
      if (pattern.test(input)) {
        threats.push(`XSS_PATTERN_${index + 1}`);
      }
    });

    return { isSafe: threats.length === 0, threats };
  }

  private static checkCommandInjection(input: string): { isSafe: boolean; threats: string[] } {
    const commandPatterns = [
      /(\||&|;|`|\$\(|\${)/,
      /(rm\s|wget\s|curl\s|nc\s|netcat\s)/i,
      /(\.\.\/|\.\.\\)/,
      /(\bchmod\b|\bchown\b|\bsu\b|\bsudo\b)/i
    ];

    const threats: string[] = [];
    
    commandPatterns.forEach((pattern, index) => {
      if (pattern.test(input)) {
        threats.push(`CMD_PATTERN_${index + 1}`);
      }
    });

    return { isSafe: threats.length === 0, threats };
  }

  private static checkHeaderThreats(request: Request): { threats: string[]; warnings: string[] } {
    const threats: string[] = [];
    const warnings: string[] = [];

    // Check for suspicious headers
    const suspiciousHeaders = [
      'x-forwarded-host',
      'x-originating-ip',
      'x-remote-ip',
      'x-cluster-client-ip'
    ];

    for (const header of suspiciousHeaders) {
      if (request.headers.get(header)) {
        warnings.push(`Suspicious header detected: ${header}`);
      }
    }

    // Check for overly long header values
    for (const [name, value] of request.headers.entries()) {
      if (value.length > 8192) {
        threats.push(`Header ${name} exceeds maximum length`);
      }
    }

    return { threats, warnings };
  }

  private static analyzeUserAgent(userAgent: string): { warnings: string[] } {
    const warnings: string[] = [];

    // Check for suspicious user agent patterns
    const suspiciousPatterns = [
      /bot|crawler|spider/i,
      /curl|wget|httpie/i,
      /scanner|audit|test/i
    ];

    for (const pattern of suspiciousPatterns) {
      if (pattern.test(userAgent)) {
        warnings.push('Suspicious user agent detected');
        break;
      }
    }

    return { warnings };
  }

  private static validateGlobalSecurity(
    context: RequestContext,
    globalSettings: GlobalSettings
  ): { errors: string[]; warnings: string[] } {
    const errors: string[] = [];
    const warnings: string[] = [];

    // Additional security checks based on global security level
    switch (globalSettings.security_level) {
      case 'enhanced':
        // Strict security checks
        if (!context.user_id) {
          errors.push('User authentication required for enhanced security level');
        }
        break;
      case 'standard':
        // Standard security checks
        if (!context.ip_address) {
          warnings.push('IP address not available for tracking');
        }
        break;
      case 'basic':
      default:
        // Basic security checks only
        break;
    }

    return { errors, warnings };
  }
}