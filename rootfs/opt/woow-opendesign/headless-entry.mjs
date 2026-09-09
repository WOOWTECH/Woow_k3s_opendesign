#!/usr/bin/env node
import { renderSlides } from './headless-renderer.mjs';

const host = '127.0.0.1';
const port = 7456;
// OpenDesign 0.21.1's startServer().shutdown() resolves immediately without
// closing the HTTP server and leaves child processes and timers on the event
// loop, so Node never exits on its own. Verified in the pinned base image:
// `shutdown() resolved in 1 ms; server.listening = true` with three live
// ProcessWrap handles still attached. The Home Assistant add-on hid this behind
// its launcher's 5s TERM-to-KILL grace timer; with one process per container
// that bound has to live here, or every pod deletion burns the whole
// terminationGracePeriodSeconds and ends in SIGKILL (exit 137).
const SHUTDOWN_GRACE_MS = 10_000;
let started;
let stopping = false;

async function stop(signal) {
  if (stopping) return;
  stopping = true;
  console.info(`[woow-opendesign] ${signal} received; stopping OpenDesign`);
  // Unref'd: it never keeps a drained event loop alive, but it still fires if
  // something else is holding the loop open past the grace window.
  const forced = setTimeout(() => {
    console.warn(`[woow-opendesign] shutdown exceeded ${SHUTDOWN_GRACE_MS}ms; exiting`);
    process.exit(typeof process.exitCode === 'number' ? process.exitCode : 0);
  }, SHUTDOWN_GRACE_MS);
  forced.unref?.();
  try {
    await started?.shutdown?.();
    await new Promise((resolve) => {
      const server = started?.server;
      if (!server || !server.listening) {
        resolve();
        return;
      }
      server.close(() => resolve());
      server.closeAllConnections?.();
    });
  } catch (error) {
    console.error('[woow-opendesign] shutdown error', error);
  }
}

try {
  const { startServer } = await import('/app/apps/daemon/dist/server.js');
  started = await startServer({
    host,
    port,
    returnServer: true,
    desktopSlideRenderer: renderSlides,
    desktopArtifactExporter: null,
  });
  console.info(`[woow-opendesign] OpenDesign ${started.url} with Playwright export renderer`);

  process.once('SIGTERM', () => void stop('SIGTERM'));
  process.once('SIGINT', () => void stop('SIGINT'));
  await new Promise((resolve, reject) => {
    started.server.once('close', resolve);
    started.server.once('error', reject);
  });
} catch (error) {
  console.error('[woow-opendesign] failed to start', error);
  process.exitCode = 1;
} finally {
  await stop('exit');
}
