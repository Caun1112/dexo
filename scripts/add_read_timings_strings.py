#!/usr/bin/env python3
"""Add the read-timings settings section strings."""
import json
from collections import OrderedDict

PATH = "dexo/Localizable.xcstrings"

NEW = {
    "settings.section.read_timings": ("Read Tracking", "阅读上报"),
    "readboost.status.timings_disabled": (
        "Read-time reporting is off for this forum. Turn on \"Report read time to linux.do\" under Settings › Read Tracking.",
        "该论坛的阅读上报已关闭。请到「设置 › 阅读上报」中打开「向 linux.do 上报阅读时间」。",
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
