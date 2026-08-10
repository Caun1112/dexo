#!/usr/bin/env python3
"""Add the long-press action-sheet strings."""
import json
from collections import OrderedDict

PATH = "dexo/Localizable.xcstrings"

NEW = {
    "post.view_raw": ("View source", "查看原文"),
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
