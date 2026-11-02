#!/usr/bin/env python3
"""ISS-OD-05 (image export half): "Export as image" (PNG/JPEG/WebP) still showed the
broken-image icon + alt text for project assets (<img src="assets/logo.svg">) after the
baseHref fix, which only covers the PDF / new-tab path (export-basehref.py).

On the web (no desktop host) the image export uses the preview's snapshot bridge
(srcdoc.ts captureSnapshot → syncElementState): it clones the DOM into an SVG
<foreignObject> and rasterises that SVG as an <img>. An SVG used as an image never loads
external resources, and the bridge copies each <img> as its URL (currentSrc), so every
picture of the design is missing from the exported image.

Fix: in syncElementState, a loaded <img> is copied as a data: URL drawn through a canvas
(same-origin project assets do not taint it; a cross-origin image that would taint the
canvas keeps its URL exactly as before), and its srcset is dropped so the data URL wins.
The bridge text is built into TWO places and both get the same edit:
  * the daemon (apps/daemon/dist/**, injected into URL-load previews — the path the UI's
    image export uses), and
  * the web bundle (apps/web/out/**, srcDoc previews).
The edit lives inside a template literal: no backticks, no "${", no backslashes.

  snapshot-inline-img.py <app root, e.g. /app>
Exact-string patch: exits 1 unless the upstream line occurs exactly once in the daemon
dist and exactly once in the web export (and is gone afterwards).
"""
import os
import sys

OLD = "if (tag === 'img' && source.currentSrc) target.setAttribute('src', source.currentSrc);"
NEW = (
    "if (tag === 'img' && source.currentSrc) { var woowSrc = source.currentSrc; try { "
    "if (source.complete && source.naturalWidth > 0 && source.naturalHeight > 0 && woowSrc.slice(0, 5) !== 'data:') { "
    "var woowBox = source.getBoundingClientRect(); "
    "var woowK = Math.min(4096 / source.naturalWidth, 4096 / source.naturalHeight, "
    "Math.max(1, (woowBox.width * (window.devicePixelRatio || 1)) / source.naturalWidth)); "
    "var woowC = document.createElement('canvas'); "
    "woowC.width = Math.max(1, Math.round(source.naturalWidth * woowK)); "
    "woowC.height = Math.max(1, Math.round(source.naturalHeight * woowK)); "
    "woowC.getContext('2d').drawImage(source, 0, 0, woowC.width, woowC.height); "
    "woowSrc = woowC.toDataURL('image/png'); } } catch (_) {} "
    "target.setAttribute('src', woowSrc); if (woowSrc !== source.currentSrc) target.removeAttribute('srcset'); }"
)
MARK = "var woowSrc = source.currentSrc;"
assert "`" not in NEW and "${" not in NEW and "\\" not in NEW


def files(root, exts):
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(exts):
                yield os.path.join(d, f)


def patch(root, exts, label):
    hits = []
    for p in files(root, exts):
        with open(p, encoding="utf-8", errors="surrogateescape") as fh:
            s = fh.read()
        if OLD in s or MARK in s:
            hits.append((p, s))
    if len(hits) != 1 or hits[0][1].count(OLD) != 1:
        sys.exit(f"snapshot-inline-img: {label}: expected the upstream <img> copy line exactly once, "
                 f"found {[(p, s.count(OLD), s.count(MARK)) for p, s in hits]}")
    p, s = hits[0]
    s = s.replace(OLD, NEW)
    with open(p, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(s)
    if OLD in s or s.count(MARK) != 1:
        sys.exit(f"snapshot-inline-img: {label}: {p} not patched")
    print(f"snapshot-inline-img: {label}: <img> inlined as a data URL in {p}")


def main(app):
    patch(os.path.join(app, "apps/daemon/dist"), (".js", ".mjs"), "daemon")
    patch(os.path.join(app, "apps/web/out"), (".js",), "web")


if __name__ == "__main__":
    main(sys.argv[1])
