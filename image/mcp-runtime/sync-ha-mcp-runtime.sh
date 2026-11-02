#!/usr/bin/env bash
# Re-copy the HA add-on's built-in MCP runtime into ha/ (the ONLY source of the MCP gateway, tool surface, defaults
# and protections of the PaaS open-design image: the PaaS runs the same code as the HA add-on).
#
#   open-design/mcp-runtime/sync-ha-mcp-runtime.sh <Woow_ha_opendesign_add_on clone> <full commit sha>
#
# Copies `mcp-runtime/` of WOOWTECH/Woow_ha_opendesign_add_on at <sha> with `git archive` (tracked files only, so
# nothing from the clone's working tree can enter), except tests/e2e/ (the HA container proof; the PaaS has its own
# in ../tests/e2e/), then writes HA_SOURCE.json with the source commit and the sha256 of every copied file.
# Never edit ha/ by hand: PaaS-only behaviour lives in paas_opendesign_mcp/. Review the diff of ha/ and HA_SOURCE.json.
set -Eeuo pipefail

if (( $# != 2 )); then
  echo "usage: $0 <Woow_ha_opendesign_add_on clone> <full commit sha>" >&2
  exit 64
fi
src=$1
commit=$2
here=$(cd "$(dirname "$0")" && pwd)
if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
  echo "commit must be a full 40-hex sha" >&2
  exit 64
fi
git -C "$src" cat-file -e "$commit^{commit}"
git -C "$src" cat-file -e "$commit:mcp-runtime/ha_opendesign_mcp/runtime.py"

rm -rf "$here/ha"
mkdir -p "$here/ha"
git -C "$src" archive --format=tar "$commit" -- mcp-runtime | tar -x -C "$here/ha" --strip-components=1
rm -rf "$here/ha/tests/e2e"
find "$here/ha" -name __pycache__ -prune -exec rm -rf {} +

python3 - "$here" "$commit" <<'PY'
import hashlib, json, pathlib, sys
here, commit = pathlib.Path(sys.argv[1]), sys.argv[2]
root = here / 'ha'
files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in sorted(root.rglob('*')) if p.is_file()}
manifest = {
    'source_repository': 'https://github.com/WOOWTECH/Woow_ha_opendesign_add_on',
    'source_path': 'mcp-runtime',
    'source_commit': commit,
    'excluded': ['tests/e2e'],
    'note': 'Pinned copy of the HA add-on built-in MCP runtime; never edit ha/ by hand. Re-run sync-ha-mcp-runtime.sh.',
    'files': files,
}
(here / 'HA_SOURCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('copied %d files of mcp-runtime from %s' % (len(files), commit))
PY
python3 "$here/tests/verify_ha_copy.py"
