#!/usr/bin/env python3
"""prune-orphan-runs — drop agent-run records whose project no longer exists (AI-OD-007-6).

Runs in the `prune-runs` initContainer (daemon image, uid 1001, od-data mounted) on EVERY pod
start, BEFORE the daemon: nothing writes to <data>/runs while it runs, and the daemon indexes
that directory when it starts, so a record removed here never comes back.

Background: the daemon stores one record per agent run in <data>/runs/<runId>/state.json
(user prompt, error text, artifact paths, ...) and never deletes it. Deleting a project
leaves its runs readable through GET /api/runs/<id> and listed again after every restart —
prompts of a project the user deleted stay on the volume forever. The proper fix is in the
daemon (project delete -> drop its runs); until then this removes the leftovers at the next
start. A run of a project deleted while the pod is up stays readable until that start.

A run directory is removed only when ALL of these hold:
  * its state.json parses and has a non-empty string `projectId`;
  * that id is NOT a row of the daemon database (projects / workspace_projects);
  * <data>/projects/<projectId> does NOT exist.
Any doubt leaves everything untouched: no database, a database that cannot be read, a query
error, a run without projectId (not tied to a project), an unreadable state.json, a name that
is not a plain directory name, a symlink. Best effort — every failure is logged and the
script exits 0, a cleanup must never block the daemon. It prints counts only, never a
prompt, a path or an id.

Env: OD_DATA_PATH (default /app/.od), OD_RUNS_PRUNE_DRY_RUN=true (log, delete nothing).
"""
import json
import os
import re
import shutil
import sqlite3
import sys

DATA = os.environ.get("OD_DATA_PATH", "/app/.od")
DRY = os.environ.get("OD_RUNS_PRUNE_DRY_RUN", "").strip().lower() in ("1", "true", "yes")
RUNS = os.path.join(DATA, "runs")
PROJECTS = os.path.join(DATA, "projects")
DIAG = os.path.join(DATA, "diagnostics")
DB = os.path.join(DATA, "app.sqlite")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def log(msg):
    print("[prune-runs] " + msg, flush=True)


def known_project_ids():
    """Ids of every project the daemon database knows, or None when that cannot be determined."""
    if not os.path.isfile(DB):
        return None
    uri = "file:%s?mode=ro" % DB.replace("?", "%3f").replace("#", "%23")
    con = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        ids = {r[0] for r in con.execute("SELECT id FROM projects") if isinstance(r[0], str)}
        try:
            ids |= {r[0] for r in con.execute("SELECT project_id FROM workspace_projects") if isinstance(r[0], str)}
        except sqlite3.Error:
            pass  # the table is optional; `projects` above is the authority
        return ids
    finally:
        con.close()


def run_project_id(state_path):
    try:
        with open(state_path, "rb") as f:
            state = json.loads(f.read().decode("utf-8"))
    except Exception:
        return None
    pid = state.get("projectId") if isinstance(state, dict) else None
    return pid if isinstance(pid, str) and pid else None


def main():
    if not os.path.isdir(RUNS):
        log("no runs directory — nothing to do")
        return 0
    try:
        ids = known_project_ids()
    except Exception as exc:
        log("WARN: project list unreadable (%s) — nothing removed" % type(exc).__name__)
        return 0
    if ids is None:
        log("no daemon database yet — nothing removed")
        return 0

    seen = orphan = removed = failed = 0
    for entry in os.scandir(RUNS):
        if not entry.is_dir(follow_symlinks=False) or not SAFE_NAME.match(entry.name):
            continue
        seen += 1
        pid = run_project_id(os.path.join(entry.path, "state.json"))
        if pid is None or pid in ids:
            continue
        # An id that is not a plain name could point anywhere: doubt -> keep.
        if not SAFE_NAME.match(pid):
            continue
        # Second, independent witness: the project's own directory.
        if os.path.lexists(os.path.join(PROJECTS, pid)):
            continue
        orphan += 1
        if DRY:
            continue
        try:
            shutil.rmtree(entry.path)
            diag = os.path.join(DIAG, entry.name)
            if os.path.isdir(diag) and not os.path.islink(diag):
                shutil.rmtree(diag, ignore_errors=True)
            removed += 1
        except Exception:
            failed += 1
    log("runs=%d orphan=%d removed=%d failed=%d%s" % (seen, orphan, removed, failed, " (dry run)" if DRY else ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # best effort, never block the daemon
        log("WARN: %s — nothing more removed" % type(exc).__name__)
        sys.exit(0)
