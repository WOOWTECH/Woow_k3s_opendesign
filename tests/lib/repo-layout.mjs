// Shared layout resolution for the node:test lanes. Mirrors lib/repolayout.py.
//
// A missing input must be LOUD. Every helper here throws with an explicit
// banner naming the path it wanted and the env var that overrides it, so a
// component that has not been staged yet fails the file instead of silently
// skipping its assertions.
import { access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const REPO_ROOT = path.resolve(process.env.REPO_ROOT || path.join(here, '..', '..'));
export const OPT_DIR = path.resolve(REPO_ROOT, process.env.OPT_DIR || 'rootfs/opt/woow-opendesign');
export const LAUNCHER = path.resolve(REPO_ROOT, process.env.LAUNCHER || 'rootfs/usr/local/bin/k3s-opendesign');
export const ARTIFACTS = path.join(REPO_ROOT, 'tests', '.artifacts');

function banner(label, target, hint) {
  return [
    '',
    '='.repeat(72),
    `MISSING INPUT — ${label}`,
    '='.repeat(72),
    `wanted   : ${target}`,
    `repo root: ${REPO_ROOT}`,
    `opt dir  : ${OPT_DIR}`,
    hint ? `hint     : ${hint}` : '',
    'This is NOT a pass. The component that produces this file has not been',
    'staged, or the repository layout differs from the default.',
    '',
  ].filter(Boolean).join('\n');
}

export async function mustExist(target, label, hint) {
  try {
    await access(target);
  } catch {
    throw new Error(banner(label, target, hint));
  }
  return target;
}

/** Path of a file inside rootfs/opt/woow-opendesign. */
export function optPath(name) {
  return path.join(OPT_DIR, name);
}

/** Import a runtime module from rootfs/opt, failing loudly when it is absent. */
export async function importOpt(name, label) {
  const target = optPath(name);
  await mustExist(target, label || `${name} has not been ported yet`, 'override with OPT_DIR=');
  return import(pathToFileURL(target).href);
}

/** Path of a chart asset extracted by tests/lib/extract-chart-assets.py. */
export function artifactPath(name) {
  return path.join(ARTIFACTS, name);
}

export async function mustHaveArtifact(name) {
  return mustExist(
    artifactPath(name),
    `chart asset ${name} has not been extracted`,
    'run: python3 tests/lib/extract-chart-assets.py',
  );
}
