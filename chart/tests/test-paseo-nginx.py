#!/usr/bin/env python3
"""Real local nginx checks of Helm output; no Kubernetes or upstream requests.

Requires helm, PyYAML and nginx with njs. NGINX_ROOTFS can point to an already
extracted nginx-unprivileged Alpine image; its musl loader runs without chroot.
Missing prerequisites fail rather than silently reporting a skipped regression.
"""

import http.client
import base64
import hashlib
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest

import yaml


CHART = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).parent / "fixtures/paseo-nginx-origins.json"
BUCKET = re.compile(r"^\s*map_hash_bucket_size\s+\d+;\s*$", re.MULTILINE)


def origins():
    result = {}
    for row in json.loads(FIXTURES.read_text()):
        host = ".".join(chr(97 + i) * n for i, n in enumerate(row.get("labelLengths", [])))
        origin = row.get("origin") or "https://" + host
        if row.get("port"):
            origin += ":" + str(row["port"])
        result[row["name"]] = origin
    return result


def nginx_runtime():
    if os.environ.get("NGINX_ROOTFS"):
        root = Path(os.environ["NGINX_ROOTFS"]).resolve()
        loaders = list((root / "lib").glob("ld-musl-*.so.1"))
        if len(loaders) != 1:
            raise RuntimeError("NGINX_ROOTFS requires one matching musl loader")
        command = [str(loaders[0]), "--library-path", f"{root}/lib:{root}/usr/lib",
                   str(root / "usr/sbin/nginx")]
    else:
        root = Path("/")
        binary = os.environ.get("NGINX_BINARY") or shutil.which("nginx")
        if not binary:
            raise RuntimeError("Install nginx+njs or provide NGINX_ROOTFS; see test-paseo-nginx.md")
        command = [binary]
    modules = Path(os.environ.get("NGINX_MODULE_DIR", str(root / "usr/lib/nginx/modules")))
    mime = root / "etc/nginx/mime.types"
    for required in [modules / "ngx_http_js_module.so", mime]:
        if not required.is_file():
            raise RuntimeError(f"Missing nginx test prerequisite: {required}")
    return command, modules, mime


class NginxStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.command, cls.modules, cls.mime = nginx_runtime()
        cls.origins = origins()
        version = subprocess.run(cls.command + ["-v"], capture_output=True, text=True,
                                 check=True, timeout=10)
        print(version.stderr.strip(), flush=True)

    def render(self, folder, origin, *, enabled=True, guard=True, console=True, mcp=True):
        values = {
            "auth": {"existingSecret": "synthetic-fixture"},
            "authProxy": {"guard": {"enabled": guard}},
            "paseo": {"enabled": enabled, "origin": origin},
            "config": {"allowedOrigins": origin},
            "console": {"enabled": console}, "mcp": {"enabled": mcp},
        }
        file = folder / "values.yaml"
        file.write_text(yaml.safe_dump(values))
        rendered = subprocess.run([
            os.environ.get("HELM_BINARY", "helm"), "template", "fixture", str(CHART),
            "--namespace", "offline-fixture", "-f", str(file)],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        docs = list(yaml.safe_load_all(rendered.stdout))
        return next(d["data"] for d in docs if d and d["kind"] == "ConfigMap"
                    and d["metadata"]["name"] == "fixture-open-design-authproxy")

    def materialize(self, folder, data):
        # Relocate only filesystem paths, listen socket, and console DNS. Keep
        # complete rendered maps, locations, njs and MCP Unix-upstream syntax.
        replacements = {
            "modules/ngx_http_js_module.so": str(self.modules / "ngx_http_js_module.so"),
            "/etc/nginx/mime.types": str(self.mime),
            "/etc/nginx/conf.d/*.conf": str(folder / "default.conf"),
            "/etc/nginx/njs/authguard.js": str(folder / "authguard.js"),
            "/etc/nginx/auth/.htpasswd": str(folder / "fixture.htpasswd"),
            "/var/log/nginx/": str(folder) + "/",
            "/tmp/": str(folder) + "/",
            "http://fixture-open-design-console:": "http://127.0.0.1:",
            "listen 8080;": f"listen unix:{folder}/nginx.sock;",
        }
        for name in ["nginx.conf", "default.conf", "authguard.js"]:
            if name not in data:
                continue
            content = data[name]
            # Single-pass replacement avoids rewriting /tmp inside a new path.
            pattern = "|".join(re.escape(key) for key in replacements)
            content = re.sub(pattern, lambda match: replacements[match[0]], content)
            if name == "nginx.conf" and os.geteuid() == 0:
                # Container CI runs as root. Keep test workers under the same
                # identity so they can read this test's private temp directory.
                content = "user root;\n" + content
            (folder / name).write_text(content)
        (folder / "fixture.htpasswd").write_text("")
        (folder / "logs").mkdir(exist_ok=True)
        return self.command + ["-p", str(folder) + "/", "-c", str(folder / "nginx.conf"),
                               "-e", str(folder / "bootstrap.log")]

    def check(self, command):
        return subprocess.run(command + ["-t"], capture_output=True, text=True, timeout=10)

    def assert_starts(self, folder, command, exercise=None):
        checked = self.check(command)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        with (folder / "process.log").open("w+") as log:
            child = subprocess.Popen(command + ["-g", "daemon off;"], stdout=log,
                                     stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and child.poll() is None:
                    client = http.client.HTTPConnection("localhost", timeout=0.3)
                    try:
                        client.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        client.sock.settimeout(0.3)
                        client.sock.connect(str(folder / "nginx.sock"))
                        client.request("GET", "/healthz")
                        response = client.getresponse()
                        self.assertEqual((response.status, response.read()), (200, b"ok\n"))
                        if exercise:
                            exercise()
                        return
                    except (OSError, http.client.HTTPException):
                        time.sleep(0.03)
                    finally:
                        client.close()
                log.seek(0)
                self.fail("nginx did not serve its local health stub: " + log.read()
                          + (folder / "error.log").read_text())
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGQUIT)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=3)

    def test_proxy_enforces_auth_exact_origin_and_sanitizes_identity(self):
        received = []

        class Upstream(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append({'method': self.command, 'path': self.path,
                                 'headers': dict(self.headers)})
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'fixture')

            do_POST = do_GET

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='paseo-proxy-') as tmp:
                folder = Path(tmp)
                origin = self.origins['paas']
                data = self.render(folder, origin)
                # Bind the fake app to its own ephemeral port, never an existing app.
                data['default.conf'] = data['default.conf'].replace(
                    'http://127.0.0.1:7460;', f'http://127.0.0.1:{server.server_port};')
                command = self.materialize(folder, data)
                password = 'synthetic-local-only'
                digest = base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()
                (folder / 'fixture.htpasswd').write_text(f'fixture:{{SHA}}{digest}\n')
                authorization = 'Basic ' + base64.b64encode(f'fixture:{password}'.encode()).decode()

                def request(method, path, headers):
                    with closing(http.client.HTTPConnection('localhost', timeout=2)) as client:
                        client.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        client.sock.settimeout(2)
                        client.sock.connect(str(folder / 'nginx.sock'))
                        client.request(method, path, headers=headers)
                        response = client.getresponse()
                        return response.status, response.read()

                def exercise():
                    for path in ['/paseo/setup', '/paseo/setup/', '/paseo/assets/app.js',
                                 '/api/paseo-bridge']:
                        with self.subTest(path=path):
                            before = len(received)
                            self.assertEqual(request('GET', path, {})[0], 401)
                            self.assertEqual(request('POST', path, {'Authorization': authorization})[0], 403)
                            self.assertEqual(request('GET', path, {
                                'Authorization': authorization, 'Origin': origin + '.attacker.invalid'})[0], 403)
                            self.assertEqual(len(received), before)
                            self.assertEqual(request('GET', path, {'Authorization': authorization}),
                                             (200, b'fixture'))
                            self.assertEqual(request('POST', path, {
                                'Authorization': authorization, 'Origin': origin,
                                'X-Remote-User-Id': 'spoofed'}), (200, b'fixture'))
                            forwarded = received[-1]
                            self.assertEqual(forwarded['path'], path)
                            self.assertEqual(forwarded['method'], 'POST')
                            self.assertEqual(forwarded['headers']['Origin'], origin)
                            self.assertEqual(forwarded['headers']['X-Remote-User-Id'], 'fixture')
                            self.assertNotIn('Authorization', forwarded['headers'])

                self.assert_starts(folder, command, exercise)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_fixture_covers_full_dns_length_and_port(self):
        self.assertEqual(len(self.origins["max-dns"].removeprefix("https://")), 253)
        self.assertGreater(len("0:" + self.origins["paas"]), 64)
        self.assertTrue(self.origins["max-dns-port"].endswith(":65535"))

    def test_full_render_starts_for_short_paas_and_maximum_origins(self):
        for name, origin in self.origins.items():
            with self.subTest(origin=name), tempfile.TemporaryDirectory(prefix="paseo-nginx-") as tmp:
                folder = Path(tmp)
                data = self.render(folder, origin)
                self.assertEqual(BUCKET.findall(data["nginx.conf"])[0].strip(),
                                 "map_hash_bucket_size 512;")
                self.assertIn('"0:' + origin + '" 1;', data["default.conf"])
                self.assertIn('"1:' + origin + '" 1;', data["default.conf"])
                self.assert_starts(folder, self.materialize(folder, data))

    def test_64_byte_bucket_reproduces_the_real_nginx_failure(self):
        for name in ["paas", "max-dns-port"]:
            with self.subTest(origin=name), tempfile.TemporaryDirectory(prefix="paseo-nginx-") as tmp:
                folder = Path(tmp)
                data = self.render(folder, self.origins[name])
                data["nginx.conf"], count = BUCKET.subn("\nmap_hash_bucket_size 64;", data["nginx.conf"])
                self.assertEqual(count, 1)
                result = self.check(self.materialize(folder, data))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("could not build map_hash", result.stderr)
                self.assertIn("map_hash_bucket_size", result.stderr)

    def test_guard_off_and_optional_routes_off_still_start(self):
        for options in [{"guard": False}, {"console": False, "mcp": False}]:
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix="paseo-nginx-") as tmp:
                folder = Path(tmp)
                data = self.render(folder, self.origins["max-dns-port"], **options)
                self.assert_starts(folder, self.materialize(folder, data))

    def test_disabled_paseo_keeps_existing_short_origin_startup(self):
        with tempfile.TemporaryDirectory(prefix="paseo-nginx-") as tmp:
            folder = Path(tmp)
            data = self.render(folder, self.origins["short"], enabled=False)
            self.assertEqual([line.strip() for line in BUCKET.findall(data["nginx.conf"])],
                             ["map_hash_bucket_size 512;"])
            self.assertNotIn("$od_paseo_origin_ok", data["default.conf"])
            self.assert_starts(folder, self.materialize(folder, data))

    def test_disabling_paseo_preserves_long_origin_startup(self):
        # The older local-route map also stores complete origins, so the bucket
        # directive must remain when the optional Paseo routes disappear.
        for name in ["paas", "max-dns-port"]:
            with self.subTest(origin=name), tempfile.TemporaryDirectory(prefix="paseo-nginx-") as tmp:
                folder = Path(tmp)
                data = self.render(folder, self.origins[name], enabled=False)
                self.assertEqual([line.strip() for line in BUCKET.findall(data["nginx.conf"])],
                                 ["map_hash_bucket_size 512;"])
                self.assertNotIn("$od_paseo_origin_ok", data["default.conf"])
                self.assertIn(self.origins[name], data["default.conf"])
                self.assert_starts(folder, self.materialize(folder, data))


if __name__ == "__main__":
    unittest.main(verbosity=2)
