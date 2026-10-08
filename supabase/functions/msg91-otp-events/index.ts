// MSG91 OTP Widget's deprecated Events and Actions webhook requires a POST URL.
// Phone ownership is established only by whatsapp-access calling MSG91's
// verifyAccessToken API. Callback bodies are deliberately not read, logged,
// persisted, or trusted for any account/workspace decision.
Deno.serve((request: Request) => {
  if (request.method !== 'POST') {
    return new Response('POST required', { status: 405, headers: { Allow: 'POST' } });
  }
  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
});
