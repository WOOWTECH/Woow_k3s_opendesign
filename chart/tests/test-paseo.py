#!/usr/bin/env python3
"""Offline chart and synthetic-process checks; no Kubernetes, registry or provider calls."""

import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

import yaml


CHART = Path(__file__).resolve().parents[1]
REPO = CHART.parents[1]
BASELINE_REVISION = "33d476a"  # Chart 0.5.7 before this feature; stable after commit.
LAUNCH = CHART / "files/paseo-launch.py"
spec = importlib.util.spec_from_file_location("paseo_launch", LAUNCH)
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


def render(chart=CHART, **values):
    cmd = ["helm", "template", "fixture", str(chart), "--namespace", "offline-fixture",
           "--set", "auth.existingSecret=offline-fixture"]
    for key, value in values.items():
        if isinstance(value, bool):
            value = str(value).lower()
        cmd.extend(["--set", f"{key}={value}"])
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def documents(result):
    if result.returncode:
        raise AssertionError(result.stderr)
    return {(x["kind"], x["metadata"]["name"]): x
            for x in yaml.safe_load_all(result.stdout) if x}


ON = {"paseo.enabled": True, "paseo.origin": "https://fixture.example"}


class ChartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.enabled = documents(render(**ON, **{"mcp.enabled": True, "console.enabled": True}))
        cls.disabled = documents(render(**{"mcp.enabled": True, "console.enabled": True}))

    def pod(self, docs):
        return docs[("StatefulSet", "fixture-open-design")]["spec"]["template"]["spec"]

    def test_disabled_and_legacy_values_match_baseline_except_reviewed_fixes(self):
        data = subprocess.run(["git", "-C", str(REPO), "archive", BASELINE_REVISION, "charts/open-design"],
                              capture_output=True, check=True).stdout
        with tempfile.TemporaryDirectory() as folder:
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                # Python on the research host predates tarfile's filter argument.
                # Accept only regular files rooted in this chart, never links.
                for member in archive.getmembers():
                    parts = Path(member.name).parts
                    if not member.isfile():
                        continue
                    self.assertEqual(parts[:2], ("charts", "open-design"))
                    self.assertNotIn("..", parts)
                    dest = Path(folder) / member.name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(archive.extractfile(member).read())
            # Align only chart-version metadata before comparing the old chart.
            # This also derives the expected version-bearing rollout checksums.
            baseline_chart = Path(folder) / "charts/open-design/Chart.yaml"
            metadata = yaml.safe_load(baseline_chart.read_text())
            metadata["version"] = yaml.safe_load((CHART / "Chart.yaml").read_text())["version"]
            baseline_chart.write_text(yaml.safe_dump(metadata, sort_keys=False))
            # Only these independently tested fixes differ with Paseo disabled.
            # Patch the temporary baseline, then compare every rendered document,
            # including the checksum derived from the exact changed template.
            baseline_template = Path(folder) / "charts/open-design/templates/auth-proxy-configmap.yaml"
            source = baseline_template.read_text()
            anchor = "    http {\n"
            self.assertEqual(source.count(anchor), 1)
            baseline_template.write_text(source.replace(anchor, anchor +
                "      # The origin map includes the method prefix and a full DNS host. Keep\n"
                "      # valid long public origins within one hash bucket (nginx default: 64).\n"
                "      map_hash_bucket_size 512;\n", 1))
            console_template = Path(folder) / "charts/open-design/templates/console-configmap.yaml"
            console_source = console_template.read_text()
            port = "    const TTYD_PORT = {{ .Values.console.service.ttydPort }};\n"
            old_url = "frame.src = loc.protocol + '//' + loc.hostname + ':' + TTYD_PORT;"
            self.assertEqual(console_source.count(port), 1)
            self.assertEqual(console_source.count(old_url), 1)
            console_template.write_text(console_source.replace(port, port +
                '    const TTYD_BASE_PATH = {{ default "" .Values.console.externalPath | trimSuffix "/" | toJson }};\n', 1)
                .replace(old_url, "frame.src = loc.protocol + '//' + loc.hostname + ':' + TTYD_PORT + TTYD_BASE_PATH + '/';", 1))
            baseline = documents(render(Path(folder) / "charts/open-design",
                                        **{"mcp.enabled": True, "console.enabled": True}))
            self.assertEqual(self.disabled, baseline)
            legacy = documents(render(**{"paseo": "null", "mcp.enabled": True, "console.enabled": True}))
            self.assertEqual(legacy, baseline)

    def test_same_container_preserves_other_components(self):
        before, after = self.pod(self.disabled), self.pod(self.enabled)
        self.assertEqual([c["name"] for c in before["containers"]],
                         [c["name"] for c in after["containers"]])
        old_od, new_od = before["containers"][0], after["containers"][0]
        self.assertNotIn("command", new_od)  # Preserve the image ENTRYPOINT.
        self.assertEqual(new_od["args"][:3], ["python3", "/etc/opendesign-paseo/launch.py", "--"])
        self.assertEqual(new_od["args"][3:], old_od["args"])
        for key in ["image", "securityContext", "resources", "startupProbe", "livenessProbe", "envFrom"]:
            self.assertEqual(new_od.get(key), old_od.get(key))
        self.assertEqual(before["containers"][1:], after["containers"][1:])
        self.assertEqual(before["initContainers"], after["initContainers"])
        self.assertEqual(old_od["volumeMounts"], [v for v in new_od["volumeMounts"] if v["name"] != "paseo-launch"])
        for key, value in self.disabled.items():
            if key[0] != "StatefulSet" and key != ("ConfigMap", "fixture-open-design-authproxy"):
                self.assertEqual(value, self.enabled[key], key)

    def test_runtime_environment_and_persistence(self):
        docs = documents(render(**ON, **{"persistence.data.mountPath": "/persistent/od",
                                         "persistence.home.mountPath": "/persistent/home",
                                         "service.targetPort": 7459}))
        env = {e["name"]: e.get("value") for e in self.pod(docs)["containers"][0]["env"]}
        self.assertEqual(env["HOME"], "/persistent/home")
        self.assertEqual(env["OPENDESIGN_PASEO_DATA_DIR"], "/persistent/od")
        self.assertEqual(env["OPENDESIGN_PASEO_NATIVE_PORT"], "7459")
        self.assertEqual(env["OPENDESIGN_PASEO_ORIGIN"], "https://fixture.example")
        self.assertEqual(env["OPENDESIGN_PASEO_AUTO_ENABLE"], "1")
        self.assertEqual(env["OPENDESIGN_PASEO_BUNDLED_PLUGIN"], "/app/plugins/_official/woow/woow-paseo")

    def test_proxy_routes_and_origin_boundary(self):
        conf = self.enabled[("ConfigMap", "fixture-open-design-authproxy")]["data"]["default.conf"]
        self.assertIn('"1:" 1;', conf)
        self.assertIn('"0:https://fixture.example" 1;', conf)
        self.assertNotIn('"0:" 1;', conf)
        for route in ["= /paseo/setup", "= /paseo/setup/", "^~ /paseo/assets/", "= /api/paseo-bridge"]:
            block = conf.split("location " + route + " {", 1)[1].split("\n  }", 1)[0]
            for expected in ['auth_basic "Open Design";', 'proxy_pass http://127.0.0.1:7460;',
                             'proxy_set_header Origin $http_origin;', 'proxy_set_header Authorization "";',
                             'if ($od_paseo_origin_ok = 0)', 'proxy_buffering off;',
                             'access_log off;', 'error_log /dev/null;']:
                self.assertIn(expected, block)
        # Existing nginx /healthz remains a local stub, never the app's health endpoint.
        health = conf.split("location = /healthz {", 1)[1].split("}", 1)[0]
        self.assertNotIn("proxy_pass", health)
        self.assertIn('return 200 "ok\\n";', health)

    def test_invalid_deployment_contracts_fail_closed(self):
        cases = [
            {"authProxy.enabled": False}, {"authProxy.basicAuth.enabled": False},
            {"image.enforceBindHost": False}, {"config.bindHost": "0.0.0.0"},
            {"paseo.origin": "http://fixture.example"}, {"paseo.origin": "https://fixture.example/path"},
            {"paseo.origin": "*"}, {"service.targetPort": 7460}, {"authProxy.port": 7460},
            {"mcp.enabled": True, "mcp.port": 7460}, {"persistence.home.enabled": False},
            {"persistence.data.enabled": False},
            {"console.enabled": True, "console.externalPath": "/paseo"},
            {"extraEnv[0].name": "HOME", "extraEnv[0].value": "/other"},
            {"extraEnv[0].name": "OPENDESIGN_PASEO_DATA_DIR", "extraEnv[0].value": "/other"},
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertNotEqual(render(**(ON | case)).returncode, 0)

    def test_origin_fallback_and_wrapper_rollout_checksum(self):
        docs = documents(render(**{"paseo.enabled": True, "config.allowedOrigins": "https://fixture.example"}))
        annotations = docs[("StatefulSet", "fixture-open-design")]["spec"]["template"]["metadata"]["annotations"]
        self.assertIn("checksum/paseo-launch", annotations)
        self.assertNotEqual(annotations["checksum/authproxy-config"],
                            self.disabled[("StatefulSet", "fixture-open-design")]["spec"]["template"]["metadata"]["annotations"]["checksum/authproxy-config"])
        self.assertNotEqual(render(**{"paseo.enabled": True}).returncode, 0)


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.events = self.root / "events.jsonl"
        self.events.touch()
        self.child = None
        self.log = (self.root / "supervisor.log").open("w+")
        self.daemon_script = self.root / "daemon.py"
        self.daemon_script.write_text('''import json, os, signal, subprocess, sys, time
p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
with open(os.environ["OPENDESIGN_PASEO_TEST_LOG"], "a") as f:
    f.write(json.dumps({"kind": "od", "pid": os.getpid(), "child": p.pid}) + "\\n")
while True: time.sleep(1)
''')
        self.app = self.root / "app.mjs"
        self.app.write_text('''import fs from 'node:fs';
import {spawn} from 'node:child_process';
const child = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)']);
fs.appendFileSync(process.env.OPENDESIGN_PASEO_TEST_LOG,
 JSON.stringify({kind:'paseo',pid:process.pid,child:child.pid,hasOdToken:'OD_API_TOKEN' in process.env,
 hasPreload:'NODE_OPTIONS' in process.env,hasProvider:'ANTHROPIC_API_KEY' in process.env})+'\\n');
setInterval(()=>{},1000);
''')

    def rows(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()]

    def await_rows(self, predicate, timeout=6):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            rows = self.rows()
            if predicate(rows):
                return rows
            time.sleep(0.03)
        self.fail("timed out waiting for synthetic child events")

    def start(self, extra=(), daemon=None, app=None):
        env = {"PATH": os.environ["PATH"], "HOME": str(self.root),
               "OPENDESIGN_PASEO_TEST_LOG": str(self.events),
               "OD_API_TOKEN": "synthetic-not-a-secret", "ANTHROPIC_API_KEY": "synthetic-not-used"}
        self.child = subprocess.Popen([
            sys.executable, str(LAUNCH), "--paseo-entry", str(app or self.app),
            "--restart-delay", "0.1", "--stop-timeout", "0.3", "--health-url", "",
            *extra, "--", *(daemon or [sys.executable, str(self.daemon_script)])],
            env=env, stdout=self.log, stderr=self.log)

    def tearDown(self):
        if self.child and self.child.poll() is None:
            self.child.terminate()
            self.child.wait(timeout=5)
        self.log.close()
        self.temp.cleanup()

    def test_child_environment_drops_web_secrets_and_preload(self):
        env = launch.paseo_environment({"HOME": "/tenant", "OD_API_TOKEN": "fixture",
            "TUI_PASSWORD": "fixture", "UNRELATED_SECRET": "fixture", "NODE_OPTIONS": "--import old-preload",
            "ANTHROPIC_API_KEY": "fixture", "OPENDESIGN_PASEO_ORIGIN": "https://fixture.example"})
        self.assertEqual(set(env), {"HOME", "ANTHROPIC_API_KEY", "OPENDESIGN_PASEO_ORIGIN"})

    def test_app_crash_restarts_only_owned_app_and_reaps_group(self):
        self.start()
        rows = self.await_rows(lambda r: len(r) >= 2)
        od = next(r for r in rows if r["kind"] == "od")
        app = next(r for r in rows if r["kind"] == "paseo")
        self.assertFalse(app["hasOdToken"])
        self.assertFalse(app["hasPreload"])
        self.assertTrue(app["hasProvider"])
        os.kill(app["pid"], signal.SIGKILL)
        rows = self.await_rows(lambda r: sum(x["kind"] == "paseo" for x in r) >= 2)
        self.assertEqual([r["pid"] for r in rows if r["kind"] == "od"], [od["pid"]])
        self.assertFalse(launch.group_alive(app["pid"]))
        self.assertTrue(launch.group_alive(od["pid"]))

    def test_missing_bundle_keeps_daemon_running(self):
        self.start(app=self.root / "missing.mjs")
        rows = self.await_rows(lambda r: any(x["kind"] == "od" for x in r))
        time.sleep(0.4)
        self.assertIsNone(self.child.poll())
        self.assertTrue(launch.group_alive(rows[0]["pid"]))

    def test_graceful_shutdown_stops_both_owned_groups(self):
        self.start()
        rows = self.await_rows(lambda r: len(r) >= 2)
        self.child.terminate()
        self.assertEqual(self.child.wait(timeout=5), 0)
        for row in rows:
            self.assertFalse(launch.group_alive(row["pid"]))

    def test_daemon_failure_preserves_exit_code_and_stops_app(self):
        self.start()
        rows = self.await_rows(lambda r: len(r) >= 2)
        od = next(r for r in rows if r["kind"] == "od")
        os.kill(od["pid"], signal.SIGKILL)
        self.assertEqual(self.child.wait(timeout=5), 137)
        for row in rows:
            self.assertFalse(launch.group_alive(row["pid"]))

    def test_health_failure_restarts_app_without_network_requests(self):
        self.start(extra=["--health-url", "file:///does-not-exist-paseo-fixture",
                          "--health-interval", "0.1", "--health-grace", "0"])
        rows = self.await_rows(lambda r: sum(x["kind"] == "paseo" for x in r) >= 2)
        self.assertEqual(sum(x["kind"] == "od" for x in rows), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
