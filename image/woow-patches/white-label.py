#!/usr/bin/env python3
"""ISS-OD-11: the paid white-label service shows upstream's NPS / CSAT survey (it covers
the preview after a run) and upstream promo links (OpenDesign Cloud sign-in callout,
Discord and @OpenDesignHQ in the nav rail).

Injected into every page of the static web export (apps/web/out/**/*.html), right
after <head>, before any app script runs:
  * the survey's own "retired" flag (localStorage key, apps/web/src/components/
    experience-survey-trigger.ts): isSurveyRetired() is then true, so the survey is
    never armed or shown and nothing is sent;
  * a stylesheet hiding the promo elements by their upstream data-testid, plus the
    survey card's CSS-module class as a second layer;
  * (#1439) the same stylesheet hides the OpenDesign Cloud (AMR / vela) sign-in and
    "switch to Cloud" entry points; white-label-links.py rewrites the links themselves.

  white-label.py <web out dir>
Exits 1 if index.html is not patched or a page has no <head>.
"""
import os
import sys

MARK = "woow-white-label"
INJECT = (
    '<script id="' + MARK + '">try{localStorage.setItem("open-design:experience-survey:v1:retired","1")}catch(e){}</script>'
    '<style id="' + MARK + '-css">'
    '[data-testid="entry-nav-rail-social"],[data-testid="entry-cloud-signin-tip"],'
    '[class*="ExperienceSurvey-module__"],'
    # #1439: OpenDesign Cloud (AMR / vela) entry points — the runtime is not installed here,
    # so sign-in answered 500 "vela binary not found" and "switch to Cloud" set the shared
    # default agent to the unusable amr. Brand icons of the (rewritten) support channels.
    '[data-testid="chat-error-switch-to-cloud"],.settings-cloud-signin-callout,.amr-login-pill,'
    '.onboarding-cloud__primary,'
    '[data-testid="inline-model-switcher-agent-amr"],[data-testid="inline-model-switcher-agent-amr-reminder"],'
    '[data-testid="inline-model-switcher-account-amr-reminder"],[data-testid="inline-model-switcher-account-upgrade"],'
    '[data-support-channel] [class*="channelIcon"]{display:none!important}'
    # :has() in its own rule: a browser without it drops only this rule, not the list above.
    '.agent-card:has(img[src="/agent-icons/amr.svg"]){display:none!important}</style>'
)


def main(outdir):
    n = 0
    for root, _, files in os.walk(outdir):
        for f in files:
            if not f.endswith(".html"):
                continue
            p = os.path.join(root, f)
            s = open(p, encoding="utf-8").read()
            if MARK in s:
                continue
            if s.count("<head>") != 1:
                sys.exit(f"white-label: {p} has {s.count('<head>')} <head> tags")
            open(p, "w", encoding="utf-8").write(s.replace("<head>", "<head>" + INJECT, 1))
            n += 1
    if MARK not in open(os.path.join(outdir, "index.html"), encoding="utf-8").read():
        sys.exit("white-label: index.html not patched")
    print(f"white-label: survey retired + promo links hidden in {n} pages")


if __name__ == "__main__":
    main(sys.argv[1])
