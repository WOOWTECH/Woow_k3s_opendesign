#!/bin/sh
# ISS-OD-01: "Save as PDF" of an OpenDesign deck prints only the active slide.
#
# The fixed deck framework (packages/contracts/src/prompts/deck-framework.ts, the
# DECK_SKELETON_HTML every deck is generated from) hides inactive slides with
#   .slide:not(.active) { display: none !important; }        specificity 0,2,0
# and its @media print block tries to show them again with
#   .slide { display: flex !important; }                      specificity 0,1,0
# which loses. Fix (one rule, inside @media print, after the last-child rule):
#   .slide:not(.active) { display: flex !important; }         0,2,0 and later → wins
# applied wherever the built framework text occurs (daemon contracts dist, web chunks,
# bundled skills/plugins/templates). Same-line append, so line numbers stay put.
# Exits 1 unless the daemon's @open-design/contracts copy was patched.
set -eu
RULE='.slide:last-child { page-break-after: auto; break-after: auto; }'
FIX='.slide:not(.active) { display: flex !important; }'
n=0
for f in $(find /app/apps/daemon/dist /app/apps/daemon/node_modules/.pnpm /app/apps/web/out \
                /app/skills /app/plugins /app/prompt-templates /app/craft -type f \
                \( -name '*.js' -o -name '*.mjs' -o -name '*.html' -o -name '*.md' \) \
                -exec grep -lF "$RULE" {} + 2>/dev/null || true); do
  grep -qF "$RULE $FIX" "$f" && continue
  sed -i 's/\.slide:last-child { page-break-after: auto; break-after: auto; }/& .slide:not(.active) { display: flex !important; }/' "$f"
  grep -qF "$RULE $FIX" "$f"
  echo "deck-print: patched $f"
  n=$((n + 1))
done
C=$(find /app/apps/daemon/node_modules/.pnpm -path '*/@open-design/contracts/dist/index.mjs' | head -n 1)
test -n "$C"
grep -qF "$RULE $FIX" "$C" || { echo "deck-print: $C not patched"; exit 1; }
echo "deck-print: $n file(s) patched"
