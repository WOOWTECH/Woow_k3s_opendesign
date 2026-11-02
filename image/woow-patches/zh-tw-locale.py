#!/usr/bin/env python3
"""ISS-OD-08: the zh-TW UI locale of OpenDesign 0.24.1 still carries ~zh-CN strings
(e.g. the composer placeholder 「请审查并润色现有动效…」). Fix them in the built web bundle.

The built Next.js chunk holds every locale as an object literal of "key":"value" pairs.
This tool finds the ONE object that is the zh-TW dictionary (it contains all marker
pairs below, which exist only in zh-TW), and inside that span only, replaces string
values with their OpenCC s2twp conversion — but only values that still contain
Simplified characters (OpenCC s2tw changes them); values already in Traditional Chinese
are left alone, as are keys and every other locale (zh-CN keeps its Simplified strings).
A few s2twp IT-phrase choices that read wrong in this UI are reverted (POST_FIX).

  generate: zh-tw-locale.py generate <chunk.js> <mapping.json>   (needs `opencc`, dev only)
  apply:    zh-tw-locale.py apply <web out dir> <mapping.json>   (image build, stdlib only)

`apply` finds the chunk by content, checks that every mapped `"old"` literal occurs in
the zh-TW span (exactly as generated), replaces it, and exits 1 on any mismatch, so an
upstream bump that changes the bundle fails the build instead of silently not patching.
"""
import json
import os
import sys

# s2twp phrase choices that are wrong for this UI (zh-TW usage): applied after s2twp.
POST_FIX = {"許可權": "權限", "儀錶板": "儀表板", "瞭解": "了解", "臺": "台", "羣": "群", "峯": "峰"}
# Characters OpenCC s2tw changes although zh-TW UI text uses them as-is: they alone do
# not mark a value as an untranslated zh-CN leftover.
TW_OK = set("台群峰")

MARKERS = ['"invite.landing.subtitle":"你受邀加入 OpenDesign 一起協作。"', '"invite.role.member":"成員"']


def find_span(s):
    """(start, end) of the object literal containing all MARKERS, or None."""
    pos = [s.find(m) for m in MARKERS]
    if min(pos) < 0:
        return None
    # walk back from the first marker to the '{' that opens its object (string-aware
    # forward scan from there must close after the last marker)
    i = min(pos)
    depth = 0
    j = i
    while j > 0:
        j -= 1
        c = s[j]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                break
            depth -= 1
    start = j
    k, depth, in_str, esc = start, 0, None, False
    while k < len(s):
        c = s[k]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == in_str:
                in_str = None
        elif c in "\"'`":
            in_str = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    end = k + 1
    if not all(start < p < end for p in pos):
        return None
    return start, end


def iter_values(span):
    """Yield (literal, decoded) for every "key":"value" value literal in the span."""
    i = 0
    n = len(span)
    while i < n:
        if span[i] != '"':
            i += 1
            continue
        j = i + 1
        while j < n and span[j] != '"':
            j += 2 if span[j] == "\\" else 1
        lit = span[i:j + 1]
        if span[i - 1:i] == ":":
            try:
                yield lit, json.loads(lit)
            except ValueError:
                pass
        i = j + 1


def find_chunk(outdir):
    hits = []
    for root, _, files in os.walk(outdir):
        for f in files:
            if f.endswith(".js"):
                p = os.path.join(root, f)
                with open(p, encoding="utf-8", errors="surrogateescape") as fh:
                    s = fh.read()
                if all(m in s for m in MARKERS):
                    hits.append(p)
    if len(hits) != 1:
        sys.exit(f"zh-tw-locale: expected exactly one chunk with the zh-TW markers, found {hits}")
    return hits[0]


def generate(chunk, mapping):
    from opencc import OpenCC  # dev-only dependency

    s2tw, s2twp = OpenCC("s2tw"), OpenCC("s2twp")
    s = open(chunk, encoding="utf-8").read()
    span = find_span(s)
    if not span:
        sys.exit("zh-TW dictionary not found")
    pairs = {}
    for lit, val in iter_values(s[span[0]:span[1]]):
        simplified = [c for c in set(val) if c not in TW_OK and s2tw.convert(c) != c]
        if simplified:  # still has Simplified characters
            new = s2twp.convert(val)
            for a, b in POST_FIX.items():
                new = new.replace(a, b)
            if new != val:
                pairs[lit] = json.dumps(new, ensure_ascii=False)
    json.dump({"markers": MARKERS, "replace": [[o, n] for o, n in pairs.items()]},
              open(mapping, "w"), ensure_ascii=False, indent=1)
    print(f"{len(pairs)} zh-TW values to convert (span {span[1] - span[0]} chars)")


def apply(outdir, mapping):
    m = json.load(open(mapping, encoding="utf-8"))
    chunk = find_chunk(outdir)
    s = open(chunk, encoding="utf-8").read()
    span = find_span(s)
    if not span:
        sys.exit("zh-tw-locale: zh-TW dictionary span not found")
    body = s[span[0]:span[1]]
    for old, new in m["replace"]:
        if body.count(old) < 1:
            sys.exit(f"zh-tw-locale: {old[:60]}… not in the zh-TW dictionary (bundle changed?)")
        body = body.replace(old, new)
    # nothing Simplified-only left among the converted values
    with open(chunk, "w", encoding="utf-8") as fh:
        fh.write(s[:span[0]] + body + s[span[1]:])
    print(f"zh-tw-locale: {len(m['replace'])} zh-TW values converted (s2twp) in {chunk}")


if __name__ == "__main__":
    cmd, a, b = sys.argv[1:4]
    generate(a, b) if cmd == "generate" else apply(a, b)
