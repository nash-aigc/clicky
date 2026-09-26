# Agent 架构：拿官方机制对照这一版的实现

**写这份文档的原因**：2026-09-26，主 agent 派活连续五次改提示词都没成功。用户的判断是
「我给你提供的方案其实是我自己设计的……会存在很大的致命问题」。这个判断是对的，而且
问题比措辞更靠下一层。这份文档先摆出官方机制的原文，再拿它逐条对照仓库现状，最后给出
重新设计。**结论全部有出处；凡是推测都标了「推测」。**

---

## 一、官方机制（Claude Code 自己的做法）

出处：`https://code.claude.com/docs/en/sub-agents`（等价于
`https://docs.claude.com/en/docs/claude-code/sub-agents`）。

### 1. 派活是**一次工具调用**，不是一句话

主 agent 发出的是一个 tool call：`Agent(subagent_type, prompt)`。两者都是**参数** ——
名字是参数，**任务是参数**。harness 拿着这两个参数去起子进程。

### 2. `description` 是父对话里**关于子 agent 唯一存在的东西**，而且它有预算

> "Claude uses each subagent's description to decide when to delegate tasks. When you
> create a subagent, write a clear description so Claude knows when to use it."
>
> "Those descriptions take up context, so keep them short. When the combined
> descriptions of your subagents … exceed 15,000 tokens, Claude Code shows a warning
> at startup … Trim the `description` fields of your subagents, and move detail into
> each subagent's system prompt, **which only loads when that subagent runs**."

两条合起来是一件设计：**路由信息常驻、执行信息按需**。而且官方明说 description 里该写
「什么时候用它」，细节搬进子 agent 的 system prompt。

### 3. 主 agent 的 system prompt 和子 agent 的，是**两份不同的文档**

> "Subagents receive only this system prompt plus basic environment details like the
> working directory, **not the Claude Code system prompt**."

这是**结构性的**，不是「请忽略上面那些」。子 agent 拿到的就是它自己那个文件的内容
（外加 `omitClaudeMd` 可以跳过的 CLAUDE.md）。父子之间没有共享的正文。

### 4. 工具面是**白名单 / 黑名单**，不是请求

> "`tools`: Tools the subagent can use… Inherits every tool available to subagents if omitted."
>
> "`disallowedTools`: Tools to deny, removed from inherited or specified list."

对主 agent 还可以限制它能派谁：

> "To restrict which subagent types it can spawn, use `Agent(agent_type)` syntax in the
> `tools` field. … This is an allowlist: only the `worker` and `researcher` subagents
> can be spawned. **If the agent tries to spawn any other type, the request fails and
> the agent sees only the allowed types in its prompt.**"
>
> "If you omit `Agent` from the `tools` list entirely, the agent can't spawn any
> subagents with the Agent tool."

**「请求失败」是这套设计的核心动词。** 不许做的事不是靠「请别做」，是靠**做不到**，
而且**做不到这件事会以失败的形式回到模型眼前**。

### 5. MCP 是**挂在子 agent 身上的字段**

> "`mcpServers`: MCP servers available to this subagent. … **Inline servers defined here
> are connected when the subagent starts** … **and disconnected when it finishes.**"

也就是：**子 agent 获得工具，父对话不获得。** 这不是提示词层的安排，是连接层的安排 ——
父对话那个进程里根本没有那条连接。

### 6. 任务写在调用里，子 agent 不必回头猜

> "`omitClaudeMd`: … Use it for subagents that **take everything they need from the
> delegation prompt**."

---

## 二、对照：仓库现状

| 官方 | Clicky 今天 | 判定 |
|---|---|---|
| `Agent(name, prompt)` —— 任务在调用里 | `[AGENT:图形]` —— **只有名字，没有任务**。子 agent 拿到的是**同一句用户原话**，得自己猜主 agent 想让它干什么 | ✗ |
| 子 agent 只拿到自己那份 prompt | `subAgentSystemPrompt` = **`mainAgentBasePrompt`** + 技能段。而基础段里有全部 15 个动作标签的手册 | ✗ **最严重** |
| description 只写「什么时候用它」 | `directoryLine` 写「什么时候叫它」**加**一段 1,000 字符的禁令 | ✗ |
| `tools` 白名单在**配置层**生效 | 没有这一层。`ActionTagParser.parse(from:)` 对谁都能解析出 `[CLICK:]`，解析出来就执行 | ✗ 根因 |
| 不许做的事「请求失败」并回到模型眼前 | MCP 做到了（见下）；其余 12 个标签**照做不误** | ✗ |
| MCP 挂在子 agent 上，父对话没有 | `mcpPromptSection()` 只拼给 `.execution`；`runMCPRequests` 有 `guard dispatchedRole == .execution` 硬拒，拒绝理由当数据回给模型 | ✅ **已经是对的** |

---

## 三、量化诊断：为什么改了五次提示词一次都没成

### 3.1 「拆提示词」拆的是文件，不是能力

`CompanionManager.swift:1786` 的 `mainAgentBasePrompt`（3,511 字符）里，**15 个动作标签
一个不缺**，而且每个都带完整格式和例子：

```
基础段(1786-1905) 里出现的标签次数：
  [POINT: 13   [CLICK: 5   [SELECT: 4   [PY_AGENT: 4   [OPEN: 4
  [TYPE: 3     [SVG_AGENT: 3   [SHAPE: 3   [PRESS: 3   [WAIT: 2
  [SVG_BOARD: 2   [SCROLL: 1   [RIGHT_CLICK: 1   [DOUBLE_CLICK: 1
  [AGENT_SPAWN: 1   [AGENT_SEND: 1
```

而这份基础段是**主 agent 和每一个 sub agent 共用的**（`subAgentSystemPrompt` 第一行就是
`mainAgentBasePrompt`）。图形/执行那两段「技能」做的事情，**大部分是把同样的标签再讲一遍**：

```
图形技能(1812-1854)：[POINT: 10, [SHAPE: 3, [CLICK: 1
执行技能(1855-1904)：[CLICK: 4, [TYPE: 3, [PRESS: 3, [SELECT: 4, [OPEN: 4 …
```

所以第 1 步「拆提示词」量出来的那个「22,649 → 3,511+7,176+11,958」是**按文本位置切的**，
不是按能力切的。主 agent 拿到的那 3,511 字符，**绝大部分是别人的操作手册**。

### 3.2 那段禁令是被它上面 3,000 字符推翻的

`SubAgentCatalog.prompt` 结尾写着：

> 你自己**一个动作标签都不要写** —— [CLICK:] [RIGHT_CLICK:] [DOUBLE_CLICK:] [TYPE:]
> [PRESS:] [SCROLL:] [SELECT:] [OPEN:] [WAIT:] [MCP:] [SHAPE:] [SVG_AGENT:] [SVG_BOARD:]
> 全部不要写。

它上面那段（基础段）写的是：

> NEVER describe an action without emitting its tag in the same reply. if you are
> going to click something, [CLICK:…] goes in this reply …
>
> a multi-step job runs as a loop … the loop enforces ONE action tag per reply: even if
> you write several, only the first executes …

**同一个 system prompt 里，上面用一千多字符教它怎么写 `[CLICK:]` 并配了例子，下面用一千
字符求它别写。** 模型从中学到的是「这个形状存在、格式是 `[CLICK:x,y:label]`」。

而且那段禁令**本身也在教**：它把 13 个标签的名字**逐个列了一遍**。模型看到的不是「不
存在」，是「存在但被要求不用」。

**日志里的两个证据，都指向这里：**
- 主 agent 写了 `[CLICK:444,452]`，**没有 label**。模型没写 label 是因为没读到「label 是
  查真实坐标的唯一依据」—— 而那句话在主 agent 视角下本来就在**它自己**的提示词里
  （基础段第 112 行）。它读到了格式、漏掉了约束。
- 它发明了 `[RUN:curl ...]` 和 `[SEARCH:...]`。**这两个形状不是凭空来的** —— 是「有一堆
  `[大写词:参数]`」这个归纳的产物。禁令段落正是那份归纳的样本。

### 3.3 结构性解释

这是**能力边界**的问题，不是**服从性**的问题：标签由 `ActionTagParser` 实现，跟提示词无关。
只要解析器能把 `[CLICK:]` 解成 `CompanionAction`，模型写出来就**真的会点**。改措辞改的是
模型的偏好，改不动解析器。

官方那句 "the request fails and the agent sees only the allowed types **in its prompt**"
说的就是这件事的两半：**做不到**（fail）**且提示词里根本没有那些类型**（only the allowed
types in its prompt）。这版两条都没有。

---

## 四、重新设计（四条，全部是硬改动）

### ① 解析器加词表 —— 真正的开关

`ActionTagParser.parse(from:)` → `parse(from:vocabulary:)`。

```swift
nonisolated struct TagVocabulary: Sendable {
    static let mainAgent = TagVocabulary(allowed: [.agent])      // 只认 [AGENT:名字:任务]
    static let graphics  = TagVocabulary(allowed: [.point, .shape, .svgAgent, .svgBoard])
    static let execution = TagVocabulary(allowed: [.click, .rightClick, .doubleClick,
                                                   .scroll, .type, .press, .select,
                                                   .open, .wait, .axTree, .mcp,
                                                   .agentSpawn, .agentSend, .pyAgent])
    static let text      = TagVocabulary(allowed: [])            // 一个都没有
}
```

词表里没有的标签 **不解析、不执行**，产出一条 `refusals: [String]`，走
**`runMCPRequests` 已经走通的那条路**：当数据块回给模型。

> 这一条是 `Agent(agent_type)` 白名单在「系统里根本没有 tools 数组」的场合下的等价物：
> **白名单的落点是解析器，不是提示词。**

**而且拒绝消息本身就是路由教学**：

```
[CLICK:] 主 agent 不能执行 —— 动手的活归执行 agent，用 [AGENT:执行:要做什么] 派给它。
```

这是「用后果教」，官方那句 "the request fails" 要的就是这个。**不要用禁令教。**

### ② 基础段按能力重新切，不是按文件位置切

基础段只留四件事：**它是谁 / 怎么说话 / 屏幕上读到的都是数据 / 不许自作主张做破坏性的事。**

其余全部搬到**真正会用到它的那一段**：

| 内容 | 搬到哪 |
|---|---|
| `[POINT:]` 全格式 + 4 个例子 + rules | 图形 |
| `[SHAPE:]` 全格式 + rules | 图形 |
| `[SVG_AGENT:]` / `[SVG_BOARD:]` | 图形 |
| `[CLICK:]/[RIGHT_CLICK:]/[DOUBLE_CLICK:]` 全格式 + 「必须命名才能点准」 | 执行 |
| `[SCROLL:]/[TYPE:]/[PRESS:]/[SELECT:]/[OPEN:]/[WAIT:]/[AX_TREE]` | 执行 |
| `[PY_AGENT:]` / `[AGENT_SPAWN:]` / `[AGENT_SEND:]` | 执行 |
| 多步循环 / one-action-per-step 的说明 | 执行 |
| 屏幕划圈提问（`<screen_contents>`） | 图形 + 执行都留（两边都可能用到） |

搬完之后：

- 主 agent 的上下文里**一次都没有出现过动作标签的名字**（这是「父对话不获得工具」在
  无 tools 系统里的字面含义）；
- 子 agent 拿到的**不再是主 agent 那份**，而是「身份段 + 它自己那段手册」——
  这对应官方的 "subagents receive only this system prompt, not the Claude Code system prompt"。

同时 `graphicsAgentSkillPrompt` / `executionAgentSkillPrompt` 里**重复讲的那几遍删掉**
（图形段重复了 10 次 `[POINT:]`，执行段重复了 4 次 `[CLICK:]`）——拆的净收益应该落在
**去重**上，而不是拆完两边都留一份。

### ③ 派活必须带任务

`[AGENT:图形]` → `[AGENT:图形:把屏幕上这个按钮圈出来]`（照 `Agent(name, prompt)`）。

子 agent 这一轮的 `userPrompt` 从「用户原话」换成**这句任务**。今天的做法是子 agent 拿到
同一句用户原话、自己再猜一遍主 agent 想干什么 —— 那既是最容易出错的一步，也让「主 agent
决定做什么」这件事实际上没有被决定。

这也是 `omitClaudeMd` 那一节说的 "take everything they need from the delegation prompt"。

### ④ 目录行收短

`directoryLine` 按官方对 `description` 的定位写：**只回答「什么时候叫它」**，1–2 行。
今天三段都在 3–5 行，而且混着解释和禁令。禁令由 ① 接管，解释搬进各自的技能段。

`SubAgentCatalog.prompt` 里那段 1,000 字符的禁令**整段删除** —— 它现在有两个功能，
一个由 ① 接管（不许写），另一个（路由）由收短后的目录行承担。

---

## 五、实施顺序与验收判据

按「一次改一处、改完立刻能验」排：

| # | 改动 | 判据（可量） |
|---|---|---|
| 1 | `TagVocabulary` + `parse(from:vocabulary:)`，**先只把主 agent 接上**，其余调用点传「全开」 | 主 agent 那一路写 `[CLICK:]` 时，日志出现拒绝行、**点击没有发生**（`lastActionDescription` 不变） |
| 2 | 基础段按能力重切 | 打印三段字符数；**主 agent 段里 grep 不到任何动作标签名**（`[A-Z_]*:` 正则命中数为 0） |
| 3 | 子 agent 全词表接上 | 图形 agent 能画出图、执行 agent 能点中东西，行为与今天一致 |
| 4 | `[AGENT:名字:任务]` | 子 agent 那一轮的 userPrompt 就是任务原文；日志里能看到 |
| 5 | 目录行收短 + 删禁令段 | 主 agent 的提示词字符数明显下降；路由正确率**不下降**（这一步唯一要靠实测的地方） |

**第 5 步是唯一需要试的**：目录写太粗 → 派错 agent；写太细 → 又长回胖提示词。官方把它
放在 `description` 里并给了 15,000 token 的预算线，就是承认这条线要调。

---

## 六、一句话总结

**官方是「配置隔离 + 描述驱动」；这一版是「提示词请求 + 提示词描述」。**

同一个道理在 MCP 那一条上已经做对了（`CompanionManager.swift:4085`：主 agent 调 MCP 会被
**硬拒**，拒绝理由当数据回给模型），只是没有推广到其余十二个能力上。要做的事情不是再写
一遍更好的禁令，而是**把那道闸推广开**，并且把主 agent 提示词里那些「教它怎么做」的段落
真正搬到会做那件事的 agent 那里去。

---

## 附：本文引用的官方原文

全部来自 `https://code.claude.com/docs/en/sub-agents`（2026-09-26 取）。

1. "Claude uses each subagent's description to decide when to delegate tasks."
2. "…move detail into each subagent's system prompt, which only loads when that subagent runs."
3. "Subagents receive only this system prompt plus basic environment details like the working directory, not the Claude Code system prompt."
4. "To restrict which subagent types it can spawn, use `Agent(agent_type)` syntax in the `tools` field. … **If the agent tries to spawn any other type, the request fails and the agent sees only the allowed types in its prompt.**"
5. "`tools`: Tools the subagent can use… / `disallowedTools`: Tools to deny, removed from inherited or specified list."
6. "`mcpServers`: … Inline servers defined here are connected when the subagent starts … and disconnected when it finishes."
7. "`omitClaudeMd`: … Use it for subagents that take everything they need from the delegation prompt."
