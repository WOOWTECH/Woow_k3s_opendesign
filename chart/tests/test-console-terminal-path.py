#!/usr/bin/env python3
"""Execute the rendered Console tab handler and check its actual iframe URL."""
import json
import os
from pathlib import Path
import subprocess
import unittest

import yaml


CHART = Path(__file__).resolve().parents[1]
HARNESS = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const frame = { src: 'about:blank' };
const panel = { classList: { add() {} } };
const context = {
  document: {
    querySelectorAll() { return []; },
    getElementById(id) { return id === 'ttydFrame' ? frame : panel; },
  },
  window: { location: { protocol: 'https:', hostname: 'console.example.test' } },
  refreshLogs() {},
};
vm.createContext(context);
vm.runInContext(input.code, context, { timeout: 1000 });
context.switchTab('terminal');
const first = frame.src;
frame.src += '?session=existing';
context.switchTab('dashboard');
context.switchTab('terminal');
process.stdout.write(JSON.stringify({ first, second: frame.src }));
"""


class ConsoleTerminalPathTests(unittest.TestCase):
    def test_rendered_terminal_navigation_preserves_configured_base_path(self):
        for runtime_install in (False, True):
            for path, expected in (("", "/"), ("/", "/"), ("/console", "/console/"),
                                   ("/console/", "/console/"),
                                   ("/operator/terminal", "/operator/terminal/")):
                with self.subTest(runtime_install=runtime_install, path=path):
                    rendered = subprocess.run(
                        [os.environ.get("HELM_BINARY", "helm"), "template", "t", str(CHART),
                         "--set-string", f"console.externalPath={path}",
                         "--set", f"console.runtimeInstall={str(runtime_install).lower()}"],
                        check=True, capture_output=True, text=True, timeout=30,
                    )
                    templates = next(d for d in yaml.safe_load_all(rendered.stdout)
                                     if d and d.get("kind") == "ConfigMap"
                                     and "index.html" in d.get("data", {}))
                    app = templates["data"]["index.html"]
                    code = app.split("<script>", 1)[1].split("async function refreshStatus", 1)[0]
                    result = subprocess.run(
                        [os.environ.get("NODE_BINARY", "node"), "-e", HARNESS],
                        input=json.dumps({"code": code}), check=True, capture_output=True,
                        text=True, timeout=10,
                    )
                    actual = json.loads(result.stdout)
                    url = "https://console.example.test:7681" + expected
                    self.assertEqual(actual["first"], url)
                    self.assertEqual(actual["second"], url + "?session=existing")


if __name__ == "__main__":
    unittest.main()
