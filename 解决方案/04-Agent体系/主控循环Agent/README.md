# 主控循环 Agent

> 四类分流里的 **③**：点击、输入、打开、文件读写。它是**唯一在本机上改变机器状态、并且要回头确认的**那一类，
> 所以只有它带"看一步做一步"的循环。
> 它是**真 agent**（有循环、有观察、有自主决策），不是脚本执行体。
>
> 状态：**设计已记录，尚未实施**。

---

## 一、这一类是什么

| 项 | 内容 |
|---|---|
| 执行体 | 主控自己——视觉模型 + `CompanionManager` 的循环，**进程内**调用 `MacosUseSDK` |
| 接收的标签 | `[CLICK]` `[RIGHT_CLICK]` `[DOUBLE_CLICK]` `[SCROLL]` `[TYPE]` `[SELECT]` `[PRESS]` `[OPEN]` `[WAIT]` `[AX_TREE]`<br>**+ 文件工具** `[FILE_LIST]` `[FILE_READ]` `[FILE_WRITE]`（新）<br>**+ 新动作** `[DRAG]`（及可选的 `[MOVE]`）（新）<br>**+ 截图与 OCR** `[SCREENSHOT]` `[CROP]` `[OCR:]`（新，`05`）<br>**+ 工具库** `[RUN:工具名:参数]`（新，`06`；MCP 也走这一层） |
| 循环 | 有：一步一动作 → 新截图 → 自动续写，15 步上限。**由代码强制**（只执行回复里的第一个动作） |
| 观察手段 | 截图（主）+ 界面结构摘要 `[AX_TREE]`（按需） |
| 闸门 | 「允许 Clicky 操作电脑」管点击/输入；**文件访问清单**管文件读写（逐路径、读写分离） |

**它不接收**：`[POINT]`/`[SHAPE]`（纯视觉，无执行体）、`[SVG_*]`（画图助手）、`[AGENT_*]`（Claude Code）。

## 二、三篇文档各管什么

| 文档 | 管什么 | 一句话 |
|---|---|---|
| [`01-分流与边界.md`](01-分流与边界.md) | 分类本身 | 出口从 5 收到 4；桌面管家并入本类；失败要回传给模型 |
| [`02-文件访问授权.md`](02-文件访问授权.md) | 文件工具能碰什么 | 逐路径白名单，读/写两条独立判据，四条逃逸防线 |
| [`03-语言适配与动作扩展.md`](03-语言适配与动作扩展.md) | 中文环境 + 动作清单 | 语言相关的只有「应用名解析」一处；`DRAG` 等动作缺口 |
| [`04-观察判据与批量.md`](04-观察判据与批量.md) | 什么时候必须看一眼 + 批量 | 判据是「下一步是否取决于一个不确定的结果」；C 类链可一次做完；一个光标一个键盘焦点是物理上限 |
| [`05-截图与OCR.md`](05-截图与OCR.md) | 按区域截屏（原图）+ 本地 OCR | 视觉用的图是缩过的、要存的是原图；截图/裁剪/OCR 是一条 C 类链 |
| [`06-工具库与MCP.md`](06-工具库与MCP.md) | 预先写好的脚本库 + MCP | 工具的两个来源（自写 / 从 MCP 提炼）；**固化判据是"要替模型记住它不可能知道的东西"**，不是代码行数；打开 App 属指令不属脚本；工具与技能并列（函数式 vs 方法论）、按需两层加载；创建+独立校验+失败回落；MCP 装但不直灌 |
| [`07-工具路由与instant-agent.md`](07-工具路由与instant-agent.md) | 工具选择的路由架构 | 移植 instant-agent：模型只选不生成命令、拒绝优于选错、L0 短语表（高频 2ms 零模型）、catalog 硬度（params schema / verify / examples / verified_at 门禁）；**JEV 不移植**（instant-agent 已实测删掉它），目录破 150 条才升级闭集路由，数百条才评估 JEV |
| [`图形讲解/`](图形讲解/README.md) | 本类分派出去的「要一张图」能力 | 逐笔动画 + 逐步讲解（自己的脚本、自己的模型调用） |

## 三、全部代码落点（一张总表）

按「先修坏的，再加新的」排序。**每一行都是要改的地方，不是建议**。

### 第一优先：修已确认的坏点

| 文件 | 改什么 | 依据 |
|---|---|---|
| `MacosUseController.swift` | **修应用名解析**（中文名打不开的根因）：建「名字 → 应用」索引，中英文同表 | [`03`](03-语言适配与动作扩展.md) 第二节（五种仪器实测） |
| `CompanionManager.swift` | **续写提示词带上上一步的真实结果**——现在失败时仍说「executed as written」，模型以为成功了 | [`03`](03-语言适配与动作扩展.md) 第四节 |
| `MacosUseController.swift` | 去掉 `.skipsHiddenFiles` 的影响（cryptex 应用如 Safari 目前靠 SDK 兜底侥幸能用） | [`03`](03-语言适配与动作扩展.md) 第二节 |

### 第二优先：并掉桌面管家

| 文件 | 改什么 | 依据 |
|---|---|---|
| `ActionTagParser.swift` | 移除 `desktopAgentPattern`（`[PY_AGENT]`）；加三个文件标签的 pattern + **`streamingTagKeywords`** | [`01`](01-分流与边界.md)、[`02`](02-文件访问授权.md) |
| `MacosUseController.swift` | 三个文件工具的进程内实现（`FileManager` + **逐路径授权校验**）；`[OPEN:]` 扩展到路径；移除 `runDesktopFileAgentTask`（`:1318`）与它的 case（`:222/266`） | [`02`](02-文件访问授权.md) |
| `AppSettings.swift` | `FileAccessEntry` + `fileAccessEntries`（`decodeIfPresent`，缺省空数组） | [`02`](02-文件访问授权.md) 第六节 |
| `GeneralSettingsView.swift` | `SettingsPage` 加 `.fileAccess`「文件访问」；列表 + 两个开关 + `NSOpenPanel`；侧边栏「看与操作」分组加一行 | [`02`](02-文件访问授权.md) 第四节 |
| `CompanionManager.swift` | 系统提示词：删 `[PY_AGENT]` 一节；注入 `<authorized_paths>` 清单 | [`02`](02-文件访问授权.md) 第三节 |

### 第三优先：加动作

| 文件 | 改什么 | 依据 |
|---|---|---|
| `ActionTagParser.swift` | `[DRAG:]`（及可选 `[MOVE:]`）的 case + pattern + **`streamingTagKeywords`**；修饰键表加中文别名 | [`03`](03-语言适配与动作扩展.md) 第五、六节 |
| `MacosUseController.swift` | `DRAG` 的实现：`mouseDown` → 多次 `mouseDragged`（**必须分步**）→ `mouseUp`；起点走与 click 同一条吸附链 | [`03`](03-语言适配与动作扩展.md) 第五节 |
| `CompanionManager.swift` | 系统提示词加动作那一行 + 把拖拽归入「破坏性动作需明确要求」 | [`03`](03-语言适配与动作扩展.md) 第五节 |

### 第四优先：并发与多目标（可选，收益大）

| 文件 | 改什么 | 依据 |
|---|---|---|
| `CompanionManager.swift` | 按新判据分档：**C 类链**（整条链事先确定 + 任何一步失败都不会让下一步有害）允许一次执行完；v1 只放行不碰焦点的动作 | [`04`](04-观察判据与批量.md) 第三节 |

### 第五优先：截图与 OCR

| 文件 | 改什么 | 依据 |
|---|---|---|
| `CompanionScreenCaptureUtility.swift` | 新增一条**原图**抓取路径（现状是缩到 1280 + JPEG 0.8，只适合喂模型）；现有视觉那条路一行不改 | [`05`](05-截图与OCR.md) 第一节 |
| `MacosUseController.swift` | `[SCREENSHOT:区域]`（left/right/top/bottom/full + 归一化矩形）、`[CROP:路径:x,y,w,h]` 两个动作 | [`05`](05-截图与OCR.md) 第二节 |
| 新增 | OCR（Vision `VNRecognizeTextRequest`，显式 `zh-Hans` + `en`）——全仓库目前没用过 Vision | [`05`](05-截图与OCR.md) 第四节 |
| `AppSettings.swift` + `GeneralSettingsView.swift` | 看与截图页加「截图保存位置」，默认 `~/Desktop/Clicky/` | [`05`](05-截图与OCR.md) 第三节 |

### 第六优先：工具库（收益最大的一步）

| 文件 | 改什么 | 依据 |
|---|---|---|
| `ActionTagParser.swift` | `[RUN:工具名:参数]` 的 case + pattern + **`streamingTagKeywords`**；`[TOOLS:分类]`（拉某分类的完整卡片） | [`06`](06-工具库与MCP.md) 第五节 |
| 新增 | 工具库运行时：读 `manifest.json`、**三层加载**（L0 常驻一行 / L1 命中后注入卡片 / L2 技能文档）、参数校验、跑 `run`、跑 `verify`、**比对不符就回落手动路径**；失败时把 L1 卡片一起回填 | [`06`](06-工具库与MCP.md) 第五、六节 |
| 新增 | 工具库本体：`tools/` 在仓库里、**按功能分类**、每个工具标注 `dependsOnMCP`、**不含任何密钥**（密钥走 `Application Support` 下的 0600 文件） | [`06`](06-工具库与MCP.md) 第四、七节 |
| `CompanionManager.swift` | 系统提示词注入 **L0 清单**（每工具一行，≤40 个约 1.2 KB），不是完整 JSON Schema | [`06`](06-工具库与MCP.md) 第五节 |
| `AppSettings.swift` | **「允许调用工具库」独立总闸**（已定）——与「允许操作电脑」分开 | [`06`](06-工具库与MCP.md) 第九节 |

### 第七优先：MCP（只包装，不直灌）

| 文件 | 改什么 | 依据 |
|---|---|---|
| 新增 | MCP 客户端（按需），或先用脚本包装外部服务的少数高频动作 | [`06`](06-工具库与MCP.md) 第三节 |
| — | **不要把整套 MCP 工具 schema 注入快路径**——判据是它对每次请求固定前缀的开销 | [`06`](06-工具库与MCP.md) 第三节 |

### 第八优先：工具路由（移植 instant-agent 的执行纪律）

| 文件 | 改什么 | 依据 |
|---|---|---|
| 新增 | L0 短语表引擎（正则 + 别名 + 槽位抽取，纯本地，挂在 `[RUN:]` 之前）；L2 槽位校验（不过就拒）；重试一次；`verified_at` 门禁 | [`07`](07-工具路由与instant-agent.md) 第二节 |
| `tools/manifest.json` | 条目升级成 catalog 硬度：`params` 带 type/min/max、`command` 常量化、`verified_at`/`verify`/`examples` 必填 | [`07`](07-工具路由与instant-agent.md) 第二节 |
| `CompanionManager.swift` | 提示词加一句「目录里没有的能力就是没有」（拒绝优于选错）；工具数/索引体积监控（超 150 条或 6 KB 提醒升级闭集路由） | [`07`](07-工具路由与instant-agent.md) 第三、六节 |

### 第九优先：为复盘打标签（复盘 Agent 的前置）

| 文件 | 改什么 | 依据 |
|---|---|---|
| `ConversationHistoryStore.swift` | `ConversationHistoryEntry` 加 `taskLabels: [String]?` 与 `reviewedAt: Date?`（**都走 `decodeIfPresent`**，旧文件照常解码） | [`../复盘Agent/README.md`](../复盘Agent/README.md) §三 |
| `ActionTagParser.swift` | `[TASK:标签1,标签2]` 的 case + pattern + **`streamingTagKeywords`**（它同样不能被念出来） | 同上 §五 |
| `CompanionManager.swift` | 系统提示词要求每轮输出 1–3 个**词表内**标签；把标签写进当轮 turn 记录 | 同上 §五 |
| 新增 | `task_labels.json`（受控词表，放在工具库旁边，用户可改） | 同上 §五 |

### 加任何动作的四处纪律（漏一处就有症状）

1. `CompanionAction` 加 case（`ActionTagParser.swift`）
2. 解析 pattern + `forEachMatch` 调用
3. **`streamingTagKeywords`（`ActionTagParser.swift:696`）** ← 漏了 **TTS 会把标签逐字念出来**
4. 系统提示词那一行（`CompanionManager.swift:1598` 一带）← 漏了模型不知道有这个能力

（第 5 处是实现本身：`MacosUseController` 的执行分支 + 闸门。）

## 四、验收入口

| 改什么 | 去哪看验收 |
|---|---|
| 名字解析 / 失败回传 / 新动作 | [`03`](03-语言适配与动作扩展.md) 第八节（N1–N6、I1–I4、F1–F2、D1–D5） |
| 文件工具的授权 | [`02`](02-文件访问授权.md) 第七节（A1–A8、E1–E6、P1–P3） |
| 桌面管家合并后没有丢能力 | [`01`](01-分流与边界.md) 第五节（V1–V6） |
| 观察判据与批量 | [`04`](04-观察判据与批量.md) 第七节（C1–C8） |
| 工具路由（instant-agent 纪律） | [`07`](07-工具路由与instant-agent.md) 第七节（J1–J9） |
| 截图 / 裁剪 / OCR / 保存位置 | [`05`](05-截图与OCR.md) 第七节（S1–S10） |
| 工具库：来源与判据、三层加载、创建+校验+兜底、密钥、MCP 注入策略 | [`06`](06-工具库与MCP.md) 第十节（T1–T11） |
