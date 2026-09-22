# 14 - Agent 子系统：本机 Claude Code 当多 Agent 运行时

> 写于 2026-09-22。参照项目：`/Users/mjm/Desktop/HeyClicky-Reversed/README/03-多Agent运行时.md`（它用 codex 子进程 + JSON-RPC）。本项目的等价形态是 **claude CLI 的 stream-json 常驻子进程**，不需要自己实现 JSON-RPC。

## 一、架构一页话

一个 Agent = **一条 `AgentSession` 记录 + 一个 claude CLI 子进程**。会话记录的 `id`（UUID）**同时**就是 CLI 的 `--session-id`——线程身份和我们的记录身份是同一个，不需要映射表。

| HeyClicky（codex） | 本项目 |
|---|---|
| codex 子进程 + stdin/stdout JSON-RPC | `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages` 常驻子进程，换行分隔 JSON |
| `thread/start` | 首次启动带 `--session-id <UUID>` |
| `thread/resume` | 进程死后重拉带 `--resume <UUID>`（线程历史在 CLI 侧，不丢） |
| `turn/steer` | 进程活着就往 stdin 再写一行 user 消息（实测有效，见下） |
| `turn/interrupt` | stdin 写 `control_request` interrupt（实测 CLI 会回 `result` 帧结束当前轮） |
| `workingDirectoryOverride` | 子进程 `cwd` = 项目文件夹 |
| `approval_policy` | `--permission-mode`（见权限三档） |

文件分工：`AgentSession.swift`（纯数据）→ `AgentSessionStore.swift`（持久化，克隆 `ConversationSessionsStore` 的形状）→ `ClaudeAgentProcess.swift`（子进程管道，`nonisolated`）→ `AgentSessionManager.swift`（`@MainActor` 编排）→ `AgentSessionView.swift` + `HomeSpaceSidebarView` 的 agentList（UI）。

## 二、CLI 协议实测（2026-09-22，claude v2.1.278，参数与 App 完全一致）

启动参数（`ClaudeAgentProcess.launchArguments`）：

```
-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
--session-id <UUID>          # 首次；之后 --resume <UUID>
--permission-prompts none    # headless 没人答审批弹窗，宁可拒绝不要挂死
--permission-mode acceptEdits --allowedTools Read Edit Write Glob Grep Bash WebSearch WebFetch Task NotebookEdit
```

实测确认的行为：

- **stdout 是一帧一行的 JSON**。要处理的帧型：`system/init`（握手）、`stream_event`（`content_block_delta` 的 `text_delta` 拼流式文本）、`assistant`（完整消息，取 `tool_use` 块记成「⚙︎ 工具 · 摘要」行）、`result`（一轮结束，带 `subtype` / `result` / `total_cost_usd`）。**完整 assistant 消息的文本块不再发一遍**——delta 已经送过 UI，再发就是重影。
- **一轮结束的判据是 `result` 帧，且 `total_cost_usd` 每轮都有值**（实测 0.193、0.232 两轮）。
- **同进程第二轮追问直接写 stdin 即可**（steer 形态）——实测同一进程跑了两轮，第二轮正确改写了第一轮创建的文件。
- **中断：写 `{"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}` 一行，不需要 kill**。CLI 会立刻结束当前轮回一个 `result` 帧，`subtype` 是 `error_during_execution`、`result` 字段为**空**、`is_error` 为 true。解析代码（`ClaudeAgentProcess.swift:397-405`）对非 success 子类型走「记一条『回合未正常完成（子类型）』」的分支，中断轮不丢账。`requestInterrupt` 里 1.5 s 后 SIGTERM 只是 CLI 不响应时的兜底。
- **stderr**：本机用户的 claude 配置会让 CLI 打 `unrecognized_model` 一类的警告——非致命，只把 stderr 尾部（12 行）留作进程异常退出时的取证材料，正常运行时不打扰用户。

## 三、进程生命周期决策

1. **一 Agent 一进程，进程死了 ≠ 线程死了。** 桥接对象 `processesByAgentID` 在进程退出后**保留**（不清出字典），因为 `hasLaunchedOnce` 决定下一轮带 `--session-id` 还是 `--resume`。进程意外死亡只影响这一轮，下一轮自动续线程。
2. **写 stdin 失败给一次重拉机会。** `deliverTurn` 里 `sendUserTurn` 返回 false → 清掉桥 → 重新 ensureProcess（这次带 `--resume`）→ 再试一次 → 还失败才报 `turnDeliveryFailed`。这吃掉的是「alive 检查和写入之间进程恰好死了」的窗口。
3. **中断轮也记账。** 状态机：`interrupt()` 先把状态写成 `.interrupted`，随后到达的 result 帧把部分结果记进 transcript，但状态判断发现已是 interrupted 就不覆盖成 completed。用户看到的是「被中断」+ 它做到哪一步。
4. **app 退出杀干净。** `NSApplication.willTerminateNotification` → `terminateAllProcessesForAppExit()`。持久化里 `.running` 的记录在下次启动被 `demoteInterruptedAgentsOnLaunch()` 降为 `.interrupted`——花名册里永远没有僵尸。
5. **进程的私有状态全部锁在自己的 `parsingQueue` 上**（stderr 尾、累计流文本、行缓冲），回调以 `AgentProcessEvent`（Sendable）跨回 MainActor。这是子进程线程和 UI 线程之间唯一的通道。

## 四、权限三档的实际参数

| 档 | CLI 参数 | 实际能做什么 |
|---|---|---|
| 只读规划 | `--permission-mode plan` | 只读+给计划，不动文件 |
| 自动改文件（默认） | `--permission-mode acceptEdits` + `--allowedTools Read Edit Write Glob Grep Bash WebSearch WebFetch Task NotebookEdit` | 改项目内文件、跑命令、联网查 |
| 完全授权 | `--dangerously-skip-permissions` | 任何命令不经确认 |

`--allowedTools` 在 acceptEdits 档是显式的，因为 `--permission-prompts none` 下「会弹审批」的工具会被**静默拒绝**——显式放行才让 Bash 等在 headless 里可用。

## 五、和语音管线的关系（红线）

`CompanionManager.currentResponseTask` / `voiceState` 是驱动光标、TTS、刘海动效的**单槽互斥**状态，Agent 子系统**绝不复用**。并行长任务的先例是 `historyCompressionTask`：`AgentSessionManager` 由 `CompanionManager` 惰性持有、自带 Task、自带状态，语音提问、打断、切会话都不碰它。音效复用 `SoundEffectPlayer` 现成的 `answerFinished`（agent-done）和 `attentionNeeded`（agent-needs-you）。

流式文本**故意不进 `AgentSession` 模型**：delta 每秒几十次，模型住在 store 的 NSLock + 磁盘写后面，每条 delta 过一次锁再写一次盘不可接受。所以 manager 单独持有 `streamingTextByAgentID`，只有完成的回合走 store。

## 六、实测数据（2026-09-22，沙箱 `~/Desktop/clicky-agent-sandbox/`）

| 项 | 值 |
|---|---|
| 第一轮（建文件）result | `success`，cost $0.193 |
| 同进程第二轮（改文件）result | `success`，cost $0.232 |
| 中断轮 result | `error_during_execution`，`result` 空，`is_error: true` |
| 流式帧 | 一轮 35+ 个 `stream_event` |
| 中断生效 | control_request 后 ~2 s 内出 result 帧，无需 SIGTERM |

## 七、二期：语音调度（2026-09-22）

参考项目 03 号文档的「多 Agent 协作」不是 Agent 互相对话，而是**语音伴侣当总调度**：用户一句话，模型自己 spawn / send。本机形态是两个新动作标签：

- `[AGENT_SPAWN:名字:任务描述]` — 新开一个 Agent 干后台活。任务描述必须自包含（Agent 只看得到这一段文字）。同名 Agent 已存在 → 直接把任务交给它，不新建；文件夹取「默认项目文件夹」设置，没设就用 `~/Desktop/ClickyAgents/<名字>`（自动建目录，重名加 `-2`）。
- `[AGENT_SEND:名字:追加指令]` — 给在跑的 Agent 追加要求。名字按大小写不敏感精确匹配优先、含匹配兜底；匹配到多个 → 把候选名单回填给模型改口；找不到 → 回填现有名单。

三个硬性实现决策：

1. **调度标签不进 `actions` 数组**。进了就会触发「一动作一截图」的续拍循环（每步截一张屏）；它们进的是 `ActionParseResult.agentRequests`，和 `shapeRequests` 同级，解析后直接派发、结果作为 `<agent_dispatch_results>` 数据块挂进 `pendingAccessibilityContext`（数据通道，与 `[AX_TREE]` 同一权限级），下一步模型自己知道发生了什么。派发失败（总闸关、并发满、Agent 忙）也回填一行，模型会向用户解释。
2. **`streamingTagKeywords` 必须带上 `AGENT_SPAWN|AGENT_SEND`**（实测过：逐句快答会把不在表里的标签读出声）。已验证空消息的标签按垃圾丢弃、与 `[POINT:]` 互不污染、标签从 spokenText 剥离（独立编译 ActionTagParser 测过三种输入）。
3. **TTS 播报闸门双保险**。`BailianTTSClient.speakText` 开头会 `stopPlayback()`，所以完成播报只在 `voiceState == .idle` 时发（闭包 `voiceIdleProvider` 由 CompanionManager 注入，AgentSessionManager 自己不碰 voiceState——红线不变），再加 `isAnnouncingCompletion` 串行化标志防多个 Agent 同时完成时互相掐。只播结果第一句（按 `。！？\n` 切，截 60 字）。语音对话进行中只响现成的 `answerFinished` 音效。两个开关：「Agent 悬浮图标」（`allowsAgentDesktopHUD`）、「Agent 完成时语音播报」（`announcesAgentCompletion`），都在 Agent 设置页。

## 八、二期：桌面悬浮图标（HUD）

`AgentHUDController.swift`，形态抄还原文档 04 号：每屏右上角一摞圆 chip。实现决策：

- **面板参数克隆 `CompanionResponseOverlay`**（borderless + nonactivatingPanel、`.statusBar` 层级、透明、跨 Space），唯一区别是 `ignoresMouseEvents = false`——chip 是按钮。面板只占 chip 栈大小（宽 264、右上角菜单栏下方），不做全屏命中区探针（那是覆盖层为了不挡交互才需要的）。**绝不能成为 key window**：`.nonactivatingPanel` + 内容里没有文本框，点 chip 纯鼠标交互。
- **`NSHostingView` 只装一次**。刷新（`.clickyAgentSessionsDidChange`，运行中的 Agent 每几秒一发）只原位更新共享的 `AgentHUDStackModel.agents`——每次重建 hosting view 会把用户的悬停状态打断。chip 行高固定 56（悬停展开条比折叠瓦片高，固定行高让悬停变成纯内容切换，面板 frame 不用跟着动）。
- **面板 frame 跟随 chip 数量与手柄折叠态**。手柄折叠发生在 SwiftUI 侧，控制器靠 `stackModel.objectWillChange` 得知后重设 frame——收起时面板只剩手柄那么高，否则透明区域挡住底下应用的点击。
- **可见性规则**：显示所有 `status != .idle` 且本轮未点 × 的 Agent（dismissed 是内存 `Set<UUID>`，重启即回来）；启动时什么都不显示，直到本会话第一次 turn 活动——空闲 Agent 没有可看的东西。控制器在 `CompanionManager.start()` 里就触碰（`_ = agentHUDController`），保证第一次 store 变更前面板已存在，否则「运行中」的 chip 要等到第二次变更才出现。
- **点 chip 进刘海 Agent 页**：`CompanionManager.openAgentPage(agentID:)` → `selectAgent` + `selectedSidebarSection = .agents` + `expandForLaunch()`。不需要 `requestedAgentID` 之类的请求标志——Agent 视图是侧栏的另一半，内容列实时读 section；设置才需要请求标志（设置页与侧栏互斥）。
- **调色板**：chip 渐变用 `MascotRoster.identity(forSessionID:)` 同一条 id 哈希规则，同一 Agent 的桌面 chip 和侧栏头像永远同色。状态点：运行绿 / 完成蓝 / 出错红 / 中断橙。
- **截图天然排除**：`CompanionScreenCaptureUtility` 按 bundle id 剔除本 app 全部窗口，HUD 对模型不可见，零额外代码。

## 九、二期：累计花费

`AgentSession.accumulatedCostUSD: Double?` + `AgentSessionStore.addTurnCost`（同一次 mutate 里更新单轮和累计）。Agent 会话页头部在单轮花费旁显示「累计 ≈$x.xx」，且只在累计 ≠ 单轮时显示（第一轮两个数一样，显示两遍是噪音）。

## 十、遗留（三期）

- steer 的时机限制：Agent 在跑时 SEND 返回「正在执行上一条任务，这条指令没有送出」；「活动转弯中途插话」要求 CLI 侧排队。
- HUD 展开条里的追问输入框（要点 chip 进刘海用现成 composer；做输入框需要 key-window 面板，复杂度不成比例）。
- 文件 diff 弹层、审批卡片（走 `--permission-prompts none` 三档权限，没有审批流）。
- 端到端实测：调度标签的真机全链路（模型发出标签 → 派发 → chip 出现 → 播报）还没跑过——解析层已独立验证，真机链路等用户实测。
