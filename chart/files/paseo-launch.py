#!/usr/bin/env python3
"""Supervise optional Paseo beside OD, inside the existing container/PID namespace.

The image init remains PID 1. Only direct children started here are owned; no
pidfiles, process-name matching, or kills of another container/service. Keep an
exited child's zombie until its process group is stopped, preventing PID reuse
between exit observation and killpg. Runtime-detached children remain the Paseo
manager's responsibility (its existing /proc ownership/reconciliation protocol).
"""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import time
import urllib.request


SAFE_ENV = frozenset({
    "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "NODE_ENV",
    "NODE_PATH", "LD_LIBRARY_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR",
    "PUPPETEER_EXECUTABLE_PATH", "PUPPETEER_SKIP_DOWNLOAD",
    "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH", "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD",
    "USE_BUILTIN_RIPGREP", "LITELLM_BASE_URL",
    # Provider credentials already explicitly supplied to the tenant OD process
    # remain available to its CLI runtime. Never print their values.
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL",
    "OPENROUTER_API_KEY", "GEMINI_API_KEY", "CODEX_ACCESS_TOKEN",
})


def paseo_environment(env):
    # Deliberately exclude OD_API_TOKEN, Basic/login credentials, arbitrary
    # extraEnv and NODE_OPTIONS (including historical --import preloads).
    return {key: value for key, value in env.items()
            if key in SAFE_ENV or key.startswith("OPENDESIGN_PASEO_")}


def exited(child):
    # Popen.poll() would reap the child and release its PID too early.
    return os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None


def group_alive(pgid):
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "stat").read_text()
            fields = raw[raw.rfind(")") + 2:].split()
            if int(fields[2]) == pgid and fields[0] not in {"Z", "X"}:
                return True
        except (OSError, ValueError, IndexError):
            continue
    return False


def signal_group(child, sig):
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass


def stop_children(children, timeout):
    children = [child for child in children if child is not None]
    for child in children:
        signal_group(child, signal.SIGTERM)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and any(group_alive(c.pid) for c in children):
        time.sleep(0.05)
    for child in children:
        # A zombie group leader still reserves this process group ID until wait().
        signal_group(child, signal.SIGKILL)
    return [child.wait() for child in children]


def healthy(url):
    try:
        # No ambient proxy credentials; the request stays on the fixed loopback app.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=1) as response:
            return response.status == 200
    except (OSError, ValueError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paseo-entry", default="/opt/opendesign-paseo/bin/serve.mjs")
    parser.add_argument("--restart-delay", type=float, default=5)
    parser.add_argument("--stop-timeout", type=float, default=10)
    parser.add_argument("--health-url", default="http://127.0.0.1:7460/healthz")
    parser.add_argument("--health-interval", type=float, default=5)
    parser.add_argument("--health-grace", type=float, default=30)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or min(args.restart_delay, args.stop_timeout, args.health_interval) <= 0 or args.health_grace < 0:
        parser.error("daemon argv and positive supervision intervals are required")

    stopping = False

    def request_stop(_sig, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    daemon = None
    paseo = None
    try:
        # No shell; preserve the original daemon argv, working directory and env.
        daemon = subprocess.Popen(command, start_new_session=True)
        next_start = 0.0
        next_health = 0.0
        failures = 0
        while not stopping:
            if exited(daemon):
                codes = stop_children([daemon, paseo], args.stop_timeout)
                daemon = paseo = None
                return codes[0] if codes[0] >= 0 else 128 - codes[0]
            now = time.monotonic()
            if paseo is not None and exited(paseo):
                stop_children([paseo], args.stop_timeout)
                paseo = None
                next_start = time.monotonic() + args.restart_delay
                print("[paseo-launch] app exited; retry scheduled", flush=True)
            if paseo is None and now >= next_start and not stopping:
                try:
                    if not Path(args.paseo_entry).is_file():
                        raise FileNotFoundError()
                    paseo = subprocess.Popen(["node", args.paseo_entry],
                                             env=paseo_environment(os.environ),
                                             start_new_session=True)
                    next_health = now + args.health_grace
                    failures = 0
                except OSError:
                    print("[paseo-launch] app unavailable; OD continues; retry scheduled", flush=True)
                    next_start = now + args.restart_delay
            if paseo is not None and args.health_url and now >= next_health:
                failures = 0 if healthy(args.health_url) else failures + 1
                next_health = time.monotonic() + args.health_interval
                if failures >= 3:
                    print("[paseo-launch] app health failed; restarting app only", flush=True)
                    stop_children([paseo], args.stop_timeout)
                    paseo = None
                    next_start = time.monotonic() + args.restart_delay
            time.sleep(0.1)
        return 0
    except OSError:
        # No raw exception: env, argv, URLs and filesystem details stay out of logs.
        print("[paseo-launch] daemon or supervisor startup failed", flush=True)
        return 1
    finally:
        stop_children([daemon, paseo], args.stop_timeout)


if __name__ == "__main__":
    raise SystemExit(main())
