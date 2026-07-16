#!/usr/bin/env python3
"""Open Design Console — Flask management dashboard."""
import json
import os
import subprocess
import threading
import time
from datetime import datetime, timezone

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

NAMESPACE = os.environ.get("NAMESPACE", "open-design")
POD_LABEL = "app=open-design"
CONTAINER = "open-design"

# Health history
health_history = []
health_lock = threading.Lock()

# Response cache for expensive kubectl+curl calls
_cache = {}
_cache_lock = threading.Lock()
CACHE_TTL = 15  # seconds


def _cache_get(key):
    with _cache_lock:
        entry = _cache.get(key)
        if entry and time.time() - entry["ts"] < CACHE_TTL:
            return entry["val"]
    return None


def _cache_set(key, val):
    with _cache_lock:
        _cache[key] = {"val": val, "ts": time.time()}


def get_pod_name():
    """Find the running open-design pod (cached)."""
    cached = _cache_get("pod_name")
    if cached is not None:
        return cached
    try:
        result = subprocess.run(
            ["kubectl", "get", "pod", "-l", POD_LABEL, "-n", NAMESPACE,
             "--field-selector=status.phase=Running",
             "-o", "jsonpath={.items[0].metadata.name}"],
            capture_output=True, text=True, timeout=10
        )
        pod = result.stdout.strip() or None
        if pod:
            _cache_set("pod_name", pod)
        return pod
    except Exception:
        return None


def kexec(cmd):
    """Execute command inside open-design pod, return stdout."""
    pod = get_pod_name()
    if not pod:
        return None
    try:
        result = subprocess.run(
            ["kubectl", "exec", pod, "-n", NAMESPACE, "-c", CONTAINER,
             "--", "sh", "-c", cmd],
            capture_output=True, text=True, timeout=15
        )
        return result.stdout
    except Exception:
        return None


def health_check_loop():
    """Background: check open-design health every 60s."""
    time.sleep(15)
    while True:
        try:
            pod = get_pod_name()
            ts = datetime.now(timezone.utc).isoformat()
            if pod:
                raw = kexec("curl -s http://localhost:7457/api/health 2>/dev/null")
                try:
                    data = json.loads(raw) if raw else {}
                    ok = data.get("ok", False)
                except Exception:
                    ok = False
                entry = {"ts": ts, "pod": pod, "ok": ok}
            else:
                entry = {"ts": ts, "pod": None, "ok": False}

            with health_lock:
                health_history.append(entry)
                if len(health_history) > 100:
                    health_history.pop(0)
        except Exception:
            pass
        time.sleep(60)


# Start health check background thread
threading.Thread(target=health_check_loop, daemon=True).start()


@app.route("/")
def index():
    return render_template("index.html")


def _fetch_health_data():
    """Fetch health data with caching."""
    cached = _cache_get("health_data")
    if cached is not None:
        return cached
    raw = kexec("curl -s http://localhost:7457/api/health 2>/dev/null")
    try:
        data = json.loads(raw) if raw else {}
    except Exception:
        data = {}
    _cache_set("health_data", data)
    return data


@app.route("/api/status")
def api_status():
    pod = get_pod_name()
    if not pod:
        return jsonify({"ok": False, "pod": None, "message": "Pod not found"})

    health = _fetch_health_data()
    agents_data = _fetch_agents_data()
    agents_available = []
    for a in agents_data.get("agents", []):
        if a.get("available"):
            agents_available.append({
                "id": a["id"],
                "name": a.get("name", a["id"]),
                "version": a.get("version", "unknown"),
                "path": a.get("path", ""),
            })

    return jsonify({
        "ok": health.get("ok", False),
        "pod": pod,
        "version": health.get("version", "unknown"),
        "agents": agents_available,
        "namespace": NAMESPACE,
    })


@app.route("/api/health-history")
def api_health_history():
    with health_lock:
        return jsonify(list(health_history))


def _fetch_agents_data():
    """Fetch agents data with caching."""
    cached = _cache_get("agents_data")
    if cached is not None:
        return cached
    raw = kexec("curl -s http://localhost:7457/api/agents 2>/dev/null")
    try:
        data = json.loads(raw) if raw else {}
    except Exception:
        data = {}
    _cache_set("agents_data", data)
    return data


@app.route("/api/agents")
def api_agents():
    data = _fetch_agents_data()
    if data:
        return jsonify(data)
    return jsonify({"agents": [], "error": "Failed to fetch agents"})


@app.route("/api/logs")
def api_logs():
    lines_param = request.args.get("lines", "100")
    try:
        lines = int(lines_param)
        if lines < 1:
            return jsonify({"error": "lines must be a positive integer"}), 400
        lines = min(lines, 10000)  # cap at 10k
    except (ValueError, TypeError):
        return jsonify({"error": "lines must be a valid integer"}), 400
    try:
        result = subprocess.run(
            ["kubectl", "logs", "--tail", str(lines),
             "-l", POD_LABEL, "-n", NAMESPACE, "-c", CONTAINER],
            capture_output=True, text=True, timeout=15
        )
        return jsonify({"logs": result.stdout})
    except Exception as e:
        return jsonify({"logs": "", "error": str(e)})


@app.route("/api/restart", methods=["POST"])
def api_restart():
    try:
        result = subprocess.run(
            ["kubectl", "rollout", "restart", "deployment/open-design",
             "-n", NAMESPACE],
            capture_output=True, text=True, timeout=15
        )
        return jsonify({"ok": result.returncode == 0, "message": result.stdout})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=18790, debug=False)
