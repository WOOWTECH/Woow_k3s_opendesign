// Run on a fresh candidate container, as uid 1001, before any GUI login.
// No account, engine download or model call is needed.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ensureOmnigentDependencies, runDependencyCommand } from '/app/apps/daemon/dist/integrations/omnigent/dependencies.js';
import { OmnigentIntegrationService } from '/app/apps/daemon/dist/integrations/omnigent/service.js';

assert.equal(process.getuid(), 1001);
for (const key of ['OMNIGENT_CONFIG_HOME', 'OMNIGENT_DATA_DIR', 'OG_CONFIG_HOME', 'OG_DATA_DIR', 'OG_STATE_DIR']) {
  assert.equal(process.env[key], undefined, `legacy override: ${key}`);
}
const base = process.env.OD_SMOKE_URL ?? 'http://127.0.0.1:7457';
const response = await fetch(`${base}/api/integrations/omnigent/status`, { signal: AbortSignal.timeout(30000) });
assert.equal(response.status, 200);
assert.equal(response.headers.get('cache-control'), 'no-store');
const status = await response.json();
assert.equal(status.installed, true);
assert.equal(status.installationSource, 'bundled');
assert.equal(status.enabled, true);
assert.equal(status.phase, 'needs-login');
assert.equal(status.server, null);
assert.equal(status.loginConfirmed, false);
assert.equal(status.host.connected, false);
assert.deepEqual(status.verification, {});
assert.deepEqual([...status.installedEngines].sort(), ['claude', 'codex', 'opencode', 'pi']);
const missingLogin = await fetch(`${base}/api/integrations/omnigent/actions`, {
  method: 'POST', signal: AbortSignal.timeout(15000), headers: { 'content-type': 'application/json', origin: base },
  body: JSON.stringify({ action: 'setup' }),
});
assert.equal(missingLogin.status, 400);
assert.equal((await missingLogin.json()).error.code, 'INVALID_CREDENTIALS');

const dataDir = await mkdtemp(path.join(tmpdir(), 'od-omnigent-contract-'));
try {
  const stateDir = path.join(dataDir, 'integrations/omnigent');
  const commands = [];
  const deps = await ensureOmnigentDependencies({ stateDir, run: async (command, args, options) => {
    commands.push([command, args]);
    assert.equal(command, '/opt/omnigent/venv/bin/python', 'must reuse image SDK; installation forbidden');
    assert.deepEqual(args.slice(0, 3), ['-I', '-B', '-c']);
    return runDependencyCommand(command, args, options);
  } });
  assert.equal(deps.python, '/opt/omnigent/venv/bin/python');
  assert.ok(commands.length >= 2, 'SDK and patch probes must execute');
  await assert.rejects(stat(path.join(stateDir, 'deps')), { code: 'ENOENT' });
  // Observe the compiled service boundary: no global legacy config home may win.
  let input;
  const service = new OmnigentIntegrationService({ dataDir, env: process.env,
    getPlugin: async () => ({ id: 'woow-omnigent', installedAt: 1, sourceKind: 'bundled' }),
    createOnboarding: async () => { throw new Error('read-only status must not onboard'); },
    adapter: async request => { input = request; return { ok: true, data: {} }; },
  });
  await service.status('local', true);
  assert.equal(input.configHome, path.join(stateDir, 'host'));
  assert.equal(input.dataDir, path.join(stateDir, 'host'));
  assert.equal(input.localOnly, true);
  assert.equal(input.allowManagedHost, undefined);
  assert.equal(input.server, undefined);
  assert.equal(input.username, undefined);
  assert.equal(input.password, undefined);
} finally { await rm(dataDir, { recursive: true, force: true }); }

// Fresh boot must not run the legacy launcher or a native host before login.
for (const pid of (await readdir('/proc')).filter(name => /^\d+$/.test(name))) {
  let argv;
  try { argv = (await readFile(`/proc/${pid}/cmdline`, 'utf8')).split('\0').filter(Boolean); }
  catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') continue; throw error; }
  assert.ok(!argv.some(arg => /(?:omnigent-host-entry|omnigent-host-launch|host-kit\/supervisor\.sh)$/.test(arg)), `premature host manager: ${pid}`);
  assert.ok(!(argv.some(arg => /(?:^|\/)omnigent$/.test(arg)) && argv.includes('host')), `premature host: ${pid}`);
}
console.log('native Omnigent smoke OK: GUI needs login, private state, bundled patched SDK reused, no host before setup');
