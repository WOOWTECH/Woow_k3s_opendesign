"""Fail when mcp-runtime/ha/ differs from mcp-runtime/HA_SOURCE.json (edited, added or missing files), then run the
HA runtime's own vendor check (ha/tests/verify_vendor.py: the Woow_ha_mcp_addons copy and the hash-pinned wheels).

    python3 open-design/mcp-runtime/tests/verify_ha_copy.py
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / 'HA_SOURCE.json').read_text())
errors = []
if not re.fullmatch(r'[0-9a-f]{40}', manifest.get('source_commit', '')):
    errors.append('source_commit is not a full sha')
copy = ROOT / 'ha'
actual = {str(p.relative_to(copy)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in sorted(copy.rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
expected = manifest.get('files', {})
for name in sorted(set(actual) | set(expected)):
    if name not in expected:
        errors.append('unlisted file in ha/: ' + name)
    elif name not in actual:
        errors.append('missing file in ha/: ' + name)
    elif actual[name] != expected[name]:
        errors.append('modified file in ha/: ' + name)
for required in ('VENDOR.json', 'ha_opendesign_mcp/__init__.py', 'ha_opendesign_mcp/runtime.py',
                 'ha_opendesign_mcp/child.py', 'requirements/management.txt', 'requirements/child.txt',
                 'tests/verify_vendor.py', 'vendor/packages/mcp-admin-ui/package-lock.json'):
    if required not in actual:
        errors.append('ha/ lacks ' + required)
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('HA built-in MCP runtime copy: %d files match %s@%s' % (
    len(actual), manifest['source_repository'], manifest['source_commit']))
sys.exit(subprocess.call([sys.executable, '-I', str(copy / 'tests' / 'verify_vendor.py')]))
