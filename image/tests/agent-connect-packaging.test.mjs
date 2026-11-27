import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const dockerfile = fs.readFileSync(new URL('../Dockerfile', import.meta.url), 'utf8');
const preparer = fs.readFileSync(new URL('../paseo-runtime/scripts/prepare-managed-runtime.mjs', import.meta.url), 'utf8');
const packageManifest = JSON.parse(fs.readFileSync(new URL('../paseo-runtime/package.json', import.meta.url), 'utf8'));
const launcherManifest = JSON.parse(fs.readFileSync(new URL('../paseo-runtime/launcher/open-design.json', import.meta.url), 'utf8'));

test('PaaS image uses the candidate-owned musl PTY gate', () => {
  for (const fragment of [
    '.agent-connect-build build-base',
    'python3',
    'node scripts/prepare-managed-runtime.mjs /opt/opendesign-paseo/managed-runtime',
    'apk del .agent-connect-build',
  ]) assert.ok(dockerfile.includes(fragment), fragment);
  assert.doesNotMatch(dockerfile, /markRuntimeReady\(loc\)/);
  assert.match(preparer, /\['ci', '--prefix', root, '--omit=dev', '--ignore-scripts'/);
  assert.match(preparer, /\['rebuild', '--prefix', root, 'node-pty', '--ignore-scripts=false'/);
  assert.match(preparer, /npm_config_build_from_source: 'true'/);
  assert.match(preparer, /pty\.spawn\('\/bin\/sh'/);
  assert.ok(preparer.indexOf("['ci'") < preparer.indexOf("['rebuild'"));
  assert.ok(preparer.indexOf("['rebuild'") < preparer.indexOf('pty.spawn'));
  assert.ok(preparer.indexOf('pty.spawn') < preparer.indexOf('markRuntimeReady(loc)'));
});

test('Agent Connect launcher metadata invalidates the prior manifest version', () => {
  assert.equal(launcherManifest.title, 'Agent Connect');
  assert.equal(launcherManifest.version, packageManifest.version);
});
