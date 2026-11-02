// Fast, Docker-free check of how the vendored host package (../paseo-runtime) picks its managed Paseo runtime (#448).
// The container proof is paseo-bundled-runtime-offline.sh; this one runs in lint.yml on every PR.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { runtimeContext } from '../paseo-runtime/src/runtime-context.mjs';
import { prepareRuntimeManifest, markRuntimeReady, runtimeReady, runtimeDirectory } from '../paseo-runtime/vendor/pi-paseo/src/runtime-layout.mjs';

function tenant(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'od-bundled-')), home = path.join(root, 'home'), dataDir = path.join(root, 'data');
  const packageRoot = path.join(root, 'opt/opendesign-paseo');
  fs.mkdirSync(home); fs.mkdirSync(dataDir); fs.mkdirSync(path.join(packageRoot, 'src'), { recursive: true });
  fs.writeFileSync(path.join(packageRoot, 'src/runtime-worker.mjs'), '');
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return { home, dataDir, packageRoot };
}
function bake(directory) {
  const loc = { runtimeDir: directory };
  const release = prepareRuntimeManifest(loc);
  fs.mkdirSync(path.join(release, 'node_modules/@getpaseo/cli'), { recursive: true });
  fs.writeFileSync(path.join(release, 'node_modules/@getpaseo/cli/package.json'), JSON.stringify({ name: '@getpaseo/cli', version: '0.11.2' }));
  markRuntimeReady(loc);
  assert.equal(runtimeReady(loc), true);
  return loc;
}
const context = fixture => runtimeContext({ home: fixture.home, dataDir: fixture.dataDir, packageRoot: fixture.packageRoot, env: { PATH: process.env.PATH } });
const volumeRuntime = fixture => path.join(fixture.dataDir, 'paseo/packages/runtime');

test('a ready managed runtime next to the package is used in place; the tenant volume gets none', t => {
  const fixture = tenant(t), bundled = path.join(fixture.packageRoot, 'managed-runtime');
  const loc = bake(bundled);
  const value = context(fixture);
  assert.equal(value.env.PI_PASEO_RUNTIME_DIR, bundled);
  assert.ok(runtimeDirectory(loc).startsWith(bundled));
  assert.equal(fs.existsSync(volumeRuntime(fixture)), false);
});

test('supervisor, workers and the stdio MCP server derive the same runtime from the package root they receive', t => {
  const fixture = tenant(t);
  bake(path.join(fixture.packageRoot, 'managed-runtime'));
  const parent = context(fixture);
  const child = runtimeContext({ home: fixture.home, dataDir: fixture.dataDir, packageRoot: parent.env.OPENDESIGN_PASEO_PACKAGE_ROOT, env: parent.env });
  assert.equal(child.env.PI_PASEO_RUNTIME_DIR, parent.env.PI_PASEO_RUNTIME_DIR);
});

test('without a ready managed runtime the old volume install is the fallback (and a stale receipt does not count)', t => {
  const fixture = tenant(t), bundled = path.join(fixture.packageRoot, 'managed-runtime');
  assert.equal(context(fixture).env.PI_PASEO_RUNTIME_DIR, volumeRuntime(fixture));
  const loc = bake(bundled);
  fs.writeFileSync(path.join(runtimeDirectory(loc), '.pi-paseo-runtime.json'), JSON.stringify({ lockSha256: '0'.repeat(64), revision: 'stale' }));
  assert.equal(context(fixture).env.PI_PASEO_RUNTIME_DIR, volumeRuntime(fixture));
});
