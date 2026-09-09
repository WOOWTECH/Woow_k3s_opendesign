// Launcher acceptance for the k3s port.
//
// The HA launcher supervised two processes (OpenDesign + nginx) behind a
// TERM/KILL watchdog. On Kubernetes nginx is a separate container and one
// process per container is the contract, so the watchdog is deliberately gone
// and tini + the kubelet deliver signals directly. What must survive is the
// privileged /data preparation: this pod starts as root purely to chown a
// root-owned Longhorn mount, and that code must fail closed on symlinks.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { LAUNCHER, mustExist } from './lib/repo-layout.mjs';

await mustExist(
  LAUNCHER,
  'the k3s launcher (rootfs/usr/local/bin/k3s-opendesign) has not been staged',
  'override with LAUNCHER=',
);
const launcher = await readFile(LAUNCHER, 'utf8');

function extract(startNeedle, endNeedle) {
  const start = launcher.indexOf(startNeedle);
  assert.ok(start >= 0, `launcher is missing ${startNeedle}`);
  const end = launcher.indexOf(endNeedle, start);
  assert.ok(end > start, `launcher is missing the terminator after ${startNeedle}`);
  return launcher.slice(start, end + 2);
}

test('launcher runs exactly one process and hands signals to the runtime', () => {
  assert.match(
    launcher,
    /^exec su-exec open-design:open-design \S*node \/opt\/woow-opendesign\/headless-entry\.mjs/m,
    'the launcher must exec the daemon so tini/Kubernetes signal it directly',
  );
  for (const forbidden of [/wait -n/, /nginx_pid/, /terminate_children/, /SHUTDOWN_GRACE_SECONDS/, /\/usr\/sbin\/nginx/]) {
    assert.doesNotMatch(launcher, forbidden, `the two-process HA watchdog must not be ported: ${forbidden}`);
  }
});

test('launcher refuses to run unprivileged', () => {
  assert.match(launcher, /exit 78/, 'the launcher must exit 78 when it is not root');
  const result = spawnSync('bash', ['-n', LAUNCHER], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('launcher exports the loopback bind and the chart-owned data dir', () => {
  assert.match(launcher, /OD_BIND_HOST=(?:"|')?127\.0\.0\.1/);
  assert.match(launcher, /OD_PORT=(?:"|')?7456/);
  assert.match(launcher, /OD_DATA_DIR/);
  assert.match(launcher, /HOME=/);
});

test('privileged directory preparation rejects symlinks without touching their target', async () => {
  const prepareOwnedDir = extract('prepare_owned_dir() {', '\n}\n');
  const root = await mkdtemp(path.join(tmpdir(), 'k3s-opendesign-launcher-'));
  const outside = path.join(root, 'outside');
  const link = path.join(root, 'runtime-link');
  await mkdir(outside, { mode: 0o711 });
  await symlink(outside, link);
  const before = await stat(outside);
  try {
    const harness = `set -Eeuo pipefail\n${prepareOwnedDir}\nprepare_owned_dir "$1"`;
    const result = spawnSync('bash', ['-c', harness, 'launcher-test', link], { encoding: 'utf8' });
    assert.equal(result.status, 78, result.stderr);
    assert.match(result.stderr, /refusing symbolic-link runtime directory/);
    const after = await stat(outside);
    assert.equal(after.uid, before.uid);
    assert.equal(after.gid, before.gid);
    assert.equal(after.mode, before.mode, 'a rejected symlink target must be left untouched');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('launcher removes obsolete credential symlinks without following them or deleting data', async () => {
  const removeCredentials = extract('remove_obsolete_credentials() {', '\n}\n');
  const root = await mkdtemp(path.join(tmpdir(), 'k3s-opendesign-credentials-'));
  const data = path.join(root, 'opendesign');
  const target = path.join(data, 'outside-credentials');
  const credentials = path.join(data, 'credentials');
  try {
    await mkdir(target, { recursive: true });
    await writeFile(path.join(target, 'sentinel'), 'retained');
    await symlink(target, credentials);
    const harness = `set -Eeuo pipefail\nDATA_DIR="$1"\n${removeCredentials}\nremove_obsolete_credentials`;
    const result = spawnSync('bash', ['-c', harness, 'launcher-test', data], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    await assert.rejects(stat(credentials), 'the obsolete credential symlink must be unlinked');
    assert.equal(await readFile(path.join(target, 'sentinel'), 'utf8'), 'retained', 'its target must survive');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('launcher tightens the persistent tree to 0750 for the runtime UID', () => {
  assert.match(launcher, /chmod 0750/, 'the data tree must not be world-readable on a shared volume');
  for (const directory of ['home', 'export-render', 'export-pdf']) {
    assert.ok(launcher.includes(directory), `launcher must prepare ${directory} under the data dir`);
  }
});
