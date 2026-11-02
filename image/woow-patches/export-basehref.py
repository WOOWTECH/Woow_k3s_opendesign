#!/usr/bin/env python3
"""ISS-OD-05: exported PNG/PDF (and the blob preview) lose project-relative assets
(`<img src="logo.svg">` → naturalWidth 0, only the alt text shows).

Upstream apps/web/src/runtime/exports.ts buildBlobSafeSrcdoc() falls back to the SITE
ROOT (`${origin}/`) as <base href> when the caller passes no baseHref — and the export
paths (exportAsPdf fallback, image capture) do not pass one, so `logo.svg` resolves to
`/logo.svg` instead of the project's raw directory. This patch changes ONLY that
fallback in the built web bundle: when the page is a project/file route
(/projects/<id>[/conversations/<cid>][/files/<dir>/<file>]) the base becomes
`${origin}/api/projects/<id>/raw/<dir>/` (exactly what projectRawUrl() builds for the
preview); any other page keeps `${origin}/`. Callers that pass baseHref are unaffected.

  export-basehref.py <web out dir>
Exact-string patch: exits 1 unless the upstream fallback occurs exactly once.
"""
import os
import sys

OLD = 'if("string"==typeof window.location?.origin)return`${window.location.origin.replace(/\\/+$/,"")}/`;'
NEW = ('if("string"==typeof window.location?.origin){let o=window.location.origin.replace(/\\/+$/,""),'
       'm=/^\\/projects\\/([^/]+)(?:\\/conversations\\/[^/]+)?(?:\\/files\\/((?:[^/]+\\/)*)[^/]*)?\\/?$/'
       '.exec(window.location.pathname||"");return m?`${o}/api/projects/${m[1]}/raw/${m[2]||""}`:`${o}/`}')


def main(outdir):
    hits = []
    for root, _, files in os.walk(outdir):
        for f in files:
            if f.endswith(".js"):
                p = os.path.join(root, f)
                s = open(p, encoding="utf-8").read()
                if OLD in s:
                    hits.append((p, s))
    if len(hits) != 1 or hits[0][1].count(OLD) != 1:
        sys.exit(f"export-basehref: expected the upstream baseHref fallback exactly once, found {[(p, s.count(OLD)) for p, s in hits]}")
    p, s = hits[0]
    open(p, "w", encoding="utf-8").write(s.replace(OLD, NEW))
    print(f"export-basehref: project-relative <base href> fallback patched in {p}")


if __name__ == "__main__":
    main(sys.argv[1])
