#!/bin/bash
#
# Wanna 保活：**Wanna 没在跑就把它拉起来。**
#
# 由 launchd 每 15 分钟跑一次（~/Library/LaunchAgents/com.nash-aigc.clicky-keepalive.plist）。
# 文件名和 launchd label 里的 "clicky" 是内部标识符，跟通知名、UserDefaults key
# 一样保持不动 —— 改它们要连 plist 一起动并重载 launchd，零收益。
#
# ## 为什么找两个地方
#
# 开发期的 Wanna 跑在 DerivedData 里，而那个目录名带一段由**项目路径**算出来的哈希
# —— 项目路径不变它就稳定，但 `DerivedData` 被清过之后就会变。所以这里优先用
# `/Applications/Wanna.app`（正式版），找不到再回落到 DerivedData 里
# **最新的那一个**。只认一个路径的话，清理一次 DerivedData 守护就永久失效，
# 而且它是静默失效的 —— 用户只会发现"怎么又没了"。
#
# ## launchd 的环境很窄
#
# 这里每条命令都写绝对路径、不依赖 PATH、不 `cd`。`~` 也不展开成用户目录，
# 所以下面全部写成 /Users/mjm/...。

APP_NAME="Wanna"
LOG_TAG="clicky-keepalive"

# 已经在跑就什么都不做。
if /usr/bin/pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    exit 0
fi

# 找一个能打开的 .app，新的优先。
for candidate in \
    "/Applications/Wanna.app" \
    "$(/bin/ls -dt /Users/mjm/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Wanna.app 2>/dev/null | /usr/bin/head -1)"
do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
        /usr/bin/open "$candidate"
        /usr/bin/logger -t "$LOG_TAG" "Wanna 没在跑，已从 $candidate 拉起"
        exit 0
    fi
done

# 找不到任何构建产物 —— 留一条日志，否则这就是一次静默失败。
/usr/bin/logger -t "$LOG_TAG" "Wanna 没在跑，而且找不到任何 Wanna.app（DerivedData 被清过？）"
exit 1
