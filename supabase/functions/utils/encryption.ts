// supabase/functions/utils/encryption.ts
import { crypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";
import { encode as encodeBase64, decode as decodeBase64 } from "https://deno.land/std@0.168.0/encoding/base64.ts";

/**
 * Encrypt data using AES-GCM encryption
 */
export async function encryptData(data: any, encryptionKey: string): Promise<string> {
  // Convert data to JSON string
  const jsonData = JSON.stringify(data);
  
  // Convert string to bytes
  const dataBytes = new TextEncoder().encode(jsonData);
  
  // Generate a random IV (Initialization Vector)
  const iv = crypto.getRandomValues(new Uint8Array(12));
  
  // Convert the encryption key from string to bytes
  const keyBytes = new TextEncoder().encode(encryptionKey);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt']
  );
  
  // Encrypt the data
  const encryptedContent = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: iv },
    cryptoKey,
    dataBytes
  );
  
  // Combine IV and encrypted content
  const encryptedBytes = new Uint8Array(iv.length + encryptedContent.byteLength);
  encryptedBytes.set(iv, 0);
  encryptedBytes.set(new Uint8Array(encryptedContent), iv.length);
  
  // Convert to base64 for storage
  return encodeBase64(encryptedBytes);
}

/**
 * Decrypt data that was encrypted with AES-GCM
 */
export async function decryptData(encryptedData: string, encryptionKey: string): Promise<any> {
  // Convert base64 to bytes
  const encryptedBytes = decodeBase64(encryptedData);
  
  // Extract IV (first 12 bytes)
  const iv = encryptedBytes.slice(0, 12);
  
  // Extract encrypted content (rest of the bytes)
  const ciphertext = encryptedBytes.slice(12);
  
  // Convert the encryption key from string to bytes
  const keyBytes = new TextEncoder().encode(encryptionKey);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );
  
  // Decrypt the data
  const decryptedContent = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: iv },
    cryptoKey,
    ciphertext
  );
  
  // Convert decrypted content to string
  const jsonString = new TextDecoder().decode(decryptedContent);
  
  // Parse JSON to object
  return JSON.parse(jsonString);
}