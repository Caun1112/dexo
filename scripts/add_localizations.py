#!/usr/bin/env python3
"""Insert the ReadBoost / share-image strings into dexo/Localizable.xcstrings."""
import json
from collections import OrderedDict

PATH = "dexo/Localizable.xcstrings"

NEW = {
    # --- shared actions -------------------------------------------------
    "action.done": ("Done", "完成"),
    "action.back": ("Back", "返回"),

    # --- ReadBoost ------------------------------------------------------
    "readboost.title": ("ReadBoost", "已读加速"),
    "readboost.section.status": ("Status", "状态"),
    "readboost.section.risk": ("Before you start", "使用前须知"),
    "readboost.section.options": ("Options", "选项"),
    "readboost.section.advanced": ("Advanced", "高级参数"),
    "readboost.footer.advanced": (
        "Faster pacing raises the chance the forum flags the traffic. Change these only if you know what they do.",
        "更激进的节奏更容易被论坛判定为异常流量。除非清楚含义，否则请勿修改。",
    ),
    "readboost.footer.current_position %lld %lld": (
        "Currently at post %1$lld of %2$lld.",
        "当前位置：第 %1$lld / %2$lld 层。",
    ),
    "readboost.risk.body": (
        "ReadBoost reports read timings for every post in this topic without you scrolling through them. This is third-party behaviour the forum may treat as abuse — your account could be rate-limited or suspended. Use it at your own risk.",
        "已读加速会在你没有实际滑动浏览的情况下，为本话题的每一层上报阅读时长。这属于论坛可能判定为滥用的第三方行为，账号有被限制甚至封禁的风险。请自行承担后果。",
    ),
    "readboost.risk.accept": ("I understand, enable it", "我已知晓，启用功能"),
    "readboost.option.auto_start": ("Start automatically", "自动运行"),
    "readboost.option.start_from_current": ("Start from current position", "从当前浏览位置开始"),
    "readboost.option.advanced_mode": ("Advanced settings", "高级设置模式"),
    "readboost.advanced.confirm_title": ("Enable advanced settings?", "启用高级设置？"),
    "readboost.advanced.confirm_message": (
        "Custom pacing can increase the risk to your account.",
        "自定义节奏可能增加账号风险。",
    ),
    "readboost.field.base_delay": ("Base delay (ms)", "基础延迟（毫秒）"),
    "readboost.field.random_delay_range": ("Random delay range (ms)", "随机延迟范围（毫秒）"),
    "readboost.field.min_req_size": ("Min posts per request", "每次请求最小楼层数"),
    "readboost.field.max_req_size": ("Max posts per request", "每次请求最大楼层数"),
    "readboost.field.min_read_time": ("Min read time (ms)", "最小阅读时间（毫秒）"),
    "readboost.field.max_read_time": ("Max read time (ms)", "最大阅读时间（毫秒）"),
    "readboost.action.start": ("Start", "开始执行"),
    "readboost.action.stop": ("Stop", "停止执行"),
    "readboost.action.reset": ("Reset to defaults", "重置为默认值"),
    "readboost.status.already_running": ("ReadBoost is already running", "已读加速正在运行中"),
    "readboost.status.needs_consent": ("Confirm the risk notice first", "请先确认风险提示"),
    "readboost.status.no_posts": ("This topic has no posts to process", "当前话题没有可处理的楼层"),
    "readboost.status.login_required": ("Sign in before using ReadBoost", "请先登录后再使用已读加速"),
    "readboost.status.timings_disabled": (
        "Read-timing uploads are off for this forum. Turn them on in Settings first.",
        "该论坛的阅读上报已关闭，请先在设置中开启。",
    ),
    "readboost.status.starting": ("Starting…", "正在启动…"),
    "readboost.status.stopping": ("Stopping…", "正在停止…"),
    "readboost.status.stopped": ("ReadBoost stopped", "已读加速已停止"),
    "readboost.status.completed": ("ReadBoost finished", "已读加速处理完成"),
    "readboost.status.failed": ("ReadBoost failed", "已读加速执行失败"),
    "readboost.status.processing %lld %lld %lld": (
        "Posts %1$lld–%2$lld (%3$lld%%)",
        "处理楼层 %1$lld–%2$lld（%3$lld%%）",
    ),
    "readboost.status.retrying %lld %lld %lld": (
        "Retrying %1$lld–%2$lld (%3$lld left)",
        "重试 %1$lld–%2$lld（剩余 %3$lld 次）",
    ),
    "readboost.status.progress %lld %lld %lld": (
        "%1$lld%% · %2$lld/%3$lld posts",
        "%1$lld%% · %2$lld/%3$lld 层",
    ),
    "readboost.error.http %lld": ("HTTP %lld", "HTTP %lld"),

    # --- Share as image -------------------------------------------------
    "share_image.title": ("Share as image", "分享为图片"),
    "share_image.action.title": ("Share as image", "分享为图片"),
    "share_image.action.copy": ("Copy", "复制"),
    "share_image.action.save": ("Save", "保存"),
    "share_image.theme.classic": ("Classic", "经典"),
    "share_image.theme.light": ("White", "纯白"),
    "share_image.theme.dark": ("Dark", "深灰"),
    "share_image.theme.black": ("Black", "纯黑"),
    "share_image.theme.blue": ("Blue", "浅蓝"),
    "share_image.theme.green": ("Green", "浅绿"),
    "share_image.option.site": ("Site", "站点"),
    "share_image.option.title": ("Title", "标题"),
    "share_image.option.author": ("Author", "作者"),
    "share_image.option.content": ("Content", "正文"),
    "share_image.option.link": ("Link", "链接"),
    "share_image.copied": ("Image copied", "已复制图片"),
    "share_image.saved": ("Saved to Photos", "已保存到相册"),
    "share_image.save_failed": ("Could not save the image", "保存图片失败"),
    "share_image.save_denied": ("Photos access is required to save", "保存需要相册访问权限"),
    "share_image.empty": ("Nothing selected to show", "没有可显示的内容"),
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    with open(PATH, encoding="utf-8") as handle:
        catalog = json.load(handle, object_pairs_hook=OrderedDict)

    strings = catalog["strings"]
    added, updated = 0, 0
    for key, (en, zh) in NEW.items():
        entry = strings.get(key)
        if entry is None:
            strings[key] = OrderedDict(
                localizations=OrderedDict(en=unit(en), **{"zh-Hans": unit(zh)})
            )
            added += 1
        else:
            localizations = entry.setdefault("localizations", OrderedDict())
            localizations["en"] = unit(en)
            localizations["zh-Hans"] = unit(zh)
            updated += 1

    catalog["strings"] = OrderedDict(sorted(strings.items()))
    with open(PATH, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"added={added} updated={updated} total={len(strings)}")


if __name__ == "__main__":
    main()
