"""Trusted management boundary of the built-in MCP server, after bin/paas-opendesign-mcp's exec (uid 10001).

The same boundary as the HA add-on's ha_opendesign_mcp/management.py: applies the vendored
packaging/management_launcher.guard() (no_new_privs, not dumpable, no core dumps: the same-uid child cannot read this
process's memory, which holds the MCP token), then runs paas_opendesign_mcp.launch (the add-on's runtime at the PaaS
placement) with runpy. Do not replace runpy with exec: exec resets dumpability.
"""
import os
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging'))

from management_launcher import guard  # noqa: E402  vendored


def main():
    if len(sys.argv) != 1 or os.geteuid() == 0:
        raise RuntimeError('fixed nonroot management required')
    guard()
    sys.argv = ['paas_opendesign_mcp.launch']
    runpy.run_module('paas_opendesign_mcp.launch', run_name='__main__', alter_sys=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError):
        raise SystemExit('built-in MCP management unavailable; credential guard or runtime failed') from None
