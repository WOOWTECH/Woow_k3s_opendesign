// Guards on the container lane's own wiring. These are cheap static checks that
// keep the expensive podman lane honest: they caught real regressions in the HA
// suite (a browser smoke run from /tmp could not resolve playwright-core, and a
// BYOK harness that wrote its key would have made the leak assertions vacuous).
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { REPO_ROOT, mustExist } from './lib/repo-layout.mjs';

const read = async (relative, label) => readFile(await mustExist(path.join(REPO_ROOT, relative), label), 'utf8');

const smoke = await read('tests/container-smoke.sh', 'tests/container-smoke.sh is missing');
const harness = await read('tests/container-opencode-byok-e2e.mjs', 'the BYOK harness is missing');
const proxy = await read('tests/container-proxy-e2e.mjs', 'tests/container-proxy-e2e.mjs is missing');

test('the smoke exercises the real two-container topology, not a single container', () => {
  assert.match(smoke, /\bpod create\b/, 'the pod is the unit under test: OD + nginx sharing a netns');
  assert.match(smoke, /nginx:1\.27-alpine/, 'the sidecar image must match the chart');
  assert.match(smoke, /:7457/, 'only the sidecar port may be published');
  assert.match(
    smoke,
    /od-export-bridge\.js:\/usr\/share\/nginx\/od-export-bridge\.js/,
    'the sidecar must serve the export bridge from the ConfigMap path the chart mounts',
  );
});

test('the smoke proves the daemon port is not reachable from outside the pod', () => {
  assert.match(smoke, /7456/, 'the smoke must reference the loopback daemon port');
  assert.match(
    smoke,
    /daemon port .* not .* reachable|must not be reachable from outside the pod/i,
    'there must be an explicit negative assertion for the daemon socket',
  );
});

test('the renderer assertions that actually caught bugs are still present', () => {
  assert.match(smoke, /pdfinfo/, 'PDF page count');
  assert.match(smoke, /ppt\/slides\/slide/, 'PPTX slide count');
  assert.match(smoke, /png_pixels|def png_pixels/, 'per-pixel PNG decode');
  assert.match(smoke, /Editable PPTX is unsupported/, 'editable-PPTX rejection');
});

test('native byok-opencode harness uses a streaming mock and the browser request shape', () => {
  assert.match(harness, /const FAKE_API_KEY = 'od-byok-test-key-not-a-secret'/);
  assert.match(harness, /agentId: 'byok-opencode'/);
  assert.match(harness, /sessionMode: 'chat'/);
  assert.match(harness, /protocol: 'openai'/);
  assert.match(harness, /apiKey: FAKE_API_KEY/);
  assert.match(harness, /parsedBody\?\.stream === true/);
  assert.match(harness, /content-type': 'text\/event-stream; charset=utf-8'/);
  assert.match(harness, /data: \[DONE\]/);
  assert.match(harness, /request\.authorization === `Bearer \$\{FAKE_API_KEY\}`/);
  assert.match(harness, /7456/, 'the harness must talk to the loopback daemon, not the HA ingress port');
});

test('container smoke rejects BYOK key leakage to logs and to /data', () => {
  assert.match(smoke, /container-opencode-byok-e2e\.mjs/);
  assert.match(smoke, /fake BYOK key leaked to container logs/);
  assert.match(smoke, /fake BYOK key leaked to \/data persisted artifacts/);
  assert.match(smoke, /grep -R -I -F -q -- "\$1" \/data/);
});

test('the proxy e2e replaces the HA ingress browser e2e with NPM-shaped assertions', () => {
  assert.match(proxy, /od-export-bridge\.js/, 'the injected bridge must be served and referenced');
  assert.match(proxy, /href="\/settings"/, 'an unrewritten upstream body is the regression guard');
  // The script names the HA headers only inside its own negative assertions;
  // what must not exist is a request that SETS one.
  assert.doesNotMatch(proxy, /(?:set|headers)\s*[(:][^\n]*['"]?[Xx]-[Ii]ngress-[Pp]ath/, 'the proxy e2e must never send an ingress header');
  assert.match(proxy, /proxy injected HA ingress machinery/, 'the body must be asserted free of HA ingress machinery');
  assert.match(proxy, /evil\.test/, 'a cross-site Origin must be rejected');
  assert.match(proxy, /403/, 'both deny paths assert 403');
});
