#!/usr/bin/env python3
"""#1439 (R8): white label, round 2 — upstream support / community / cloud entry points.

white-label.py (ISS-OD-11) hides the upstream promo elements with CSS. These edits change
what the built JS actually does, so a hidden element can no longer send a tenant to
upstream either:

  * "Contact us" (run error card) offered upstream's Feishu community and Discord.
    The two channels become WoowTech's: support@woowtech.io and /_woow/support (a
    same-origin redirect the chart's auth proxy answers with whiteLabel.supportUrl, so
    the target can change without a new image).
  * "Switch to OpenDesign Cloud" silently PUT agentId=amr (the upstream cloud runtime,
    never installed here) into the shared app config. The App no longer hands the
    project view a cloud-switch callback (the button is hidden by CSS as well).
  * The remaining upstream links (Discord, @OpenDesignHQ, support@open-design.ai) in
    the nav rail / settings menu point at WoowTech instead.
  * The "{agent} is not signed in" error text tells the tenant where to sign in on this
    platform (the built-in CLI Terminal plugin on the Plugins page, which opens /console/,
    or an API key in the WoowTech service settings) or to switch to OpenCode — upstream's
    text only said "sign in first".

Each edit is an exact-text / anchored-regex edit of the built chunks that FAILS the
build when its target no longer matches the expected number of times (an upstream bump
must re-check them). Source maps (*.map) are left alone (they are not executed).

  white-label-links.py <web out dir>
"""
import os
import re
import sys

SUPPORT_PATH = "/_woow/support"
SUPPORT_MAIL = "mailto:support@woowtech.io"

# (name, regex, replacement (str or callable), exact number of matches in ONE chunk)
SINGLE_CHUNK_EDITS = [
    (
        "support dialog channels → WoowTech",
        re.compile(
            r'channels:\[\{id:"feishu",name:([\w$]+)\("chat\.support\.channel\.feishu"\),'
            r'href:"https://applink\.feishu\.cn/[^"]*",icon:\(0,[\w$]+\.jsx\)\([\w$]+,\{\}\)\},'
            r'\{id:"discord",name:[\w$]+\("chat\.support\.channel\.discord"\),'
            r'href:"https://discord\.gg/[^"]*",icon:\(0,[\w$]+\.jsx\)\([\w$]+,\{\}\)\}\]'
        ),
        lambda m: (
            'channels:[{id:"woow-mail",name:%s("chat.support.channel.feishu"),href:"%s",icon:null},'
            '{id:"woow-support",name:%s("chat.support.channel.discord"),href:"%s",icon:null}]'
            % (m.group(1), SUPPORT_MAIL, m.group(1), SUPPORT_PATH)
        ),
        1,
    ),
    (
        "no cloud-switch callback for the project view",
        re.compile(r"onSwitchToCloud:[\w$]+,onAgentModelChange:"),
        "onSwitchToCloud:void 0,onAgentModelChange:",
        1,
    ),
]

# Literal replacements over every chunk; each must hit at least once in total.
LITERALS = [
    ("https://discord.gg/mHAjSMV6gz", SUPPORT_PATH),
    ("https://x.com/OpenDesignHQ", SUPPORT_PATH),
    ("mailto:support@open-design.ai", SUPPORT_MAIL),
]

ZH_TW = ("WoowTech 客服信箱", "WoowTech 服務中心", "前往")
ZH_CN = ("WoowTech 客服邮箱", "WoowTech 服务中心", "前往")
OTHER = ("WoowTech support e-mail", "WoowTech help center", "Open")

SIGN_IN = {
    # zh-TW (after zh-tw-locale.py), zh-CN, en
    "請先完成 {agent} 的登入，再重新嘗試。":
        "請到「外掛」頁開啟內建的「CLI 終端機」登入 {agent}（Claude 請執行 claude login），"
        "或到 WoowTech 平台的服務設定填入 API Key；也可以到「設定 → 模型與供應商」改用 OpenCode。",
    "请先完成 {agent} 的登录，再重新尝试。":
        "请到「插件」页打开内置的「CLI 终端」登录 {agent}（Claude 请运行 claude login），"
        "或到 WoowTech 平台的服务设置填入 API Key；也可以到「设置 → 模型与供应商」改用 OpenCode。",
}


def locale_of(feishu_label):
    if feishu_label == "飛書社群":
        return ZH_TW
    if feishu_label == "飞书社群":
        return ZH_CN
    return OTHER


def main(outdir):
    chunks = os.path.join(outdir, "_next", "static", "chunks")
    files = sorted(os.path.join(chunks, f) for f in os.listdir(chunks) if f.endswith(".js"))
    src = {p: open(p, encoding="utf-8").read() for p in files}
    new = dict(src)
    log = []

    for name, rx, repl, want in SINGLE_CHUNK_EDITS:
        hits = [(p, len(rx.findall(s))) for p, s in new.items()]
        hits = [(p, n) for p, n in hits if n]
        if len(hits) != 1 or hits[0][1] != want:
            sys.exit(f"white-label-links: '{name}': expected {want} match in one chunk, got {hits}")
        p = hits[0][0]
        new[p] = rx.sub(repl, new[p])
        log.append(f"{name}: {os.path.basename(p)}")

    for old, rep in LITERALS:
        total = 0
        for p in new:
            n = new[p].count(old)
            if n:
                new[p] = new[p].replace(old, rep)
                total += n
        if not total:
            sys.exit(f"white-label-links: '{old}' not found in any chunk")
        log.append(f"{old} → {rep}: {total}")

    # i18n dictionaries: the channel names sit next to each other in every locale, so the
    # locale is told by the Feishu label (zh-TW / zh-CN get their own text, the rest English).
    pair = re.compile(r'"chat\.support\.channel\.feishu":"([^"]*)","chat\.support\.channel\.discord":"[^"]*"')
    join = re.compile(r'"chat\.support\.title":"([^"]*)","chat\.support\.join":"[^"]*"')
    n_pair = n_join = 0
    zh_tw_seen = False
    for p in new:
        s = new[p]
        if "chat.support.channel.feishu" not in s or '"chat.support.channel.feishu":"' not in s:
            continue

        def pair_sub(m):
            nonlocal zh_tw_seen
            loc = locale_of(m.group(1))
            zh_tw_seen = zh_tw_seen or loc is ZH_TW
            return '"chat.support.channel.feishu":"%s","chat.support.channel.discord":"%s"' % loc[:2]

        def join_sub(m):
            title = m.group(1)
            label = ZH_TW[2] if title in ("聯絡支援", "联系支持") else OTHER[2]
            return '"chat.support.title":"%s","chat.support.join":"%s"' % (title, label)

        s, a = pair.subn(pair_sub, s)
        s, b = join.subn(join_sub, s)
        n_pair += a
        n_join += b
        for old, rep in SIGN_IN.items():
            k = s.count('"chat.runError.signInMessage.other":"%s"' % old)
            if k:
                s = s.replace('"chat.runError.signInMessage.other":"%s"' % old,
                              '"chat.runError.signInMessage.other":"%s"' % rep)
                log.append(f"sign-in hint ({old[:6]}…): {k}")
        new[p] = s
    if n_pair < 3 or not zh_tw_seen:
        sys.exit(f"white-label-links: support channel labels: {n_pair} locales (zh-TW seen: {zh_tw_seen})")
    if n_join < 3:
        sys.exit(f"white-label-links: support join label: {n_join} locales")
    log.append(f"support labels: {n_pair} locales, join label: {n_join} locales")
    for old in SIGN_IN:
        if not any(SIGN_IN[old] in s for s in new.values()):
            sys.exit(f"white-label-links: sign-in hint not applied for '{old}'")

    # Nothing upstream left to send a tenant to.
    for bad in ("applink.feishu.cn", "discord.gg/mHAjSMV6gz", "x.com/OpenDesignHQ", "support@open-design.ai"):
        left = [os.path.basename(p) for p, s in new.items() if bad in s]
        if left:
            sys.exit(f"white-label-links: '{bad}' still in {left}")

    for p, s in new.items():
        if s != src[p]:
            open(p, "w", encoding="utf-8").write(s)
    print("white-label-links: " + "; ".join(log))


if __name__ == "__main__":
    main(sys.argv[1])
