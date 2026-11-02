"""Run the HA add-on's built-in MCP runtime (ha_opendesign_mcp.runtime, ../ha/) at the PaaS placement.

Nothing of the runtime is re-implemented here. The add-on's package keeps its placement in module constants
(ha_opendesign_mcp/__init__.py: BACKEND_URL, DATA_DIR, RUN_DIR, ADMIN_SOCKET, CHILD_SOCKET, MCP_HOST, MCP_PORT);
place() imports the runtime, replaces exactly those constants in every loaded ha_opendesign_mcp module with the PaaS
values (paas_opendesign_mcp/__init__.py), and adds one PaaS step to the add-on's start: the admin page's client
endpoint is seeded with <public origin>/mcp while it is unset. Then the add-on's runtime main() runs unchanged: the
same gateway, tool surface, default grants, protections, admin page and state handling as the HA add-on.

A re-sync of ../ha/ that renames or removes one of those constants, or pin_backend(), refuses to start (RuntimeError)
until this file is reviewed against it.
"""
import sys

from . import ADMIN_SOCKET, CHILD_SOCKET, DATA_DIR, MCP_HOST, RUN_DIR, settings

PACKAGE = 'ha_opendesign_mcp'


def placement(config):
    return {'BACKEND_URL': config['backend'], 'DATA_DIR': DATA_DIR, 'RUN_DIR': RUN_DIR,
            'ADMIN_SOCKET': ADMIN_SOCKET, 'CHILD_SOCKET': CHILD_SOCKET, 'MCP_HOST': MCP_HOST,
            'MCP_PORT': config['port']}


def place(config):
    import ha_opendesign_mcp
    import ha_opendesign_mcp.runtime as runtime  # loads every module of the package the runtime uses

    values = placement(config)
    missing = sorted(name for name in values if not hasattr(ha_opendesign_mcp, name))
    if missing:
        raise RuntimeError('HA runtime placement constants changed: ' + ', '.join(missing))
    for name, module in list(sys.modules.items()):
        if module is not None and (name == PACKAGE or name.startswith(PACKAGE + '.')):
            for key, value in values.items():
                if key in vars(module):
                    setattr(module, key, value)
    if not callable(getattr(runtime, 'pin_backend', None)):
        raise RuntimeError('HA runtime pin_backend() changed; review endpoint seeding')
    endpoint = config['endpoint']
    pin_backend = runtime.pin_backend

    def pin_and_seed(store):
        state = pin_backend(store)
        if endpoint and state.endpoint is None:
            store.update(endpoint=endpoint)
            state = store.load()
        return state

    runtime.pin_backend = pin_and_seed
    return runtime


def main():
    runtime = place(settings())
    print('[paas-opendesign-mcp] HA built-in MCP runtime on %s:%d, admin on %s' % (
        MCP_HOST, runtime.MCP_PORT, ADMIN_SOCKET), flush=True)
    runtime.main()


if __name__ == '__main__':
    main()
