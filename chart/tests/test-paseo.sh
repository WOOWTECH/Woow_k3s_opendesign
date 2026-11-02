#!/usr/bin/env bash
# Include native Paseo Python contracts in the repository's shell-only CI runner.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/test-paseo.py"
python3 "$HERE/test-paseo-nginx.py"
