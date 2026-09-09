#!/usr/bin/env python3
"""Static least-privilege and immutable-release checks for the CI workflow.

Ported from the HA add-on. Differences, all deliberate:
  * no arm64 leg and no QEMU step — every woow-k3s node reports amd64
  * the release version comes from chart/Chart.yaml `version`, not config.yaml
  * publish-release also pushes the packaged chart as an OCI artifact
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import repolayout as layout  # noqa: E402

import yaml  # noqa: E402

WORKFLOW_PATH = layout.ROOT / ".github/workflows/build.yml"
PREFLIGHT_PATH = layout.ROOT / ".github/scripts/release-preflight.sh"

layout.require(
    {".github/workflows/build.yml": WORKFLOW_PATH, ".github/scripts/release-preflight.sh": PREFLIGHT_PATH},
    who="workflow policy validation",
)

workflow_text = WORKFLOW_PATH.read_text(encoding="utf-8")
workflow = yaml.safe_load(workflow_text)
preflight_text = PREFLIGHT_PATH.read_text(encoding="utf-8")
errors: list[str] = []


def check(condition, message: str) -> None:
    if not condition:
        errors.append(message)


jobs = workflow.get("jobs", {})
required_jobs = {"validate", "smoke", "build-nonrelease", "release-preflight", "release-architecture-gate", "publish-release"}
check(required_jobs <= set(jobs), f"workflow must define {sorted(required_jobs)}; found {sorted(jobs)}")
check(workflow.get("permissions") == {"contents": "read"}, "workflow default permissions must be contents:read only")

package_writers = [name for name, job in jobs.items() if job.get("permissions", {}).get("packages") == "write"]
check(package_writers == ["publish-release"], f"only publish-release may receive packages:write; got {package_writers}")
for name in {"validate", "smoke", "build-nonrelease", "release-architecture-gate"}:
    check(jobs.get(name, {}).get("permissions") == {"contents": "read"}, f"{name} must explicitly have only contents:read")

validate_job = jobs.get("validate", {})
validate_run = "\n".join(str(step.get("run", "")) for step in validate_job.get("steps", []))
check("tests/run.sh" in validate_run, "the validate job must run the same local gate developers run")

smoke = jobs.get("smoke", {})
smoke_text = yaml.safe_dump(smoke)
smoke_run = "\n".join(str(step.get("run", "")) for step in smoke.get("steps", []))
check("load: true" in smoke_text and "push: false" in smoke_text, "the smoke job must build locally and never push")
check("tests/container-smoke.sh" in smoke_run, "the smoke job must run the real container smoke")

nonrelease = jobs.get("build-nonrelease", {})
nonrelease_text = yaml.safe_dump(nonrelease)
check("github.ref_type != 'tag'" in str(nonrelease.get("if", "")), "non-release builds must exclude tags")
check(set(nonrelease.get("needs", [])) == {"validate", "smoke"}, "non-release builds must require validation and smoke")
check("push: false" in nonrelease_text, "non-release builds must never push")
check("docker/login-action" not in nonrelease_text, "non-release builds must not receive registry credentials")

preflight = jobs.get("release-preflight", {})
preflight_job_text = yaml.safe_dump(preflight)
check("github.ref_type == 'tag'" in str(preflight.get("if", "")), "release preflight must run only for tags")
check(set(preflight.get("needs", [])) == {"validate", "smoke"}, "release preflight must require validation and smoke")
check(preflight.get("permissions") == {"contents": "read", "packages": "read"}, "release preflight must have read-only contents/package access")
check("./.github/scripts/release-preflight.sh" in preflight_job_text, "release preflight job must invoke the immutable-release check")
check("GHCR_TOKEN" in preflight_job_text, "release preflight must authenticate its read-only registry query")

release_gate = jobs.get("release-architecture-gate", {})
release_gate_job_text = yaml.safe_dump(release_gate)
release_gate_run_text = "\n".join(str(step.get("run", "")) for step in release_gate.get("steps", []))
check("github.ref_type == 'tag'" in str(release_gate.get("if", "")), "release architecture gate must run only for tags")
check(set(release_gate.get("needs", [])) == {"validate", "smoke", "release-preflight"}, "release architecture gate must wait for validation, smoke, and release preflight")
check(release_gate.get("permissions") == {"contents": "read"}, "release architecture gate must have only contents:read")
check("push: false" in release_gate_job_text and "load: true" in release_gate_job_text, "release architecture gate must build local images without publishing")
check(("linux/amd64" in release_gate_job_text or "BUILD_PLATFORM" in release_gate_job_text), "release architecture gate must build amd64")
check("linux/arm64" not in release_gate_job_text, "arm64 is not a build target for this cluster")
check("setup-qemu-action" not in workflow_text, "single-architecture builds need no QEMU")
for needle, message in [
    ('test "$(id -u)" = 1001', "release architecture gate must execute OpenCode as UID 1001"),
    ('test "$(opencode --version)" = 1.18.29', "release architecture gate must verify the exact locked OpenCode version"),
    ("container-opencode-byok-e2e.mjs", "release architecture gate must run the native BYOK streaming mock"),
    ("fake BYOK key leaked to container logs", "release architecture gate must reject BYOK key log leakage"),
    ("fake BYOK key leaked to /data persisted artifacts", "release architecture gate must reject BYOK key persistence"),
]:
    check(needle in release_gate_run_text, message)

publish = jobs.get("publish-release", {})
publish_text = yaml.safe_dump(publish)
publish_run = "\n".join(str(step.get("run", "")) for step in publish.get("steps", []))
check("github.ref_type == 'tag'" in str(publish.get("if", "")), "publishing must run only for tags")
check(
    set(publish.get("needs", [])) == {"validate", "smoke", "release-preflight", "release-architecture-gate"},
    "publishing must wait for validation, smoke, release preflight, and the release architecture gate",
)
check(publish.get("permissions") == {"contents": "read", "packages": "write"}, "release publisher must have only contents:read and packages:write")
check("push: true" in publish_text, "release publisher must explicitly push")
check("docker/login-action" in publish_text, "release publisher must authenticate to GHCR")
check("helm push" in publish_run and ("oci://ghcr.io/woowtech/charts" in publish_run or "CHART_OCI_REPOSITORY" in publish_run), "release publisher must publish the packaged chart as an OCI artifact")

for needle, message in [
    ("Chart.yaml", "preflight must derive the release version from the chart"),
    ('expected="v${version}"', "preflight must derive the exact release tag from the chart version"),
    ('"${GITHUB_REF_NAME:-}" != "$expected"', "preflight must reject a non-matching release tag"),
    ("woowtech/woow-k3s-opendesign", "preflight must inspect the GHCR image this repo publishes"),
    ('--user "${GHCR_ACTOR}:${GHCR_TOKEN}"', "preflight must use its read-only token so private existing tags cannot be missed"),
    ("--request GET", "preflight must use a GET that works around GHCR HTTP/2 HEAD framing"),
    ('case "$status" in', "preflight must classify the registry response"),
    ("404)", "preflight may proceed only when the manifest is absent"),
    ("200)", "preflight must reject an existing manifest"),
    ("Registry returned HTTP", "preflight must fail closed on unexpected registry responses"),
]:
    check(needle in preflight_text, message)
check("aarch64" not in preflight_text, "preflight must not query an architecture that is never built")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)
print("workflow release policy validation: OK")
