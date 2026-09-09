#!/usr/bin/env python3
"""Resolve the Woow_k3s_opendesign repository layout for the test suite.

Every test in this suite runs against files produced by other components of the
rewrite. When one of those files is missing the suite must say so *loudly* and
distinctly, never quietly pass. Missing input therefore exits 2 with a banner;
a real validation failure exits 1.

Environment overrides (all optional):
  REPO_ROOT   repository root                     (default: parent of tests/)
  CHART_DIR   Helm chart directory                (default: <root>/chart, else <root>)
  OPT_DIR     runtime script dir inside rootfs/   (default: rootfs/opt/woow-opendesign)
  LAUNCHER    PID-1 launcher script               (default: rootfs/usr/local/bin/k3s-opendesign)
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

MISSING_INPUT_EXIT = 2

ROOT = Path(os.environ.get("REPO_ROOT") or Path(__file__).resolve().parents[2]).resolve()


def _chart_dir() -> Path:
    override = os.environ.get("CHART_DIR")
    if override:
        return (ROOT / override).resolve() if not Path(override).is_absolute() else Path(override).resolve()
    for candidate in (ROOT / "chart", ROOT):
        if (candidate / "Chart.yaml").is_file():
            return candidate.resolve()
    return (ROOT / "chart").resolve()


CHART = _chart_dir()
OPT_DIR = ROOT / os.environ.get("OPT_DIR", "rootfs/opt/woow-opendesign")
LAUNCHER = ROOT / os.environ.get("LAUNCHER", "rootfs/usr/local/bin/k3s-opendesign")
ARTIFACTS = ROOT / "tests" / ".artifacts"

# Paths every lane depends on. Keys are the labels printed in the banner.
REQUIRED = {
    "Chart.yaml": CHART / "Chart.yaml",
    "values.yaml": CHART / "values.yaml",
    "chart templates/": CHART / "templates",
    "Dockerfile": ROOT / "Dockerfile",
    "launcher": LAUNCHER,
    "headless-entry.mjs": OPT_DIR / "headless-entry.mjs",
    "headless-renderer.mjs": OPT_DIR / "headless-renderer.mjs",
    "runtime/package.json": ROOT / "runtime/package.json",
    "runtime/package-lock.json": ROOT / "runtime/package-lock.json",
    "runtime/opencode/package.json": ROOT / "runtime/opencode/package.json",
    "runtime/opencode/package-lock.json": ROOT / "runtime/opencode/package-lock.json",
    ".github/workflows/build.yml": ROOT / ".github/workflows/build.yml",
    ".github/scripts/release-preflight.sh": ROOT / ".github/scripts/release-preflight.sh",
}


def missing(paths: dict[str, Path] | None = None) -> list[str]:
    paths = REQUIRED if paths is None else paths
    return [f"{label}: {path}" for label, path in paths.items() if not path.exists()]


def require(paths: dict[str, Path] | None = None, who: str = "test suite") -> None:
    """Abort with exit 2 and a loud banner when a component has not been staged."""
    absent = missing(paths)
    if not absent:
        return
    print("=" * 72, file=sys.stderr)
    print(f"MISSING INPUT — {who} cannot run", file=sys.stderr)
    print("=" * 72, file=sys.stderr)
    print(f"repo root : {ROOT}", file=sys.stderr)
    print(f"chart dir : {CHART}", file=sys.stderr)
    print(f"opt dir   : {OPT_DIR}", file=sys.stderr)
    print("These required paths do not exist:", file=sys.stderr)
    for item in absent:
        print(f"  - {item}", file=sys.stderr)
    print(
        "\nThis is NOT a pass. Another component of the rewrite has not produced\n"
        "these files yet, or the layout differs. Override with REPO_ROOT /\n"
        "CHART_DIR / OPT_DIR / LAUNCHER if the layout is intentionally different.",
        file=sys.stderr,
    )
    sys.exit(MISSING_INPUT_EXIT)


def describe() -> str:
    return f"REPO_ROOT={ROOT} CHART_DIR={CHART} OPT_DIR={OPT_DIR} LAUNCHER={LAUNCHER}"


def strip_comments(text: str) -> str:
    """Remove `#` comments while respecting quoted strings.

    Used before scanning for forbidden literals so that a comment which
    *explains* why a value is absent ("`latest` is rejected") does not itself
    trip the check, while a real value still does.
    """
    out = []
    for line in text.splitlines():
        quote = None
        cut = None
        index = 0
        while index < len(line):
            char = line[index]
            if quote:
                if char == "\\":
                    index += 2
                    continue
                if char == quote:
                    quote = None
            elif char in "\"'":
                quote = char
            elif char == "#" and (index == 0 or line[index - 1] in " \t"):
                cut = index
                break
            index += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


if __name__ == "__main__":
    print(describe())
    absent = missing()
    if absent:
        require()
    print("layout: OK")


def render_chart(release: str = "opendesign", values: "Path | None" = None) -> str:
    """`helm template` the chart and return the rendered manifests.

    Returns "" when helm is unavailable so callers can report a loud SKIP;
    raises RuntimeError when helm exists but the render fails, because that is
    a real chart defect rather than a missing tool.
    """
    import shutil
    import subprocess

    if not shutil.which("helm"):
        return ""
    # Default to the chart's own realistic fixture. The chart hard-requires
    # publicUrl (an NPM-fronted origin), so a bare `helm template` fails by
    # design -- that guard is the point, not a bug to work around.
    if values is None:
        default_values = CHART / "ci" / "full-values.yaml"
        if default_values.is_file():
            values = default_values
    cmd = ["helm", "template", release, str(CHART)]
    if values is not None:
        cmd += ["-f", str(values)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"helm template failed:\n{proc.stderr.strip()}")
    return proc.stdout
