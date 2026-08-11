#!/usr/bin/env python3
"""Read-timing strings: default-on wording + inline re-enable action."""
import json
from collections import OrderedDict

PATH = "dexo/Localizable.xcstrings"

NEW = {
    "settings.read_timings.reenable": ("Turn back on", "重新开启"),
    "settings.read_timings.auto_disabled.message": (
        "Dexo stopped linux.do read-time reporting after 3 consecutive failures. "
        "Clear the site verification first, then turn it back on.",
        "linux.do 阅读时间上报已连续失败 3 次，Dexo 已自动关闭。请先完成站点验证，再重新开启。",
    ),
    "settings.read_timings.footer": (
        "On by default. Frequent uploads can trip site protection, so after 3 consecutive "
        "failures — including a Cloudflare challenge — Dexo turns this off automatically. "
        "Clearing the challenge from ReadBoost turns it back on.",
        "默认开启。频繁上报可能触发站点防护，连续失败 3 次（包括 Cloudflare 验证/撞盾）后会自动关闭；"
        "在已读加速中过盾后会自动恢复。",
    ),
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    with open(PATH, encoding="utf-8") as handle:
        catalog = json.load(handle, object_pairs_hook=OrderedDict)

    strings = catalog["strings"]
    for key, (en, zh) in NEW.items():
        entry = strings.setdefault(key, OrderedDict())
        localizations = entry.setdefault("localizations", OrderedDict())
        localizations["en"] = unit(en)
        localizations["zh-Hans"] = unit(zh)

    catalog["strings"] = OrderedDict(sorted(strings.items()))
    with open(PATH, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"ok total={len(strings)}")


if __name__ == "__main__":
    main()
