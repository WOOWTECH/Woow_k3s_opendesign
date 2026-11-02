"""Build-time contract (open-design image, runs as uid 1001): claude-agent-sdk must
resolve the musl-native Claude Code pinned in the Dockerfile.

claude-agent-sdk is installed from its sdist on Alpine (no musllinux wheel), which has
no _bundled/claude, so SubprocessCLITransport._find_cli() falls back to `claude` on
PATH. Prove that with the SDK's OWN resolution code instead of testing that a file is
absent: _find_bundled_cli() is None, _find_cli() is /usr/local/bin/claude, that file
runs here (an ELF must use the musl loader) and reports the pinned version.

usage: /opt/omnigent/venv/bin/python build-contract-omnigent.py <CLAUDE_CODE_VERSION>
"""
import os
import subprocess
import sys

from claude_agent_sdk import ClaudeAgentOptions
from claude_agent_sdk._internal.transport.subprocess_cli import SubprocessCLITransport

want = sys.argv[1]
t = SubprocessCLITransport(prompt="contract", options=ClaudeAgentOptions())
bundled = t._find_bundled_cli()
assert bundled is None, f"claude-agent-sdk ships a bundled claude: {bundled}"
cli = t._find_cli()
assert cli == "/usr/local/bin/claude", f"claude-agent-sdk resolves {cli!r}, expected /usr/local/bin/claude"
real = os.path.realpath(cli)
with open(real, "rb") as f:
    head = f.read(4096)
if head.startswith(b"\x7fELF"):
    assert b"/lib/ld-musl-x86_64.so.1" in head, f"{real} is an ELF without the musl loader"
else:
    assert head.startswith(b"#!"), f"{real} is neither an ELF nor a script"
out = subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=60, check=True).stdout
assert out.split()[:1] == [want], f"claude --version {out!r} != {want}"
print(f"contract OK: claude-agent-sdk resolves {cli} -> {real} ({out.strip()})")
