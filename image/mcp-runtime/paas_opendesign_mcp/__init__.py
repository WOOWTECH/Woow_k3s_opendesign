"""PaaS placement of the HA add-on's built-in OpenDesign MCP runtime (chart open-design >= 0.5.0, `mcp` container).

The MCP runtime itself — the pinned Woow MCP gateway, the OpenDesign tools, the tool surface, its defaults and
protections, the admin page — is the HA add-on's (../ha/, a pinned copy of WOOWTECH/Woow_ha_opendesign_add_on
mcp-runtime, ../HA_SOURCE.json), used unchanged so both products behave the same. This package only places it in the
PaaS pod (launch.py):

* the runtime runs in its own sidecar container of the daemon pod as uid/gid 10001, started directly by Kubernetes:
  no root bootstrap and no privilege drop (bin/paas-opendesign-mcp replaces the add-on's bin/ha-opendesign-mcp);
* backend = the OpenDesign daemon of the same pod on 127.0.0.1:<service.targetPort> (add-on: 7456);
* MCP listener 127.0.0.1:<port> (add-on: 0.0.0.0:8081 on the LAN); the chart's nginx auth proxy routes /mcp (Bearer)
  and /private_<token>/mcp (Claude.ai) there without basic-auth — the gateway checks the token itself;
* admin.sock and the child socket in an emptyDir that only the authproxy and mcp containers mount (add-on:
  /run/ha-opendesign-mcp, group ha-ingress); nginx serves the admin page at /mcp-admin/ behind the tenant's basic-auth
  and sets X-Remote-User-Id to the basic-auth user (add-on: Supervisor Ingress sets it);
* state in a 0700 directory of uid 10001 on the od-data PVC (subPath), /data/mcp/state (add-on: /data/mcp);
* the admin page's client endpoint is seeded with <public origin>/mcp while unset (the add-on has no public URL).
"""
import os
from pathlib import Path
import re

UID = GID = 10001
# od-data PVC subPath mounted only into the mcp container (chart mcp.dataSubPath). The mount root is created by the
# kubelet (root:1001), so the vendored Store keeps its state one level down, in a directory it creates 0700.
DATA_ROOT = Path('/data/mcp')
DATA_DIR = DATA_ROOT / 'state'
# emptyDir mounted only by the authproxy (nginx) and mcp containers, never by the daemon container where tenant
# shells and agents run: mounting it is the access control of admin.sock (uvicorn creates it 0666).
RUN_DIR = Path('/run/od-mcp')
ADMIN_SOCKET = RUN_DIR / 'admin.sock'
# Gateway -> child: a 0700 directory of uid 10001, so nginx (same emptyDir, another uid) cannot reach the child.
CHILD_DIR = RUN_DIR / 'child'
CHILD_SOCKET = CHILD_DIR / 'child.sock'
MCP_HOST = '127.0.0.1'

DEFAULT_BACKEND = 'http://127.0.0.1:7457'
DEFAULT_PORT = 8081
_BACKEND = re.compile(r'http://127\.0\.0\.1:([0-9]{1,5})')
_ORIGIN = re.compile(r'https?://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?')


class SettingsError(ValueError):
    pass


def _port(text, name):
    if not re.fullmatch(r'[0-9]{1,5}', text) or not 1 <= int(text) <= 65535:
        raise SettingsError(name + ' must be a TCP port')
    return int(text)


def settings(environ=None):
    """The three chart-provided settings, validated. Anything else in the container environment is ignored.

    WOOW_OD_BACKEND_URL        the daemon, http://127.0.0.1:<port> only (pod loopback; default DEFAULT_BACKEND)
    WOOW_OD_MCP_PORT           the MCP listener port on 127.0.0.1 (default DEFAULT_PORT)
    WOOW_OD_MCP_PUBLIC_ORIGIN  the service's public origin (scheme://host[:port], the first entry of the chart's
                               config.allowedOrigins); seeds the admin page's client endpoint <origin>/mcp. Optional.
    """
    env = os.environ if environ is None else environ
    backend = env.get('WOOW_OD_BACKEND_URL') or DEFAULT_BACKEND
    match = _BACKEND.fullmatch(backend)
    if not match:
        raise SettingsError('WOOW_OD_BACKEND_URL must be http://127.0.0.1:<port>')
    backend_port = _port(match.group(1), 'WOOW_OD_BACKEND_URL')
    port = _port(env.get('WOOW_OD_MCP_PORT') or str(DEFAULT_PORT), 'WOOW_OD_MCP_PORT')
    if port == backend_port:
        raise SettingsError('the MCP port must differ from the daemon port')
    origin = (env.get('WOOW_OD_MCP_PUBLIC_ORIGIN') or '').strip().rstrip('/').lower()
    if origin and (len(origin) > 255 or not _ORIGIN.fullmatch(origin)):
        raise SettingsError('WOOW_OD_MCP_PUBLIC_ORIGIN must be scheme://host[:port]')
    return {'backend': backend, 'port': port, 'endpoint': origin + '/mcp' if origin else None}
