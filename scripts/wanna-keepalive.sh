#!/bin/bash
#
# Wanna 保活：**Wanna 没在跑就把它拉起来。**
#
# 由 launchd 每 15 分钟跑一次（~/Library/LaunchAgents/com.nash-aigc.wanna-keepalive.plist）。
#
# label、脚本名、LOG_TAG、日志文件是一套的：改其中任何一个都要连 plist 一起改并
# **重载 launchd**。只改文件不重载，job 会继续按旧参数跑，而且是**静默失效** ——
# 用户只会发现「怎么又没了」，不会看到任何报错。
#
# ## 唯一一处无法避免的绝对路径
#
# plist 里那个脚本路径只能写绝对 —— launchd 的 ProgramArguments 不接受相对路径，
# 这是协议要求的，没有绕法。除此之外本脚本**不写死任何绝对路径**：用户目录从
# $HOME 推（launchd 的 gui 域会设），推不出来才从用户名推；checkout 位置从脚本
# 自己的位置推。这样改仓库名、改用户名都不用动这个文件。
#
# ## 为什么找两个地方
#
# 开发期的 Wanna 跑在 DerivedData 里，而那个目录名带一段由**项目路径**算出来的哈希
# —— 项目路径不变它就稳定，但 `DerivedData` 被清过之后就会变。所以这里优先用
# `/Applications/Wanna.app`（正式版），找不到再回落到 DerivedData 里
# **最新的那一个**。只认一个路径的话，清理一次 DerivedData 守护就永久失效。
#
# ## launchd 的环境很窄
#
# 不依赖 PATH、不 `cd`，系统命令全写绝对路径。`~` 在 launchd 下不一定展开成用户目录，
# 所以用 $HOME。

APP_NAME="Wanna"
LOG_TAG="wanna-keepalive"

# launchd 的 gui 域会设 HOME；万一没有，从当前用户名推。
USER_HOME="${HOME:-/Users/$(/usr/bin/id -un)}"

# 已经在跑就什么都不做。
if /usr/bin/pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    exit 0
fi

# 找一个能打开的 .app，新的优先。
for candidate in \
    "/Applications/Wanna.app" \
    "$(/bin/ls -dt "$USER_HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/Wanna.app 2>/dev/null | /usr/bin/head -1)"
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
