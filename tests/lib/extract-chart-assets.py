#!/usr/bin/env python3
"""Render the chart once and extract the assets the rest of the suite inspects.

Writes into tests/.artifacts/:
  rendered.yaml          the full `helm template` output for tests/values/full.yaml
  rendered-minimal.yaml  the same for tests/values/minimal.yaml (backup disabled)
  nginx.conf             the `nginx.conf` key of the <release>-nginx ConfigMap
  od-export-bridge.js    the `od-export-bridge.js` key of the same ConfigMap

Everything downstream reads the RENDERED objects rather than guessing where the
chart happens to keep its source files. That way this suite validates what
Kubernetes would actually receive, which is exactly the check the old repo
never had: its chart could not even be installed.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolayout as layout  # noqa: E402

import yaml  # noqa: E402

NAMESPACE = "pi-agent-woow"
RELEASE = "od"
VALUES_FULL = layout.ROOT / "tests/values/full.yaml"
VALUES_MINIMAL = layout.ROOT / "tests/values/minimal.yaml"


def helm_template(values: Path) -> str:
    result = subprocess.run(
        [
            "helm", "template", RELEASE, str(layout.CHART),
            "--namespace", NAMESPACE,
            "--values", str(values),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print("=" * 72, file=sys.stderr)
        print(f"helm template FAILED for {values.name}", file=sys.stderr)
        print("=" * 72, file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return result.stdout


def main() -> None:
    layout.require(
        {
            "Chart.yaml": layout.CHART / "Chart.yaml",
            "values.yaml": layout.CHART / "values.yaml",
            "chart templates/": layout.CHART / "templates",
            "tests/values/full.yaml": VALUES_FULL,
            "tests/values/minimal.yaml": VALUES_MINIMAL,
        },
        who="chart asset extraction",
    )
    layout.ARTIFACTS.mkdir(parents=True, exist_ok=True)

    full = helm_template(VALUES_FULL)
    (layout.ARTIFACTS / "rendered.yaml").write_text(full, encoding="utf-8")
    (layout.ARTIFACTS / "rendered-minimal.yaml").write_text(helm_template(VALUES_MINIMAL), encoding="utf-8")

    documents = [doc for doc in yaml.safe_load_all(full) if isinstance(doc, dict)]
    nginx_maps = [
        doc for doc in documents
        if doc.get("kind") == "ConfigMap" and "nginx.conf" in (doc.get("data") or {})
    ]
    if len(nginx_maps) != 1:
        print(
            "ERROR: expected exactly one ConfigMap carrying an `nginx.conf` key, "
            f"found {len(nginx_maps)}",
            file=sys.stderr,
        )
        sys.exit(1)
    data = nginx_maps[0]["data"]
    (layout.ARTIFACTS / "nginx.conf").write_text(data["nginx.conf"], encoding="utf-8")

    bridge = data.get("od-export-bridge.js")
    if not bridge:
        print(
            "ERROR: the nginx ConfigMap has no `od-export-bridge.js` key. The sidecar "
            "must serve the export bridge; see portFromHA section B.",
            file=sys.stderr,
        )
        sys.exit(1)
    (layout.ARTIFACTS / "od-export-bridge.js").write_text(bridge, encoding="utf-8")

    print(f"chart assets extracted into {layout.ARTIFACTS}")
    print(f"  rendered objects: {len(documents)}")


if __name__ == "__main__":
    main()
