#!/usr/bin/env python3
"""agent-defaults — OpenDesign's out-of-the-box agent and OpenCode model (#1437 / #1438).

Runs in the `agent-defaults` initContainer (daemon image, uid 1001, od-data + od-home
mounted) on EVERY pod start, before the daemon. It never prints or stores a key: the API
keys arrive as env vars and only their PRESENCE is used.

1. ~/.config/opencode/opencode.jsonc — pin OpenCode's default model ("Default (CLI
   config)" in the UI). Unpinned, OpenCode picks a model by name from the OpenRouter
   catalogue without checking tool support and landed on an image model, so every first
   run failed ("No endpoints found that support tool use").
   The file is chart-managed only while the tenant has not taken it over:
     * absent, or only {"$schema": …} (what OpenCode writes on its first probe) → written;
     * byte-identical to what this script wrote last time (sha256 in the state file) →
       rewritten with the current values (a chart / platform model change propagates);
     * anything else → the tenant's file, never touched.
   A "model" in the tenant's ~/.config/opencode/opencode.json or config.json also wins:
   the managed file then carries no model.
   The model is written only when an OpenRouter key is configured (an openrouter/… model
   cannot run without one).

2. /app/.od/app-config.json — the server-side default agent every browser starts with.
   Desired agent: agentDefaults.defaultAgent, or for "auto": claude when Claude can run
   (ANTHROPIC_API_KEY set, or a `claude login` on od-home), else opencode when an
   OpenRouter key is set, else nothing is changed (claude + the /console/ login is then
   the only way in anyway) — except when this script itself had set opencode earlier and the
   OpenRouter key is gone: then claude (the upstream default) is put back (AI-OD-004-1).
   agentId is replaced only when it is
     * missing / null (fresh instance: also marks onboarding done, so the first page is
       the design home instead of upstream's cloud sign-up),
     * "amr" (OpenDesign Cloud — never installed here; "switch to Cloud" stored it),
     * "claude" while Claude cannot run (the upstream default that failed every run), or
     * still the value this script set last time (the tenant has not picked another
       agent since — so adding an Anthropic key later switches the default to Claude).
   Any other choice of the tenant is kept.

State (no secrets): /app/.od/.woow-agent-defaults.json. Best effort: every failure is
logged and the script exits 0 — a cosmetic default must never block the daemon.
"""
import hashlib
import json
import os
import re
import sys
import tempfile

DATA = os.environ.get("OD_DATA_PATH", "/app/.od")
HOME = os.environ.get("OD_HOME_PATH", "/home/opendesign")
STATE = os.path.join(DATA, ".woow-agent-defaults.json")
APP_CONFIG = os.path.join(DATA, "app-config.json")
OC_DIR = os.path.join(HOME, ".config", "opencode")
OC_FILE = os.path.join(OC_DIR, "opencode.jsonc")
OC_OTHERS = [os.path.join(OC_DIR, n) for n in ("opencode.json", "config.json")]
SCHEMA = "https://opencode.ai/config.json"

DEFAULT_AGENT = os.environ.get("OD_DEFAULT_AGENT", "auto").strip()
OPENCODE_MODEL = os.environ.get("OD_OPENCODE_MODEL", "").strip()
HAS_ANTHROPIC = bool(os.environ.get("ANTHROPIC_API_KEY", "").strip())
HAS_OPENROUTER = bool(os.environ.get("OPENROUTER_API_KEY", "").strip())


def log(msg):
    print("[agent-defaults] " + msg, flush=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def write_atomic(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".woow-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def strip_jsonc(text):
    """Drop // and /* */ comments outside strings, and trailing commas (enough for the
    trivial files OpenCode writes; anything unparsable counts as the tenant's)."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def parse_jsonc(data):
    try:
        v = json.loads(strip_jsonc(data.decode("utf-8")))
    except Exception:
        return None
    return v if isinstance(v, dict) else None


def load_state():
    raw = read_bytes(STATE)
    if raw is None:
        return {}
    try:
        v = json.loads(raw.decode("utf-8"))
        return v if isinstance(v, dict) else {}
    except Exception:
        return {}


def claude_can_run():
    if HAS_ANTHROPIC:
        return True
    # `claude login` (subscription / console account) stores its credential here.
    return os.path.isfile(os.path.join(HOME, ".claude", ".credentials.json"))


def opencode_config(state):
    current = read_bytes(OC_FILE)
    other_model = False
    for p in OC_OTHERS:
        raw = read_bytes(p)
        cfg = parse_jsonc(raw) if raw is not None else None
        if cfg and "model" in cfg:
            other_model = True
    want = {"$schema": SCHEMA}
    if OPENCODE_MODEL and HAS_OPENROUTER and not other_model:
        want["model"] = OPENCODE_MODEL
    data = (json.dumps(want, indent=2, ensure_ascii=False) + "\n").encode("utf-8")

    if current is None:
        owner = "absent"
    elif sha(current) == state.get("opencodeSha256"):
        owner = "managed"
    else:
        cfg = parse_jsonc(current)
        owner = "trivial" if cfg is not None and set(cfg) <= {"$schema"} else "tenant"
    if owner == "tenant":
        log("opencode.jsonc edited by the tenant — left alone")
        state.pop("opencodeSha256", None)
        return
    if current != data:
        write_atomic(OC_FILE, data)
        log("opencode.jsonc (%s) → model %s" % (owner, want.get("model", "<OpenCode default>")))
    state["opencodeSha256"] = sha(data)


def app_config(state):
    if DEFAULT_AGENT in ("", "none", "keep"):
        return
    if DEFAULT_AGENT == "auto":
        desired = "claude" if claude_can_run() else ("opencode" if HAS_OPENROUTER else None)
    else:
        desired = DEFAULT_AGENT
    if not desired and state.get("agentId") == "opencode":
        # 0.5.1 (AI-OD-004-1): the chart itself switched the default to opencode because an
        # OpenRouter key was set; the key is gone now (cleared), so opencode has nothing to run on.
        # Put the upstream default back (the rule below only fires while the tenant has not picked
        # another agent since — state["agentId"] is dropped as soon as they do).
        desired = "claude"
    if not desired:
        log("no Anthropic / OpenRouter key and no claude login — default agent unchanged")
        return
    raw = read_bytes(APP_CONFIG)
    if raw is None:
        cfg, fresh = {}, True
    else:
        try:
            cfg = json.loads(raw.decode("utf-8"))
        except Exception:
            log("app-config.json is not valid JSON — left alone")
            return
        if not isinstance(cfg, dict):
            log("app-config.json is not an object — left alone")
            return
        fresh = False
    current = cfg.get("agentId")
    reason = None
    if current in (None, ""):
        reason = "unset"
    elif current == "amr":
        reason = "OpenDesign Cloud (not installed)"
    elif current == "claude" and not claude_can_run() and desired != "claude":
        reason = "Claude Code is not signed in"
    elif current == state.get("agentId") and current != desired:
        reason = "chart default, not changed by the tenant"
    if reason:
        cfg["agentId"] = desired
        if fresh:
            cfg["onboardingCompleted"] = True
        write_atomic(APP_CONFIG, (json.dumps(cfg, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
        log("default agent %s → %s (%s)" % (current, desired, reason))
        state["agentId"] = desired
    elif current == desired:
        state["agentId"] = desired
    else:
        log("default agent %s chosen by the tenant — kept" % current)
        state.pop("agentId", None)


def main():
    state = load_state()
    before = dict(state)
    for step in (opencode_config, app_config):
        try:
            step(state)
        except Exception as exc:  # best effort, never block the daemon
            log("WARN: %s failed: %s" % (step.__name__, type(exc).__name__))
    if state != before:
        try:
            write_atomic(STATE, (json.dumps(state, indent=2, sort_keys=True) + "\n").encode("utf-8"))
        except Exception as exc:
            log("WARN: state not saved: %s" % type(exc).__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
