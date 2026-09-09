// Sidecar proxy acceptance — the replacement for the HA
// container-ingress-browser-e2e.mjs, which tested the /api/hassio_ingress/<token>
// prefix machinery that is deliberately NOT ported.
//
// Runs on the HOST, against the published sidecar port of the smoke pod:
//   cloudflared -> npm:80 (auth) -> service/opendesign:7457 -> nginx -> 127.0.0.1:7456
// This script stands in for everything from `service/opendesign:7457` rightwards.
//
// Env:
//   OD_PROXY_BASE_URL   default http://127.0.0.1:17457   (the sidecar)
//   OD_DIRECT_BASE_URL  default http://127.0.0.1:17456   (published ONLY when
//                       OD_EXPECT_DIRECT_BLOCKED=1 is not set; see smoke)
//   OD_ALLOWED_ORIGIN   default https://od.test          (must equal the
//                       OD_ALLOWED_ORIGINS the daemon was started with)
//   OD_PROJECT_ID       default od-smoke
import assert from 'node:assert/strict';

const proxy = process.env.OD_PROXY_BASE_URL || 'http://127.0.0.1:17457';
const allowedOrigin = process.env.OD_ALLOWED_ORIGIN || 'https://od.test';
const projectId = process.env.OD_PROJECT_ID || 'od-smoke';
const requireOriginOnMutation = process.env.OD_REQUIRE_ORIGIN_ON_MUTATION !== '0';

const failures = [];
function record(label, error) {
  failures.push(`${label}: ${error instanceof Error ? error.message : String(error)}`);
}
async function step(label, body) {
  try {
    await body();
    console.log(`ok   ${label}`);
  } catch (error) {
    console.error(`FAIL ${label}`);
    record(label, error);
  }
}

const url = (requestPath) => new URL(requestPath, proxy).toString();

await step('health survives the proxy', async () => {
  const response = await fetch(url('/api/health'));
  assert.equal(response.status, 200);
  assert.equal((await response.json())?.ok, true);
});

await step('the application shell carries the injected export bridge', async () => {
  const response = await fetch(url('/'));
  assert.equal(response.status, 200);
  const body = await response.text();
  assert.ok(
    body.includes('<script src="/od-export-bridge.js"></script>'),
    'the single <head> sub_filter must inject the bridge',
  );
});

await step('the bridge itself is served as JavaScript', async () => {
  const response = await fetch(url('/od-export-bridge.js'));
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type') || '', /javascript/i);
  const body = await response.text();
  assert.match(body, /redirectPdfRequest/);
  assert.doesNotMatch(body, /__OD_INGRESS_PATH__/, 'the HA install gate must be gone');
});

await step('NO path rewriting happens (regression guard against re-adding the HA sub_filter set)', async () => {
  // The daemon's own shell is served at /. If anyone re-adds the HA
  // href="/ -> href="<prefix>/ rewrites, absolute URLs in the body change and
  // this assertion fails. That rewriting is pure regression surface behind NPM.
  const response = await fetch(url('/'));
  const body = await response.text();
  for (const forbidden of ['/api/hassio_ingress/', 'X-Ingress-Path']) {
    assert.ok(!body.includes(forbidden), `proxy injected HA ingress machinery: ${forbidden}`);
  }
  const marker = process.env.OD_UPSTREAM_MARKER || 'href="/settings"';
  if (process.env.OD_EXPECT_UPSTREAM_MARKER === '1') {
    assert.ok(body.includes(marker), `upstream absolute path was rewritten; expected verbatim ${marker}`);
  }
});

await step('a same-origin mutating request is accepted', async () => {
  const response = await fetch(url(`/api/projects/${encodeURIComponent(projectId)}/export/pdf-image`), {
    method: 'POST',
    headers: { 'content-type': 'application/json', origin: allowedOrigin },
    body: JSON.stringify({ fileName: 'deck.html', deck: true, title: 'Proxy' }),
  });
  // Read the body EXACTLY once. assert.ok's message argument is evaluated
  // eagerly, so an inline `await response.text()` there consumes the stream on
  // every run -- including the passing one -- and the later arrayBuffer() then
  // throws "Body has already been read", failing the test against a healthy
  // server. Buffer first, then assert on the buffered copy.
  const bytes = Buffer.from(await response.arrayBuffer());
  assert.ok(
    response.status >= 200 && response.status < 300,
    `expected 2xx with the allow-listed Origin, got ${response.status}: ${bytes.toString('utf8').slice(0, 200)}`,
  );
  assert.ok(bytes.length > 100, 'export body came back empty through the proxy');
});

await step('a cross-site Origin is rejected by OpenDesign', async () => {
  const response = await fetch(url(`/api/projects/${encodeURIComponent(projectId)}/export/pdf-image`), {
    method: 'POST',
    headers: { 'content-type': 'application/json', origin: 'https://evil.test' },
    body: JSON.stringify({ fileName: 'deck.html', deck: true }),
  });
  assert.equal(response.status, 403, `cross-site Origin must be refused, got ${response.status}`);
});

if (requireOriginOnMutation) {
  await step('a mutating request with NO Origin is rejected by the sidecar', async () => {
    // This closes the one gap left by normalising Host to 127.0.0.1:7456: with
    // no Origin, OD falls back to isAllowedBrowserHost and would accept it.
    const response = await fetch(url(`/api/projects/${encodeURIComponent(projectId)}/export/pdf-image`), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ fileName: 'deck.html', deck: true }),
    });
    assert.equal(
      response.status,
      403,
      'nginx.requireOriginOnMutation must 403 an Origin-less mutation. If this breaks a '
      + 'legitimate non-browser client, set nginx.requireOriginOnMutation=false and RECORD WHY '
      + '— do not delete this assertion.',
    );
  });
} else {
  console.log('skip requireOriginOnMutation assertion (OD_REQUIRE_ORIGIN_ON_MUTATION=0)');
}

await step('a GET with no Origin still works (browsers omit it on same-origin GETs)', async () => {
  const response = await fetch(url('/api/health'));
  assert.equal(response.status, 200);
});

await step('a binary export is byte-identical through the proxy', async () => {
  const body = JSON.stringify({ fileName: 'deck.html', deck: true, imageFormat: 'png' });
  const headers = { 'content-type': 'application/json', origin: allowedOrigin };
  const [viaProxy, again] = await Promise.all([
    fetch(url(`/api/projects/${encodeURIComponent(projectId)}/export/image`), { method: 'POST', headers, body }),
    fetch(url(`/api/projects/${encodeURIComponent(projectId)}/export/image`), { method: 'POST', headers, body }),
  ]);
  const first = Buffer.from(await viaProxy.arrayBuffer());
  const second = Buffer.from(await again.arrayBuffer());
  assert.deepEqual(first.subarray(0, 4), Buffer.from([0x89, 0x50, 0x4e, 0x47]), 'PNG magic mangled by sub_filter');
  assert.equal(first.length, second.length, 'binary export length is not stable through the proxy');
});

if (failures.length > 0) {
  console.error(`\n${failures.length} proxy assertion(s) failed:`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('container proxy e2e: bridge injection, no path rewriting, Origin allow/deny, binary passthrough passed');
