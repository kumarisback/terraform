// The app's three synthetic checks, made from outside the cluster through
// its public entry point (BASE_URL: the ALB now, the domain later). The
// same checks run inside the cluster every 30s (gitops
// observability/components/synthetic-probes); this one also covers DNS, the
// ALB, its listeners and security group, and TLS once there is a
// certificate.
//
// Needs syn-nodejs-puppeteer-13.1 or later (the @aws/synthetics-* module
// names). Each check is a step: a failed step fails the run but the others
// still run (executeHttpStep's default), so the report shows which one.
const synthetics = require('@aws/synthetics-puppeteer');

const base = new URL(process.env.BASE_URL);

function request(method, path, body) {
  const headers = { 'User-Agent': synthetics.getCanaryUserAgentString() };
  if (body) headers['Content-Type'] = 'application/json';
  return {
    protocol: base.protocol,
    hostname: base.hostname,
    port: base.port || (base.protocol === 'https:' ? 443 : 80),
    method,
    path,
    headers,
    body,
  };
}

// Passes when the response has this status and, if given, a body matching
// the pattern.
function expect(status, bodyPattern) {
  return (res) => new Promise((resolve, reject) => {
    let body = '';
    res.on('data', (chunk) => { body += chunk; });
    res.on('error', reject);
    res.on('end', () => {
      if (res.statusCode !== status) {
        reject(new Error(`expected HTTP ${status}, got ${res.statusCode}`));
      } else if (bodyPattern && !bodyPattern.test(body)) {
        reject(new Error(`body does not match ${bodyPattern}`));
      } else {
        resolve();
      }
    });
  });
}

exports.handler = async () => {
  await synthetics.executeHttpStep('frontend-home', request('GET', '/'), expect(200));
  await synthetics.executeHttpStep('order-service-status', request('GET', '/api/orders/status'),
    expect(200, /"status"\s*:\s*"ONLINE"/));
  // A user that doesn't exist must be refused with 401: user-service, its
  // security chain and MongoDB answered. Not a real credential.
  await synthetics.executeHttpStep('user-service-signin',
    request('POST', '/api/auth/signin',
      JSON.stringify({ username: 'synthetic-probe', password: 'synthetic-probe-not-a-password' })),
    expect(401));
};
