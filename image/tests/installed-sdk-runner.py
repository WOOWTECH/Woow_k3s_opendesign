"""Executed as uid 1001 by the candidate SDK Python with -I -B."""
import hashlib
import importlib.metadata
import os
from pathlib import Path
import pytest

import omnigent.harnesses.opencode_native.forwarder as forwarder
import omnigent.harnesses.opencode_native.client as client
import omnigent.harnesses.opencode_native.bridge as bridge
import omnigent.runner.native.interrupt as interrupt

assert os.getuid() == 1001
sdk = importlib.metadata.distribution('omnigent')
assert sdk.version == '0.16.0'
root = Path(sdk.locate_file('omnigent')).resolve()
assert 'site-packages' in root.parts, 'Reject source/editable SDK'
before = {}
for module in (forwarder, client, bridge, interrupt):
    source = Path(module.__file__).resolve()
    assert source.is_relative_to(root), 'Reject injected SDK module'
    before[source] = hashlib.sha256(source.read_bytes()).hexdigest()
    print(module.__name__, source, before[source])

result = pytest.main([
    '-p', 'pytest_asyncio.plugin', '-c', '/tmp/sdk-bundle/pytest.ini',
    '/tmp/sdk-bundle/test_opencode_native_forwarder.py',
    '/tmp/sdk-bundle/test_opencode_forwarder_reconnect.py',
    '/tmp/sdk-bundle/test_opencode_native_interrupt.py',
    '--junitxml=/tmp/installed-sdk.xml', '-q',
])
assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest
           for path, digest in before.items()), 'SDK modified by tests'
raise SystemExit(result)
