// The one deliberate behaviour change to the ported export bridge.
//
// On HA the bridge refused to install unless window.__OD_INGRESS_PATH__ matched
// /^\/api\/hassio_ingress\/[A-Za-z0-9_-]{16,128}$/. Behind NPM the app is served
// at / on its own vhost, so that gate would keep the bridge permanently
// uninstalled and the UI's PDF button would hit the Electron-only /export/pdf
// route and fail. The gate is therefore replaced by the idempotence flag alone.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';
import { mustHaveArtifact } from './lib/repo-layout.mjs';

const require = createRequire(import.meta.url);
const bridgePath = await mustHaveArtifact('od-export-bridge.js');
const bridgeSource = await (await import('node:fs/promises')).readFile(bridgePath, 'utf8');
const bridge = require(bridgePath);

function browserRoot() {
  class Element {}
  const documentElement = Object.assign(new Element(), {
    getAttribute: () => null,
    matches: () => false,
    querySelector: () => null,
    querySelectorAll: () => [],
  });
  let fetchCalls = 0;
  const root = {
    Blob,
    Element,
    MutationObserver: class { observe() {} },
    Request,
    Response,
    URL,
    document: {
      body: { appendChild() {} },
      documentElement,
      createElement: () => ({ style: {}, click() {}, remove() {} }),
      querySelectorAll: () => [],
    },
    fetch: async () => { fetchCalls += 1; return new Response(); },
    location: { href: 'https://od-woow-k3s.woowtech.io/' },
    setTimeout(callback) { callback(); },
  };
  return { root, nativeFetch: root.fetch, fetchCalls: () => fetchCalls };
}

test('the HA ingress install gate is gone from the shipped bridge', () => {
  assert.doesNotMatch(bridgeSource, /__OD_INGRESS_PATH__/, 'the ingress prefix does not exist behind NPM');
  assert.doesNotMatch(bridgeSource, /hassio_ingress/, 'no HA ingress path machinery may be ported');
  assert.match(bridgeSource, /__OD_EXPORT_BRIDGE_INSTALLED__/, 'the idempotence flag must be kept and renamed');
});

test('bridge installs unconditionally with no ingress prefix present', () => {
  const { root, nativeFetch } = browserRoot();
  assert.equal(root.__OD_INGRESS_PATH__, undefined);
  bridge.createForRoot(root).install();
  assert.equal(root.__OD_EXPORT_BRIDGE_INSTALLED__, true, 'the bridge must install on a plain vhost');
  assert.notEqual(root.fetch, nativeFetch, 'install must wrap fetch');
});

test('bridge installs only once', () => {
  const { root } = browserRoot();
  const api = bridge.createForRoot(root);
  api.install();
  const wrapped = root.fetch;
  api.install();
  assert.equal(root.fetch, wrapped, 're-installing must not stack a second fetch wrapper');
});

test('the installed wrapper still redirects the Electron-only PDF route', async () => {
  const seen = [];
  const { root } = browserRoot();
  root.fetch = async (input) => {
    seen.push(String(input));
    return new Response(new Blob(['%PDF-k3s'], { type: 'application/pdf' }), {
      status: 200,
      headers: { 'content-disposition': 'attachment; filename="deck.pdf"' },
    });
  };
  bridge.createForRoot(root).install();
  const response = await root.fetch('/api/projects/p1/export/pdf', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ fileName: 'deck.html', deck: true }),
  });
  assert.deepEqual(await response.json(), { ok: true });
  assert.deepEqual(seen, ['/api/projects/p1/export/pdf-image']);
});
