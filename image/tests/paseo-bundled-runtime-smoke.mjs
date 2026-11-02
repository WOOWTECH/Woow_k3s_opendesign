// First Paseo activation must work with NO network, NO npm and a small data volume (paas-odoo-ci#448).
// Runs INSIDE the candidate image as uid 1001 next to the real OpenDesign daemon, through the same HTTP bridge the
// setup page uses. Started by open-design/tests/paseo-bundled-runtime-offline.sh (container with --network none, a
// 256 MiB tmpfs data volume and an npm stub that records any call). No provider login, pairing or model call.
// SMOKE_LOCAL / SMOKE_HOST_ROOT / SMOKE_EXPECT_BUNDLED / SMOKE_BUNDLED_PLUGIN exist only so the same file can be rehearsed outside an image.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const local = process.env.SMOKE_LOCAL === '1';
const host = process.env.SMOKE_HOST_ROOT || '/opt/opendesign-paseo';
const bundled = process.env.SMOKE_EXPECT_BUNDLED || `${host}/managed-runtime`;
const {createStandaloneApp, standaloneConfig} = await import(`${host}/host/standalone.mjs`);
const {runtimeReady, runtimeDirectory, RUNTIME_REVISION} = await import(`${host}/vendor/pi-paseo/src/runtime-layout.mjs`);

if (!local) assert.equal(process.getuid(), 1001);
const dataDir = process.env.OD_DATA_DIR;
assert.ok(dataDir && path.isAbsolute(dataDir), 'OD_DATA_DIR');

// 1. The image ships the runtime next to the host package; it is the very lock/revision that package verifies; it is immutable.
assert.equal(runtimeReady({runtimeDir: bundled}), true, 'baked runtime must be ready for the lock the host package ships');
assert.throws(() => fs.accessSync(bundled, fs.constants.W_OK), {code: 'EACCES'}, 'baked runtime must not be writable by the runtime user');
// 2. The sandbox really is offline (a missing --network none would turn this test into a false pass).
await assert.rejects(fetch('https://registry.npmjs.org/', {signal: AbortSignal.timeout(8000)}), 'the container must have no network');
// 3. A fresh volume: nothing of Paseo exists yet.
assert.equal(fs.existsSync(path.join(dataDir, 'paseo/packages')), false, 'fresh data volume expected');

const treeBytes = directory => fs.readdirSync(directory, {withFileTypes: true}).reduce((sum, entry) => {
  const file = path.join(directory, entry.name);
  return sum + (entry.isDirectory() ? treeBytes(file) : fs.lstatSync(file).blocks * 512);
}, 0);
const origin = 'https://paseo-offline.example.invalid';
const config = standaloneConfig({
  ...process.env, OPENDESIGN_PASEO_ORIGIN: origin, OPENDESIGN_PASEO_DATA_DIR: dataDir,
  OPENDESIGN_PASEO_BUNDLED_PLUGIN: process.env.SMOKE_BUNDLED_PLUGIN || '/app/plugins/_official/woow/woow-paseo', OPENDESIGN_PASEO_AUTO_ENABLE: '0',
});
const {app, bridge} = createStandaloneApp(config);
const server = app.listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
const url = `http://127.0.0.1:${server.address().port}/api/paseo-bridge`;
const call = async (method, body) => {
  const response = await fetch(url, {method, headers: {Origin: origin, 'Content-Type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)}), signal: AbortSignal.timeout(20000)});
  return {status: response.status, body: await response.json()};
};
const until = async (label, ready, limitMs) => {
  const started = Date.now();
  for (;;) {
    const {body} = await call('GET');
    if (body.operation?.status === 'error') assert.fail(`${label} failed: ${body.operation.code}`);
    if (ready(body)) return {body, seconds: (Date.now() - started) / 1000};
    assert.ok(Date.now() - started < limitMs, `${label}: still ${body.phase}/${body.operation?.status} after ${limitMs / 1000} s`);
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
};
try {
  await bridge.start();
  assert.equal((await call('POST', {action: 'enable'})).status, 202);
  const {body: status, seconds} = await until('enable', body => body.operation?.status === 'completed' && body.phase === 'running', 180000);

  // 4. Running, from the baked runtime, without having installed or downloaded anything.
  assert.equal(status.installed, true);
  assert.equal(status.version, '0.11.2');
  assert.equal(status.daemon.owned, true);
  assert.equal(status.daemon.reachable, true);
  const state = JSON.parse(fs.readFileSync(path.join(dataDir, 'paseo/state.json'), 'utf8'));
  assert.equal(state.installedRuntimeRevision, RUNTIME_REVISION);
  assert.equal(fs.existsSync(path.join(dataDir, 'paseo/packages/runtime')), false, 'no runtime on the data volume');
  assert.equal(fs.existsSync(path.join(dataDir, 'paseo/packages/npm-cache')), false, 'npm never ran (no cache on the data volume)');
  assert.ok(runtimeDirectory({runtimeDir: bundled}).endsWith(RUNTIME_REVISION));
  assert.ok(Number.isInteger(state.daemonPid) && state.daemonPid > 1, 'daemon pid recorded');
  const environ = fs.readFileSync(`/proc/${state.daemonPid}/environ`, 'utf8').split('\0');
  assert.ok(environ.includes(`PI_PASEO_RUNTIME_DIR=${bundled}`), 'daemon must run from the baked runtime');
  assert.ok(environ.includes(`PI_PASEO_RUNTIME_REVISION=${RUNTIME_REVISION}`));
  // First start must not pull ~0.7 GiB of local speech models from github.com.
  const features = JSON.parse(fs.readFileSync(path.join(dataDir, 'paseo/daemon/config.json'), 'utf8')).features;
  assert.equal(features.dictation.enabled, false);
  assert.equal(features.voiceMode.enabled, false);
  // Capacity contract: everything Paseo wrote on the data volume is small (the old on-volume install alone was ~0.8 GB).
  const used = treeBytes(path.join(dataDir, 'paseo'));
  assert.ok(used < 32 * 1024 * 1024, `first activation wrote ${(used / 1048576).toFixed(1)} MiB under the data volume's paseo/`);

  // 5. Stop persists and leaves nothing behind.
  assert.equal((await call('POST', {action: 'disable'})).status, 202);
  await until('disable', body => body.operation?.status === 'completed' && body.phase === 'disabled', 60000);
  console.log(`Paseo bundled runtime smoke passed: ${RUNTIME_REVISION} running ${seconds.toFixed(1)} s after enable with no network and no npm; ${(used / 1048576).toFixed(1)} MiB written under the data volume.`);
} finally {
  await bridge.shutdown().catch(() => {});
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
