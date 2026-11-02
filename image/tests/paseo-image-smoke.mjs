import assert from 'node:assert/strict';
import {createStandaloneApp, standaloneConfig} from '/opt/opendesign-paseo/host/standalone.mjs';

assert.equal(process.getuid(), 1001);
const origin = 'https://paseo-ci.example.invalid';
const config = standaloneConfig({
  ...process.env,
  OPENDESIGN_PASEO_ORIGIN: origin,
  OPENDESIGN_PASEO_DATA_DIR: process.env.OD_DATA_DIR,
  OPENDESIGN_PASEO_BUNDLED_PLUGIN: '/app/plugins/_official/woow/woow-paseo',
  OPENDESIGN_PASEO_AUTO_ENABLE: '0',
});
const native = async (method, route, body) => {
  const response = await fetch(`http://127.0.0.1:7457${route}`, {
    method, headers: {'Content-Type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)}),
    signal: AbortSignal.timeout(15000),
  });
  assert.equal(response.status, 200, `${method} ${route}`);
  return response.json();
};
assert.match(JSON.stringify(await native('GET', '/api/plugins')), /woow-paseo/);
const peer = {id: 'paseo-ci-peer', transport: 'stdio', enabled: false, command: '/bin/true'};
const savedPeer = (await native('PUT', '/api/mcp/servers/paseo-ci-peer', {server: peer, expected: null})).server;
const {app, bridge} = createStandaloneApp(config);
const server = app.listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
try {
  await bridge.start();
  const url = `http://127.0.0.1:${server.address().port}`;
  const setup = await fetch(`${url}/paseo/setup/`);
  assert.equal(setup.status, 200);
  assert.match(await setup.text(), /Paseo/);
  const denied = await fetch(`${url}/api/paseo-bridge`, {
    method: 'POST', headers: {Origin: 'https://untrusted.example.invalid', 'Content-Type': 'application/json'},
    body: JSON.stringify({action: 'status'}),
  });
  assert.equal(denied.status, 403);
  const status = await fetch(`${url}/api/paseo-bridge`, {headers: {Origin: origin}});
  assert.equal(status.status, 200);
  assert.equal((await status.json()).pluginInstalled, true);
  const mcp = await native('GET', '/api/mcp/servers');
  assert.deepEqual(mcp.servers.find(entry => entry.id === peer.id), savedPeer);
  const own = mcp.servers.filter(entry => entry.id === 'woow-paseo');
  assert.equal(own.length, 1);
  assert.ok(own[0].args.includes('/opt/opendesign-paseo/bin/mcp.mjs'));
  console.log('Paseo image smoke passed: native card, real atomic MCP registration, peer preservation, setup page and cross-origin rejection. No provider calls.');
} finally {
  await bridge.shutdown();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
