// BYOK runtime provenance: opencode-ai@1.18.29 exactly, on PATH, verified as
// UID 1001 at build time, and Pi fenced out at every layer the HA add-on fences
// it. Pi (@earendil-works/pi-coding-agent) was deliberately removed there; it
// must not creep back in through the k3s port.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { REPO_ROOT, mustExist } from './lib/repo-layout.mjs';

const at = (relative) => path.join(REPO_ROOT, relative);
const read = async (relative, label) => readFile(await mustExist(at(relative), label), 'utf8');

const dockerfile = await read('Dockerfile', 'the Dockerfile has not been staged');
const smoke = await read('tests/container-smoke.sh', 'tests/container-smoke.sh is missing');
const workflow = await read('.github/workflows/build.yml', 'the CI workflow has not been staged');
const provenance = await read('runtime/opencode/README.md', 'runtime/opencode/README.md must be ported with the lockfiles');

test('native OpenCode runtime is locked, on PATH, and verified without Pi', () => {
  assert.match(dockerfile, /npm ci --omit=dev --prefix \/opt\/woow-opendesign\/opencode/);
  assert.match(dockerfile, /PATH=\/opt\/woow-opendesign\/opencode\/node_modules\/\.bin:\$\{PATH\}/);
  assert.match(dockerfile, /su-exec open-design:open-design opencode --version\)" = "1\.18\.29"/);
  assert.doesNotMatch(dockerfile, /runtime\/pi|ha-pi-wrapper|ha-byok-(?:store|profiles)/);
  assert.match(provenance, /MIT licensed/);
});

test('the container smoke keeps the Pi fence and the exact version assertion', () => {
  assert.match(smoke, /test "\$\(opencode --version\)" = 1\.18\.29/);
  assert.match(smoke, /! command -v pi\b/, 'the smoke must prove Pi cannot be selected as a local fallback');
  assert.match(smoke, /ha-pi-wrapper\.mjs/, 'the smoke must prove the withdrawn Pi wrapper is absent');
});

test('CI re-verifies OpenCode as UID 1001 on the release image', () => {
  assert.match(workflow, /Verify locked OpenCode runtime as UID 1001/);
  assert.match(workflow, /linux\/amd64/);
  assert.doesNotMatch(workflow, /linux\/arm64/, 'every woow-k3s node is amd64; the arm64 leg is dropped');
});

test('nginx is not built into the application image', () => {
  assert.doesNotMatch(
    dockerfile.replace(/^\s*#.*$/gm, ''),
    /(?:apk add[^\n]*\s|\s)nginx(?:\s|$)/,
    'nginx runs as a sidecar container on k3s, not inside the OD image',
  );
});
