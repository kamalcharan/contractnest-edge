// supabase/functions/user-invitations/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { nanoid } from "https://esm.sh/nanoid@4.0.0";

const corsHeaders = {
 'Access-Control-Allow-Origin': '*',
 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
 'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

serve(async (req) => {
 // Handle CORS preflight request
 if (req.method === 'OPTIONS') {
   return new Response('ok', { headers: corsHeaders });
 }

 try {
   const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
   const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
   
   // Create supabase client
   const supabase = createClient(supabaseUrl, supabaseKey);
   
   // Parse URL for routing
   const url = new URL(req.url);
   const pathSegments = url.pathname.split('/').filter(Boolean);
   
   // Route: POST /user-invitations/validate - Validate invitation code (PUBLIC)
   if (req.method === 'POST' && pathSegments.length === 2 && pathSegments[1] === 'validate') {
     const body = await req.json();
     return await validateInvitation(supabase, body);
   }
   
   // Route: POST /user-invitations/accept - Accept invitation (PUBLIC)
   if (req.method === 'POST' && pathSegments.length === 2 && pathSegments[1] === 'accept') {
     const body = await req.json();
     return await acceptInvitation(supabase, body);
   }
   
   // Route: POST /user-invitations/accept-existing-user - Accept invitation for existing user (REQUIRES AUTH)
   if (req.method === 'POST' && pathSegments.length === 2 && pathSegments[1] === 'accept-existing-user') {
     // This endpoint requires authentication
     const authHeader = req.headers.get('Authorization');
     const token = authHeader?.replace('Bearer ', '');
     
     if (!authHeader || !token) {
       return new Response(
         JSON.stringify({ error: 'Authorization header is required' }),
         { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
       );
     }
     
     // Get user from token
     const { data: userData, error: userError } = await supabase.auth.getUser(token);
     
     if (userError || !userData?.user) {
       return new Response(
         JSON.stringify({ error: 'Invalid or expired token' }),
         { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
       );
     }
     
     const body = await req.json();
     return await acceptInvitationExistingUser(supabase, userData.user.id, body);
   }
   
   // All other routes require authentication
   // Get headers
   const authHeader = req.headers.get('Authorization');
   const tenantId = req.headers.get('x-tenant-id');
   const token = authHeader?.replace('Bearer ', '');
   
   if (!authHeader || !token) {
     return new Response(
       JSON.stringify({ error: 'Authorization header is required' }),
       { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   if (!tenantId) {
     return new Response(
       JSON.stringify({ error: 'x-tenant-id header is required' }),
       { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Get user from token
   const { data: userData, error: userError } = await supabase.auth.getUser(token);
   
   if (userError || !userData?.user) {
     return new Response(
       JSON.stringify({ error: 'Invalid or expired token' }),
       { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   const userId = userData.user.id;
   
   // Route: GET /user-invitations - List all invitations
   if (req.method === 'GET' && pathSegments.length === 1) {
     return await listInvitations(supabase, tenantId, url.searchParams);
   }
   
   // Route: GET /user-invitations/:id - Get single invitation
   if (req.method === 'GET' && pathSegments.length === 2) {
     const invitationId = pathSegments[1];
     return await getInvitation(supabase, tenantId, invitationId);
   }
   
   // Route: POST /user-invitations - Create invitation
   if (req.method === 'POST' && pathSegments.length === 1) {
     const body = await req.json();
     return await createInvitation(supabase, tenantId, userId, body);
   }
   
   // Route: POST /user-invitations/:id/resend - Resend invitation
   if (req.method === 'POST' && pathSegments.length === 3 && pathSegments[2] === 'resend') {
     const invitationId = pathSegments[1];
     return await resendInvitation(supabase, tenantId, userId, invitationId);
   }
   
   // Route: POST /user-invitations/:id/cancel - Cancel invitation
   if (req.method === 'POST' && pathSegments.length === 3 && pathSegments[2] === 'cancel') {
     const invitationId = pathSegments[1];
     return await cancelInvitation(supabase, tenantId, userId, invitationId);
   }
   
   // Invalid route
   return new Response(
     JSON.stringify({ error: 'Invalid endpoint' }),
     { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
   
 } catch (error) {
   console.error('Error processing request:', error);
   return new Response(
     JSON.stringify({ error: error.message || 'Internal server error' }),
     { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 }
});

// List invitations with filtering and pagination
async function listInvitations(supabase: any, tenantId: string, params: URLSearchParams) {
 try {
   const status = params.get('status') || 'all';
   const page = parseInt(params.get('page') || '1');
   const limit = parseInt(params.get('limit') || '10');
   const offset = (page - 1) * limit;
   
   // First get invitations without joins
   let query = supabase
     .from('t_user_invitations')
     .select('*', { count: 'exact' })
     .eq('tenant_id', tenantId)
     .order('created_at', { ascending: false });
   
   // Apply status filter
   if (status === 'pending') {
     // Include pending, sent, and resent statuses when 'pending' is requested
     query = query.in('status', ['pending', 'sent', 'resent']);
   } else if (status !== 'all') {
     query = query.eq('status', status);
   }
   
   // Apply pagination
   query = query.range(offset, offset + limit - 1);
   
   const { data: invitations, error, count } = await query;
   
   if (error) {
     console.error('Error querying invitations:', error);
     throw error;
   }
   
   // Now fetch user profiles for invited_by users
   const invitedByIds = [...new Set((invitations || []).map(inv => inv.invited_by).filter(Boolean))];
   let userProfiles = new Map();
   
   if (invitedByIds.length > 0) {
     const { data: profiles } = await supabase
       .from('t_user_profiles')
       .select('id, user_id, first_name, last_name, email')
       .in('user_id', invitedByIds);
     
     if (profiles) {
       profiles.forEach(profile => {
         userProfiles.set(profile.user_id, profile);
       });
     }
   }
   
   // Calculate expiry status and enrich data
   const enrichedData = (invitations || []).map(invitation => {
     const isExpired = ['pending', 'sent', 'resent'].includes(invitation.status) && 
       new Date(invitation.expires_at) < new Date();
     
     // Get invited by user
     const invitedByUser = userProfiles.get(invitation.invited_by) || null;
     
     // For accepted invitations, try to get the accepted user info
     let acceptedUser = null;
     if (invitation.accepted_by) {
       // We'll need to fetch this separately since we can't do complex joins
       // For now, just include the ID
       acceptedUser = { id: invitation.accepted_by };
     }
     
     return {
       ...invitation,
       invited_by_user: invitedByUser,
       is_expired: isExpired,
       time_remaining: isExpired ? null : getTimeRemaining(invitation.expires_at),
       accepted_user: acceptedUser
     };
   });
   
   return new Response(
     JSON.stringify({
       data: enrichedData,
       pagination: {
         page,
         limit,
         total: count || 0,
         totalPages: Math.ceil((count || 0) / limit)
       }
     }),
     { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 } catch (error) {
   console.error('Error listing invitations:', error);
   return new Response(
     JSON.stringify({ error: error.message || 'Failed to list invitations' }),
     { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 }
}

// Get single invitation
async function getInvitation(supabase: any, tenantId: string, invitationId: string) {
 try {
   // First get the invitation
   const { data: invitation, error } = await supabase
     .from('t_user_invitations')
     .select('*')
     .eq('id', invitationId)
     .eq('tenant_id', tenantId)
     .single();
   
   if (error) {
     console.error('Error fetching invitation:', error);
     throw error;
   }
   
   if (!invitation) {
     return new Response(
       JSON.stringify({ error: 'Invitation not found' }),
       { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Fetch invited by user profile
   let invitedByUser = null;
   if (invitation.invited_by) {
     const { data: profile } = await supabase
       .from('t_user_profiles')
       .select('id, user_id, first_name, last_name, email')
       .eq('user_id', invitation.invited_by)
       .single();
     
     invitedByUser = profile;
   }
   
   // Check if audit log table exists, if not, skip audit logs
   let auditLogs = [];
   try {
     const { data: logs } = await supabase
       .from('t_invitation_audit_log')
       .select('*')
       .eq('invitation_id', invitationId)
       .order('performed_at', { ascending: false });
     
     auditLogs = logs || [];
   } catch (auditError) {
     console.log('Audit log table might not exist, skipping audit logs');
   }
   
   return new Response(
     JSON.stringify({
       ...invitation,
       invited_by_user: invitedByUser,
       audit_logs: auditLogs
     }),
     { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 } catch (error) {
   console.error('Error fetching invitation:', error);
   return new Response(
     JSON.stringify({ error: error.message || 'Failed to fetch invitation' }),
     { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 }
}

// Create new invitation
async function createInvitation(supabase: any, tenantId: string, userId: string, body: any) {
 try {
   const { email, mobile_number, country_code, phone_code, invitation_method, role_id, custom_message } = body;
   
   // Validate input
   if (!email && !mobile_number) {
     return new Response(
       JSON.stringify({ error: 'Either email or mobile number is required' }),
       { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Check if user already exists with this email/phone
   if (email) {
     const { data: existingUser } = await supabase
       .from('t_user_profiles')
       .select('id, user_id')
       .eq('email', email)
       .single();
     
     if (existingUser) {
       // Check if user already has access to this tenant
       const { data: existingAccess } = await supabase
         .from('t_user_tenants')
         .select('id')
         .eq('user_id', existingUser.user_id)
         .eq('tenant_id', tenantId)
         .single();
       
       if (existingAccess) {
         return new Response(
           JSON.stringify({ error: 'User already has access to this workspace' }),
           { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
         );
       }
     }
   }
   
   // Check for existing pending invitation
   let existingInviteQuery = supabase
     .from('t_user_invitations')
     .select('id')
     .eq('tenant_id', tenantId)
     .in('status', ['pending', 'sent', 'resent']); // Check all "active" statuses
   
   if (email) {
     existingInviteQuery = existingInviteQuery.eq('email', email);
   } else {
     existingInviteQuery = existingInviteQuery.eq('mobile_number', mobile_number);
   }
   
   const { data: existingInvite } = await existingInviteQuery.single();
   
   if (existingInvite) {
     return new Response(
       JSON.stringify({ error: 'An invitation is already pending for this user' }),
       { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Generate invitation codes
   const userCode = generateUserCode(8);
   const secretCode = generateSecretCode(5);
   
   // Create invitation record
   const invitationData = {
     tenant_id: tenantId,
     invited_by: userId,
     user_code: userCode,
     secret_code: secretCode,
     email: email || null,
     mobile_number: mobile_number || null,
     country_code: country_code || null,
     phone_code: phone_code || null,
     invitation_method: invitation_method || 'email',
     status: 'pending',
     created_by: userId,
     expires_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString(), // 48 hours
     metadata: {
       intended_role: role_id ? { role_id } : null,
       custom_message: custom_message || null,
       invitation_url: generateInvitationLink(userCode, secretCode),
       delivery: {}
     }
   };
   
   const { data: invitation, error } = await supabase
     .from('t_user_invitations')
     .insert(invitationData)
     .select()
     .single();
   
   if (error) {
     console.error('Error creating invitation:', error);
     throw error;
   }
   
   // Log audit trail
   await logAuditTrail(supabase, invitation.id, 'created', userId, {
     invitation_method,
     recipient: email || mobile_number
   });
   
   // Get inviter details
   const { data: inviterProfile } = await supabase
     .from('t_user_profiles')
     .select('first_name, last_name')
     .eq('user_id', userId)
     .single();
   
   // Get tenant details
   const { data: tenant } = await supabase
     .from('t_tenants')
     .select('name, workspace_code')
     .eq('id', tenantId)
     .single();
   
   // Generate invitation link
   const invitationLink = generateInvitationLink(userCode, secretCode);
   
   // Send invitation
   let sendSuccess = false;
   let sendError = null;
   
   try {
     if (invitation_method === 'email' && email) {
       sendSuccess = await sendInvitationEmail({
         to: email,
         inviterName: `${inviterProfile?.first_name || 'Someone'} ${inviterProfile?.last_name || ''}`.trim(),
         workspaceName: tenant?.name || 'Workspace',
         invitationLink,
         customMessage: custom_message
       });
     } else if (invitation_method === 'sms' && mobile_number) {
       // Simply combine phone_code + mobile_number (no transformation)
       const internationalPhone = phone_code ? `+${phone_code}${mobile_number}` : mobile_number;
       sendSuccess = await sendInvitationSMS({
         to: internationalPhone,
         inviterName: `${inviterProfile?.first_name || 'Someone'}`,
         workspaceName: tenant?.name || 'Workspace',
         invitationLink
       });
     } else if (invitation_method === 'whatsapp' && mobile_number) {
       // Simply combine phone_code + mobile_number (no transformation)
       const internationalPhone = phone_code ? `+${phone_code}${mobile_number}` : mobile_number;
       sendSuccess = await sendInvitationWhatsApp({
         to: internationalPhone,
         inviterName: `${inviterProfile?.first_name || 'Someone'} ${inviterProfile?.last_name || ''}`.trim(),
         workspaceName: tenant?.name || 'Workspace',
         invitationLink,
         customMessage: custom_message
       });
     }
   } catch (error) {
     console.error('Error sending invitation:', error);
     sendError = error.message;
   }
   
   // Update invitation status based on send result
   if (sendSuccess) {
     await supabase
       .from('t_user_invitations')
       .update({ 
         status: 'sent',
         sent_at: new Date().toISOString(),
         metadata: {
           ...invitation.metadata,
           delivery: {
             status: 'sent',
             method: invitation_method,
             sent_at: new Date().toISOString()
           }
         }
       })
       .eq('id', invitation.id);
     
     await logAuditTrail(supabase, invitation.id, 'sent', userId, {
       method: invitation_method,
       recipient: email || mobile_number
     });
   } else {
     // Update metadata with send error
     await supabase
       .from('t_user_invitations')
       .update({
         metadata: {
           ...invitation.metadata,
           delivery: {
             status: 'failed',
             method: invitation_method,
             error: sendError,
             attempted_at: new Date().toISOString()
           }
         }
       })
       .eq('id', invitation.id);
   }
   
   return new Response(
     JSON.stringify({
       ...invitation,
       invitation_link: invitationLink,
       send_status: sendSuccess ? 'sent' : 'failed',
       send_error: sendError
     }),
     { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 } catch (error) {
   console.error('Error creating invitation:', error);
   return new Response(
     JSON.stringify({ error: error.message || 'Failed to create invitation' }),
     { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 }
}

// Email sending function
async function sendInvitationEmail(data: {
 to: string;
 inviterName: string;
 workspaceName: string;
 invitationLink: string;
 customMessage?: string;
}): Promise<boolean> {
 try {
   // Get email configuration from environment
   const emailProvider = Deno.env.get('EMAIL_PROVIDER') || 'msg91'; // 'msg91', 'sendgrid', 'console'

   if (emailProvider === 'console') {
     // For development/testing - just log the email
     console.log('=== INVITATION EMAIL ===');
     console.log('To:', data.to);
     console.log('Subject:', `You're invited to join ${data.workspaceName}`);
     console.log('Inviter:', data.inviterName);
     console.log('Link:', data.invitationLink);
     if (data.customMessage) {
       console.log('Custom Message:', data.customMessage);
     }
     console.log('=======================');
     return true;
   }

   // MSG91 Email Integration
   if (emailProvider === 'msg91') {
     const authKey = Deno.env.get('MSG91_AUTH_KEY');
     const senderEmail = Deno.env.get('MSG91_SENDER_EMAIL');
     const senderName = Deno.env.get('MSG91_SENDER_NAME');

     if (!authKey || !senderEmail || !senderName) {
       console.error('MSG91 email configuration is incomplete');
       return false;
     }

     const payload = {
       from: {
         email: senderEmail,
         name: senderName
       },
       to: [{ email: data.to }],
       subject: `You're invited to join ${data.workspaceName}`,
       body: generateEmailHTML(data)
     };

     const response = await fetch('https://control.msg91.com/api/v5/email/send', {
       method: 'POST',
       headers: {
         'authkey': authKey,
         'Content-Type': 'application/json'
       },
       body: JSON.stringify(payload)
     });

     const result = await response.json();
     return result.type === 'success';
   }

   // SendGrid Integration (kept as alternative)
   if (emailProvider === 'sendgrid') {
     const sendgridApiKey = Deno.env.get('SENDGRID_API_KEY');
     const fromEmail = Deno.env.get('FROM_EMAIL') || 'noreply@example.com';
     const fromName = Deno.env.get('FROM_NAME') || 'Your App';

     const response = await fetch('https://api.sendgrid.com/v3/mail/send', {
       method: 'POST',
       headers: {
         'Authorization': `Bearer ${sendgridApiKey}`,
         'Content-Type': 'application/json'
       },
       body: JSON.stringify({
         personalizations: [{
           to: [{ email: data.to }]
         }],
         from: {
           email: fromEmail,
           name: fromName
         },
         subject: `You're invited to join ${data.workspaceName}`,
         content: [
           {
             type: 'text/html',
             value: generateEmailHTML(data)
           },
           {
             type: 'text/plain',
             value: generateEmailText(data)
           }
         ]
       })
     });

     return response.ok;
   }

   return false;
 } catch (error) {
   console.error('Error sending email:', error);
   return false;
 }
}

// SMS sending function
async function sendInvitationSMS(data: {
 to: string;
 inviterName: string;
 workspaceName: string;
 invitationLink: string;
}): Promise<boolean> {
 try {
   const smsProvider = Deno.env.get('SMS_PROVIDER') || 'msg91'; // 'msg91', 'twilio', 'console'

   if (smsProvider === 'console') {
     console.log('=== INVITATION SMS ===');
     console.log('To:', data.to);
     console.log('Message:', `${data.inviterName} invited you to join ${data.workspaceName}. Accept here: ${data.invitationLink}`);
     console.log('======================');
     return true;
   }

   // MSG91 SMS Integration
   if (smsProvider === 'msg91') {
     const authKey = Deno.env.get('MSG91_AUTH_KEY');
     const senderId = Deno.env.get('MSG91_SENDER_ID');
     const route = Deno.env.get('MSG91_ROUTE') || '4'; // Default: Transactional

     if (!authKey || !senderId) {
       console.error('MSG91 SMS configuration is incomplete');
       return false;
     }

     const message = `${data.inviterName} invited you to join ${data.workspaceName}. Accept here: ${data.invitationLink}`;

     const payload = {
       sender: senderId,
       route: route,
       country: '91', // Default India, will be overridden by phone_code in actual number
       sms: [{
         message: message,
         to: [data.to] // Expecting full international number with country code
       }]
     };

     const response = await fetch('https://control.msg91.com/api/v5/flow/', {
       method: 'POST',
       headers: {
         'authkey': authKey,
         'Content-Type': 'application/json'
       },
       body: JSON.stringify(payload)
     });

     const result = await response.json();
     return result.type === 'success';
   }

   // Twilio integration (kept as alternative)
   if (smsProvider === 'twilio') {
     const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID');
     const authToken = Deno.env.get('TWILIO_AUTH_TOKEN');
     const fromNumber = Deno.env.get('TWILIO_FROM_NUMBER');

     const response = await fetch(
       `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
       {
         method: 'POST',
         headers: {
           'Authorization': 'Basic ' + btoa(`${accountSid}:${authToken}`),
           'Content-Type': 'application/x-www-form-urlencoded'
         },
         body: new URLSearchParams({
           From: fromNumber!,
           To: data.to,
           Body: `${data.inviterName} invited you to join ${data.workspaceName}. Accept here: ${data.invitationLink}`
         })
       }
     );

     return response.ok;
   }

   return false;
 } catch (error) {
   console.error('Error sending SMS:', error);
   return false;
 }
}

// WhatsApp sending function
async function sendInvitationWhatsApp(data: {
 to: string;
 inviterName: string;
 workspaceName: string;
 invitationLink: string;
 customMessage?: string;
}): Promise<boolean> {
 try {
   const whatsappProvider = Deno.env.get('WHATSAPP_PROVIDER') || 'msg91'; // 'msg91', 'console'

   if (whatsappProvider === 'console') {
     console.log('=== INVITATION WHATSAPP ===');
     console.log('To:', data.to);
     console.log('Message:', `🎉 You're Invited!\n\n${data.inviterName} has invited you to join ${data.workspaceName}\n\nAccept here: ${data.invitationLink}`);
     console.log('===========================');
     return true;
   }

   // MSG91 WhatsApp Integration
   if (whatsappProvider === 'msg91') {
     const authKey = Deno.env.get('MSG91_AUTH_KEY');
     const whatsappNumber = Deno.env.get('MSG91_WHATSAPP_NUMBER');
     const templateName = Deno.env.get('MSG91_WHATSAPP_INVITE_TEMPLATE') || 'user_invitation';

     if (!authKey || !whatsappNumber) {
       console.error('MSG91 WhatsApp configuration is incomplete');
       return false;
     }

     // Build template payload
     const payload = {
       integrated_number: whatsappNumber,
       content_type: 'template',
       payload: {
         to: data.to, // Expecting full international number with country code
         type: 'template',
         template: {
           name: templateName,
           language: {
             code: 'en',
             policy: 'deterministic'
           },
           components: [
             {
               type: 'body',
               parameters: [
                 {
                   type: 'text',
                   text: data.inviterName
                 },
                 {
                   type: 'text',
                   text: data.workspaceName
                 },
                 {
                   type: 'text',
                   text: data.invitationLink
                 }
               ]
             }
           ]
         }
       }
     };

     const response = await fetch('https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/', {
       method: 'POST',
       headers: {
         'authkey': authKey,
         'Content-Type': 'application/json'
       },
       body: JSON.stringify(payload)
     });

     const result = await response.json();
     return result.type === 'success';
   }

   return false;
 } catch (error) {
   console.error('Error sending WhatsApp:', error);
   return false;
 }
}

// Helper function to generate email HTML
function generateEmailHTML(data: any): string {
 return `
<!DOCTYPE html>
<html>
<head>
 <meta charset="utf-8">
 <meta name="viewport" content="width=device-width, initial-scale=1.0">
 <title>Invitation to ${data.workspaceName}</title>
</head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; background-color: #f5f5f5;">
 <div style="max-width: 600px; margin: 0 auto; background-color: #ffffff;">
   <div style="background-color: #4F46E5; color: white; padding: 30px; text-align: center;">
     <h1 style="margin: 0;">You're Invited!</h1>
   </div>
   <div style="padding: 40px;">
     <p>Hi there,</p>
     <p><strong>${data.inviterName}</strong> has invited you to join <strong>${data.workspaceName}</strong>.</p>
     ${data.customMessage ? `<div style="background-color: #EEF2FF; padding: 15px; margin: 20px 0; border-radius: 4px;"><p>${data.customMessage}</p></div>` : ''}
     <div style="text-align: center; margin: 40px 0;">
       <a href="${data.invitationLink}" style="background-color: #4F46E5; color: white; padding: 14px 30px; text-decoration: none; border-radius: 6px; display: inline-block;">Accept Invitation</a>
     </div>
     <p style="font-size: 14px; color: #666;">This invitation expires in 48 hours.</p>
     <p style="font-size: 14px; color: #666;">If you can't click the button, copy this link: ${data.invitationLink}</p>
   </div>
 </div>
</body>
</html>
 `;
}

// Helper function to generate email text
function generateEmailText(data: any): string {
 return `
You're Invited!

${data.inviterName} has invited you to join ${data.workspaceName}.

${data.customMessage ? `Message: ${data.customMessage}\n\n` : ''}

Accept the invitation: ${data.invitationLink}

This invitation expires in 48 hours.
 `.trim();
}

// Resend invitation
async function resendInvitation(supabase: any, tenantId: string, userId: string, invitationId: string) {
 try {
   // Get invitation
   const { data: invitation, error } = await supabase
     .from('t_user_invitations')
     .select('*')
     .eq('id', invitationId)
     .eq('tenant_id', tenantId)
     .single();
   
   if (error || !invitation) {
     return new Response(
       JSON.stringify({ error: 'Invitation not found' }),
       { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Check if invitation is in valid status
   if (!['pending', 'sent', 'resent'].includes(invitation.status)) {
     return new Response(
       JSON.stringify({ error: 'Cannot resend invitation in current status' }),
       { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Update invitation
   const { error: updateError } = await supabase
     .from('t_user_invitations')
     .update({
       status: 'resent',
       resent_count: (invitation.resent_count || 0) + 1,
       last_resent_at: new Date().toISOString(),
       last_resent_by: userId,
       expires_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString() // Reset expiry
     })
     .eq('id', invitationId);
   
   if (updateError) {
     console.error('Error updating invitation:', updateError);
     throw updateError;
   }
   
   // Log audit trail
   await logAuditTrail(supabase, invitationId, 'resent', userId, {
     resent_count: (invitation.resent_count || 0) + 1,
     method: invitation.invitation_method
   });
   
   // TODO: Actually resend the invitation
   
   return new Response(
     JSON.stringify({ 
       success: true, 
       message: 'Invitation resent successfully',
       invitation_link: generateInvitationLink(invitation.user_code, invitation.secret_code)
     }),
     { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 } catch (error) {
   console.error('Error resending invitation:', error);
   return new Response(
     JSON.stringify({ error: error.message || 'Failed to resend invitation' }),
     { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 }
}

// Cancel invitation
async function cancelInvitation(supabase: any, tenantId: string, userId: string, invitationId: string) {
 try {
   // Get invitation
   const { data: invitation, error } = await supabase
     .from('t_user_invitations')
     .select('*')
     .eq('id', invitationId)
     .eq('tenant_id', tenantId)
     .single();
   
   if (error || !invitation) {
     return new Response(
       JSON.stringify({ error: 'Invitation not found' }),
       { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Check if invitation can be cancelled
   if (['accepted', 'cancelled'].includes(invitation.status)) {
     return new Response(
       JSON.stringify({ error: 'Cannot cancel invitation in current status' }),
       { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
     );
   }
   
   // Update invitation status
   const { error: updateError } = await supabase
     .from('t_user_invitations')
     .update({
       status: 'cancelled',
       cancelled_at: new Date().toISOString(),
       cancelled_by: userId
     })
     .eq('id', invitationId);
   
   if (updateError) {
     console.error('Error cancelling invitation:', updateError);
     throw updateError;
   }
   
   // Log audit trail
   await logAuditTrail(supabase, invitationId, 'cancelled', userId, {
     previous_status: invitation.status
   });
   
   return new Response(
     JSON.stringify({ success: true, message: 'Invitation cancelled successfully' }),
     { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 } catch (error) {
   console.error('Error cancelling invitation:', error);
   return new Response(
     JSON.stringify({ error: error.message || 'Failed to cancel invitation' }),
     { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
   );
 }
}

// Validate invitation (public endpoint - no auth required)
async function validateInvitation(supabase: any, data: any) {
  try {
    const { user_code, secret_code } = data;
    
    // Get invitation details
    const { data: invitation, error } = await supabase
      .from('t_user_invitations')
      .select(`
        *,
        t_tenants!inner(
          id,
          name,
          workspace_code,
          domain,
          status
        )
      `)
      .eq('user_code', user_code)
      .eq('secret_code', secret_code)
      .single();
    
    if (error || !invitation) {
      return new Response(
        JSON.stringify({
          valid: false,
          error: 'Invalid invitation code'
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if expired
    const isExpired = new Date(invitation.expires_at) < new Date();
    
    if (isExpired) {
      return new Response(
        JSON.stringify({
          valid: false,
          error: 'This invitation has expired'
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if already accepted or cancelled
    if (invitation.status === 'cancelled') {
      return new Response(
        JSON.stringify({
          valid: false,
          error: 'This invitation has been cancelled'
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (invitation.status === 'accepted') {
      return new Response(
        JSON.stringify({
          valid: false,
          error: 'This invitation has already been accepted'
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if user exists
    let userExists = false;
    let userId = null;
    
    if (invitation.email) {
      // Check in auth.users
      const { data: authUsers } = await supabase.auth.admin.listUsers({
        filter: `email.eq.${invitation.email}`,
        page: 1,
        perPage: 1
      });
      
      if (authUsers?.users?.length > 0) {
        userExists = true;
        userId = authUsers.users[0].id;
      }
    } else if (invitation.mobile_number) {
      // Check in user_profiles by mobile
      const { data: profile } = await supabase
        .from('t_user_profiles')
        .select('user_id')
        .eq('mobile_number', invitation.mobile_number)
        .single();
      
      if (profile) {
        userExists = true;
        userId = profile.user_id;
      }
    }
    
    // Return enhanced invitation data
    return new Response(
      JSON.stringify({
        valid: true,
        invitation: {
          id: invitation.id,
          email: invitation.email,
          mobile_number: invitation.mobile_number,
          tenant: {
            id: invitation.t_tenants.id,
            name: invitation.t_tenants.name,
            workspace_code: invitation.t_tenants.workspace_code
          },
          user_exists: userExists,
          user_id: userId, // Include user_id when user exists
          status: invitation.status,
          expires_at: invitation.expires_at,
          metadata: invitation.metadata
        }
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('Error validating invitation:', error);
    return new Response(
      JSON.stringify({
        valid: false,
        error: 'Failed to validate invitation'
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Accept invitation (MODIFIED to be called ONLY for NEW USER registration)
// This is called by the auth edge function after creating the user
async function acceptInvitation(supabase: any, data: any) {
  try {
    const { user_code, secret_code, user_id, email } = data;
    
    // Validate invitation
    const { data: invitation, error: inviteError } = await supabase
      .from('t_user_invitations')
      .select('*, t_tenants!inner(id, name, workspace_code)')
      .eq('user_code', user_code)
      .eq('secret_code', secret_code)
      .single();
    
    if (inviteError || !invitation) {
      return new Response(
        JSON.stringify({ error: 'Invalid invitation' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check invitation status
    if (invitation.status === 'accepted') {
      return new Response(
        JSON.stringify({ error: 'Invitation already accepted' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (invitation.status === 'cancelled') {
      return new Response(
        JSON.stringify({ error: 'Invitation has been cancelled' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check expiration
    if (new Date(invitation.expires_at) < new Date()) {
      return new Response(
        JSON.stringify({ error: 'Invitation has expired' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Determine the user ID
    let actualUserId = user_id;
    
    // If no user_id provided but email is, look up the user
    if (!actualUserId && email) {
      console.log('Looking up user by email:', email);
      
      // First try to find in auth.users
      const { data: authUsers, error: authError } = await supabase.auth.admin.listUsers({
        filter: `email.eq.${email}`,
        page: 1,
        perPage: 1
      });
      
      if (!authError && authUsers?.users?.length > 0) {
        actualUserId = authUsers.users[0].id;
        console.log('Found user in auth.users:', actualUserId);
      } else {
        // Fallback to user_profiles
        const { data: profile } = await supabase
          .from('t_user_profiles')
          .select('user_id')
          .eq('email', email)
          .single();
        
        if (profile) {
          actualUserId = profile.user_id;
          console.log('Found user in profiles:', actualUserId);
        }
      }
    }
    
    if (!actualUserId) {
      return new Response(
        JSON.stringify({ error: 'User not found. Please ensure you have an account.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if user already has access to this tenant
    const { data: existingAccess } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', actualUserId)
      .eq('tenant_id', invitation.tenant_id)
      .single();
    
    if (existingAccess) {
      return new Response(
        JSON.stringify({ error: 'You already have access to this workspace' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Start transaction-like operations
    console.log('Accepting invitation for user:', actualUserId);
    
    // 1. Update invitation status
    const { error: updateError } = await supabase
      .from('t_user_invitations')
      .update({
        status: 'accepted',
        accepted_at: new Date().toISOString(),
        accepted_by: actualUserId
      })
      .eq('id', invitation.id);
    
    if (updateError) {
      console.error('Error updating invitation:', updateError);
      throw updateError;
    }
    
    // 2. Create user-tenant relationship
    const { data: userTenant, error: tenantError } = await supabase
      .from('t_user_tenants')
      .insert({
        user_id: actualUserId,
        tenant_id: invitation.tenant_id,
        is_default: false, // Not default since user already has other tenants
        status: 'active'
      })
      .select()
      .single();
    
    if (tenantError) {
      console.error('Error creating user-tenant relationship:', tenantError);
      
      // Try to rollback invitation update
      await supabase
        .from('t_user_invitations')
        .update({ status: 'sent' })
        .eq('id', invitation.id);
      
      throw tenantError;
    }
    
    console.log('User-tenant relationship created:', userTenant.id);
    
    // 3. Assign role if specified in invitation metadata
    if (invitation.metadata?.role_id && userTenant) {
      console.log('Assigning role:', invitation.metadata.role_id);
      
      const { error: roleError } = await supabase
        .from('t_user_tenant_roles')
        .insert({
          user_tenant_id: userTenant.id,
          role_id: invitation.metadata.role_id
        });
      
      if (roleError) {
        console.error('Error assigning role:', roleError);
        // Don't fail the whole operation if role assignment fails
      }
    }
    
    return new Response(
      JSON.stringify({
        success: true,
        message: 'Invitation accepted successfully',
        tenant: invitation.t_tenants
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('Error accepting invitation:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to accept invitation' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Accept invitation for existing user (REQUIRES AUTH)
async function acceptInvitationExistingUser(supabase: any, userId: string, body: any) {
  try {
    const { user_code, secret_code } = body;
    
    // Validate invitation
    const { data: invitation, error: inviteError } = await supabase
      .from('t_user_invitations')
      .select('*, t_tenants!inner(id, name, workspace_code)')
      .eq('user_code', user_code)
      .eq('secret_code', secret_code)
      .single();
    
    if (inviteError || !invitation) {
      return new Response(
        JSON.stringify({ error: 'Invalid invitation' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check invitation status
    if (invitation.status === 'accepted') {
      return new Response(
        JSON.stringify({ error: 'Invitation already accepted' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (invitation.status === 'cancelled') {
      return new Response(
        JSON.stringify({ error: 'Invitation has been cancelled' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check expiration
    if (new Date(invitation.expires_at) < new Date()) {
      return new Response(
        JSON.stringify({ error: 'Invitation has expired' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if user already has access to this tenant
    const { data: existingAccess } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', invitation.tenant_id)
      .single();
    
    if (existingAccess) {
      return new Response(
        JSON.stringify({ error: 'You already have access to this workspace' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Start transaction-like operations
    console.log('Accepting invitation for existing user:', userId);
    
    // 1. Update invitation status
    const { error: updateError } = await supabase
      .from('t_user_invitations')
      .update({
        status: 'accepted',
        accepted_at: new Date().toISOString(),
        accepted_by: userId
      })
      .eq('id', invitation.id);
    
    if (updateError) {
      console.error('Error updating invitation:', updateError);
      throw updateError;
    }
    
    // 2. Create user-tenant relationship
    const { data: userTenant, error: tenantError } = await supabase
      .from('t_user_tenants')
      .insert({
        user_id: userId,
        tenant_id: invitation.tenant_id,
        is_default: false,
        status: 'active'
      })
      .select()
      .single();
    
    if (tenantError) {
      console.error('Error creating user-tenant relationship:', tenantError);
      
      // Try to rollback invitation update
      await supabase
        .from('t_user_invitations')
        .update({ status: 'sent' })
        .eq('id', invitation.id);
      
      throw tenantError;
    }
    
    console.log('User-tenant relationship created:', userTenant.id);
    
    // 3. Assign role if specified in invitation metadata
    if (invitation.metadata?.role_id && userTenant) {
      console.log('Assigning role:', invitation.metadata.role_id);
      
      const { error: roleError } = await supabase
        .from('t_user_tenant_roles')
        .insert({
          user_tenant_id: userTenant.id,
          role_id: invitation.metadata.role_id
        });
      
      if (roleError) {
        console.error('Error assigning role:', roleError);
        // Don't fail the whole operation if role assignment fails
      }
    }
    
    return new Response(
      JSON.stringify({
        success: true,
        message: 'Invitation accepted successfully',
        tenant: invitation.t_tenants
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('Error accepting invitation:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to accept invitation' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Helper functions
function generateUserCode(length: number = 8): string {
 return nanoid(length).toUpperCase();
}

function generateSecretCode(length: number = 5): string {
 return nanoid(length).toUpperCase();
}

function generateInvitationLink(userCode: string, secretCode: string): string {
 const baseUrl = Deno.env.get('FRONTEND_URL') || 'http://localhost:3000';
 return `${baseUrl}/accept-invitation?code=${userCode}&secret=${secretCode}`;
}

function getTimeRemaining(expiresAt: string): string {
 const now = new Date();
 const expiry = new Date(expiresAt);
 const diff = expiry.getTime() - now.getTime();
 
 if (diff <= 0) return 'Expired';
 
 const hours = Math.floor(diff / (1000 * 60 * 60));
 const minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
 
 if (hours > 24) {
   const days = Math.floor(hours / 24);
   return `${days} day${days > 1 ? 's' : ''} remaining`;
 }
 
 return `${hours}h ${minutes}m remaining`;
}

async function logAuditTrail(
 supabase: any, 
 invitationId: string, 
 action: string, 
 performedBy: string, 
 metadata: any = {}
) {
 try {
   // Check if audit table exists by attempting to insert
   const { error } = await supabase
     .from('t_invitation_audit_log')
     .insert({
       invitation_id: invitationId,
       action,
       performed_by: performedBy,
       performed_at: new Date().toISOString(),
       metadata
     });
   
   if (error) {
     console.log('Audit log table might not exist, skipping audit log');
   }
 } catch (error) {
   console.error('Error logging audit trail:', error);
   // Don't throw - audit logging failure shouldn't break the main operation
 }
}