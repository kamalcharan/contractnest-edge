import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { SMTPClient } from 'https://deno.land/x/denomailer@1.6.0/mod.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { 
      status: 200,
      headers: corsHeaders 
    })
  }

  // Only allow POST method
  if (req.method !== 'POST') {
    return new Response('Method not allowed', {
      status: 405,
      headers: corsHeaders
    })
  }

  try {
    const { name, email, company } = await req.json()
    
    // Validate required fields
    if (!name || !email || !company) {
      return new Response(JSON.stringify({ 
        error: 'Missing required fields: name, email, company' 
      }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const currentDate = new Date().toLocaleDateString('en-IN', { 
      year: 'numeric', 
      month: 'long', 
      day: 'numeric' 
    })

    const client = new SMTPClient({
      connection: {
        hostname: "mail.vikuna.io",
        port: 465,
        tls: true,
        auth: {
          username: "onboarding@vikuna.io",
          password: Deno.env.get('SMTP_PASSWORD'),
        },
      },
    })

    // Professional HTML Email Template (FULL VERSION)
    const htmlTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to ContractNest - Early Adopter Program</title>
</head>
<body style="margin: 0; padding: 0; background-color: #f1f4f8; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;">
    <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background-color: #f1f4f8;">
        <tr>
            <td align="center" style="padding: 40px 20px;">
                <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="600" style="max-width: 600px; background-color: #ffffff; border-radius: 16px; box-shadow: 0 20px 60px rgba(20, 21, 24, 0.1); overflow: hidden;">
                    
                    <!-- Header with Gradient -->
                    <tr>
                        <td style="background: linear-gradient(135deg, #f83b46 0%, #ff6a73 100%); padding: 50px 40px; text-align: center;">
                            <h1 style="color: #ffffff; font-size: 36px; font-weight: 900; margin: 0 0 10px 0; letter-spacing: -1px;">ContractNest</h1>
                            <p style="color: rgba(255,255,255,0.95); font-size: 18px; margin: 0 0 20px 0; font-weight: 500;">Contract Management Simplified</p>
                            
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin: 20px auto 0;">
                                <tr>
                                    <td style="background: rgba(255,255,255,0.2); border: 1px solid rgba(255,255,255,0.3); border-radius: 25px; padding: 12px 24px;">
                                        <p style="color: #ffffff; font-size: 16px; font-weight: 700; margin: 0;">🎉 Welcome to Early Adopters!</p>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- Welcome Message -->
                    <tr>
                        <td style="padding: 40px;">
                            <h2 style="color: #141518; font-size: 28px; font-weight: 800; margin: 0 0 15px 0;">Welcome ${name}!</h2>
                            <p style="color: #677681; font-size: 18px; line-height: 1.6; margin: 0 0 30px 0;">Thank you for joining the <strong style="color: #f83b46;">ContractNest Early Adopter Program</strong>! You've secured an exclusive lifetime deal that will save you thousands.</p>
                        </td>
                    </tr>
                    
                    <!-- Savings Highlight -->
                    <tr>
                        <td style="padding: 0 40px 30px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background: linear-gradient(135deg, #18aa99 0%, #16857b 100%); border-radius: 12px;">
                                <tr>
                                    <td style="padding: 30px; text-align: center;">
                                        <h3 style="color: #ffffff; font-size: 28px; font-weight: 800; margin: 0 0 10px 0;">💰 You're Saving ₹72,000+ Annually!</h3>
                                        <p style="color: rgba(255,255,255,0.95); font-size: 20px; margin: 0; font-weight: 600;">Early Adopter Price: ₹1,000/month FOREVER</p>
                                        <p style="color: rgba(255,255,255,0.8); font-size: 16px; margin: 10px 0 0 0;">Regular Price: ₹4,000/month</p>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- Benefits Section -->
                    <tr>
                        <td style="padding: 0 40px 30px;">
                            <h3 style="color: #141518; font-size: 24px; font-weight: 700; margin: 0 0 20px 0; text-align: center;">🎯 Your Exclusive Benefits</h3>
                            
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin-bottom: 12px;">
                                <tr>
                                    <td style="padding: 15px 20px; background: rgba(248, 59, 70, 0.05); border-radius: 8px; border-left: 4px solid #f83b46;">
                                        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                            <tr>
                                                <td width="40" style="vertical-align: middle;">
                                                    <div style="width: 32px; height: 32px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 18px; text-align: center; line-height: 32px;">🚀</div>
                                                </td>
                                                <td style="padding-left: 15px; vertical-align: middle;">
                                                    <p style="color: #141518; font-weight: 700; font-size: 16px; margin: 0;">Priority Access at Launch (September 2024)</p>
                                                </td>
                                            </tr>
                                        </table>
                                    </td>
                                </tr>
                            </table>
                            
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin-bottom: 12px;">
                                <tr>
                                    <td style="padding: 15px 20px; background: rgba(248, 59, 70, 0.05); border-radius: 8px; border-left: 4px solid #f83b46;">
                                        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                            <tr>
                                                <td width="40" style="vertical-align: middle;">
                                                    <div style="width: 32px; height: 32px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 18px; text-align: center; line-height: 32px;">🤖</div>
                                                </td>
                                                <td style="padding-left: 15px; vertical-align: middle;">
                                                    <p style="color: #141518; font-weight: 700; font-size: 16px; margin: 0;">70% OFF AI Automation Features (December 2024)</p>
                                                </td>
                                            </tr>
                                        </table>
                                    </td>
                                </tr>
                            </table>
                            
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin-bottom: 12px;">
                                <tr>
                                    <td style="padding: 15px 20px; background: rgba(248, 59, 70, 0.05); border-radius: 8px; border-left: 4px solid #f83b46;">
                                        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                            <tr>
                                                <td width="40" style="vertical-align: middle;">
                                                    <div style="width: 32px; height: 32px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 18px; text-align: center; line-height: 32px;">👥</div>
                                                </td>
                                                <td style="padding-left: 15px; vertical-align: middle;">
                                                    <p style="color: #141518; font-weight: 700; font-size: 16px; margin: 0;">Dedicated Onboarding & Priority Support</p>
                                                </td>
                                            </tr>
                                        </table>
                                    </td>
                                </tr>
                            </table>
                            
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                <tr>
                                    <td style="padding: 15px 20px; background: rgba(248, 59, 70, 0.05); border-radius: 8px; border-left: 4px solid #f83b46;">
                                        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                            <tr>
                                                <td width="40" style="vertical-align: middle;">
                                                    <div style="width: 32px; height: 32px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 18px; text-align: center; line-height: 32px;">📈</div>
                                                </td>
                                                <td style="padding-left: 15px; vertical-align: middle;">
                                                    <p style="color: #141518; font-weight: 700; font-size: 16px; margin: 0;">Exclusive Product Roadmap Access & Beta Features</p>
                                                </td>
                                            </tr>
                                        </table>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- Next Steps -->
                    <tr>
                        <td style="padding: 0 40px 30px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background: #f8f9fa; border-radius: 12px; border: 1px solid #e9ecef;">
                                <tr>
                                    <td style="padding: 25px;">
                                        <h3 style="color: #141518; font-size: 22px; font-weight: 700; margin: 0 0 20px 0; text-align: center;">📋 What Happens Next?</h3>
                                        
                                        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                            <tr>
                                                <td style="padding: 8px 0; vertical-align: top; width: 30px;">
                                                    <div style="width: 24px; height: 24px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 14px; text-align: center; line-height: 24px;">1</div>
                                                </td>
                                                <td style="padding: 8px 0 8px 15px; vertical-align: top;">
                                                    <p style="color: #141518; font-size: 16px; margin: 0;"><strong>Info Pack Delivery:</strong> Detailed ContractNest guide within 24 hours</p>
                                                </td>
                                            </tr>
                                            <tr>
                                                <td style="padding: 8px 0; vertical-align: top;">
                                                    <div style="width: 24px; height: 24px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 14px; text-align: center; line-height: 24px;">2</div>
                                                </td>
                                                <td style="padding: 8px 0 8px 15px; vertical-align: top;">
                                                    <p style="color: #141518; font-size: 16px; margin: 0;"><strong>Personal Demo:</strong> One-on-one product walkthrough session</p>
                                                </td>
                                            </tr>
                                            <tr>
                                                <td style="padding: 8px 0; vertical-align: top;">
                                                    <div style="width: 24px; height: 24px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 14px; text-align: center; line-height: 24px;">3</div>
                                                </td>
                                                <td style="padding: 8px 0 8px 15px; vertical-align: top;">
                                                    <p style="color: #141518; font-size: 16px; margin: 0;"><strong>Launch Updates:</strong> Exclusive timeline and feature previews</p>
                                                </td>
                                            </tr>
                                            <tr>
                                                <td style="padding: 8px 0; vertical-align: top;">
                                                    <div style="width: 24px; height: 24px; background: #f83b46; border-radius: 50%; color: white; font-weight: bold; font-size: 14px; text-align: center; line-height: 24px;">4</div>
                                                </td>
                                                <td style="padding: 8px 0 8px 15px; vertical-align: top;">
                                                    <p style="color: #141518; font-size: 16px; margin: 0;"><strong>Beta Access:</strong> First to experience new features</p>
                                                </td>
                                            </tr>
                                        </table>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- Pro Tip -->
                    <tr>
                        <td style="padding: 0 40px 30px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background: #fff3cd; border-radius: 8px; border-left: 4px solid #ffc107;">
                                <tr>
                                    <td style="padding: 20px;">
                                        <p style="color: #856404; font-size: 16px; margin: 0; font-weight: 600;">💡 <strong>Pro Tip:</strong> Add onboarding@vikuna.io to your contacts to ensure you receive all updates and the detailed info pack!</p>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- CTA Button -->
                    <tr>
                        <td style="padding: 0 40px 40px; text-align: center;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin: 0 auto;">
                                <tr>
                                    <td style="background: linear-gradient(135deg, #f83b46 0%, #ff6a73 100%); border-radius: 8px; padding: 16px 32px;">
                                        <a href="mailto:charan@vikuna.io?subject=ContractNest Early Adopter - Questions" style="color: #ffffff; text-decoration: none; font-weight: 700; font-size: 18px; display: block;">📧 Have Questions? Contact Us</a>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- Contact Information -->
                    <tr>
                        <td style="padding: 0 40px 30px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background: #f8f9fa; border-radius: 8px;">
                                <tr>
                                    <td style="padding: 25px; text-align: center;">
                                        <h4 style="color: #141518; font-size: 20px; font-weight: 700; margin: 0 0 15px 0;">Need Immediate Help?</h4>
                                        <p style="color: #677681; font-size: 16px; margin: 5px 0;">📧 Email: <a href="mailto:charan@vikuna.io" style="color: #f83b46; text-decoration: none; font-weight: 600;">charan@vikuna.io</a></p>
                                        <p style="color: #677681; font-size: 16px; margin: 5px 0;">📞 Phone: <a href="tel:+919949701175" style="color: #f83b46; text-decoration: none; font-weight: 600;">+91-9949701175</a></p>
                                        <p style="color: #677681; font-size: 14px; margin: 15px 0 0 0;">We typically respond within 2 hours during business hours</p>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    
                    <!-- Footer -->
                    <tr>
                        <td style="background: #141518; padding: 30px 40px; text-align: center;">
                            <h3 style="color: #ffffff; font-size: 24px; font-weight: 800; margin: 0 0 10px 0;">ContractNest</h3>
                            <p style="color: rgba(255,255,255,0.8); font-size: 16px; margin: 0 0 15px 0;">Simplifying Contract Management</p>
                            <div style="height: 1px; background: rgba(255,255,255,0.2); margin: 20px 0;"></div>
                            <p style="color: rgba(255,255,255,0.6); font-size: 14px; margin: 0;">
                                <strong>Company:</strong> ${company}<br>
                                <strong>Status:</strong> Early Adopter Program Member<br>
                                <strong>Member Since:</strong> ${currentDate}
                            </p>
                        </td>
                    </tr>
                </table>
            </td>
        </tr>
    </table>
</body>
</html>`

    await client.send({
      from: "ContractNest <onboarding@vikuna.io>",
      to: email,
      subject: "🎉 Welcome to ContractNest Early Adopter Program!",
      html: htmlTemplate,
    })

    await client.close()

    return new Response(JSON.stringify({ 
      success: true, 
      message: 'Welcome email sent successfully' 
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })

  } catch (error) {
    console.error('Email sending error:', error)
    return new Response(JSON.stringify({ 
      error: 'Failed to send email',
      details: error.message 
    }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})