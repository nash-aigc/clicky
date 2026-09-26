# Wanna 百炼版 —— 完整复盘与快速部署手册

> 本文档记录这次改造的全过程：改造前长什么样、改成了什么、每一步踩了什么坑、
> 怎么解决的、在新电脑上如何最快部署。部署时遇到问题先翻第 4 节的坑清单。

---

## 1. 方案总览

### 改造前：原来的架构

```
Wanna ──→ Cloudflare Worker（代理，防密钥泄露）
              ├─→ Anthropic Claude     （看屏幕回答问题）
              ├─→ ElevenLabs           （朗读回答）
              └─→ AssemblyAI           （语音转文字）
PostHog ──→ 原来那个实现的分析账号（上传你的语音转写、模型回答、邮箱）
```

### 现在的架构（本仓库）

```
Wanna ──→ 你在「模型设置」里指定的服务商（直连，无代理）
              ├─→ 👂 实时语音转文字（websocket）   默认 百炼 qwen3-asr-flash-realtime
              ├─→ 🧠 看屏幕截图回答问题（SSE 流式） 默认 百炼 qwen3-vl-plus
              └─→ 👄 朗读回答                      默认 百炼 qwen-audio-3.1-tts-flash
                                                   （音色=赵今麦克隆音色）
分析上报：无（PostHog 已彻底移除）
```

配置存在 `~/Library/Application Support/Wanna/ModelConfiguration.json`（权限 600，在仓库之外）。
`BailianSecrets.plist` 仍然有效，但只在**第一次启动、还没有上面那个 JSON 时**用来播种初始配置。
密钥不进代码、不进仓库。

### 它的工作原理（用户常问）

1. 你**按住 ctrl+option 说话**，麦克风录音实时流给 `qwen3-asr-flash-realtime`，边说边出转写。
2. 你**松开按键**那一刻，app 用 ScreenCaptureKit **给所有连接的显示器整屏截图**——
   ⚠️ **是整个屏幕，不是你选中的内容**。app 根本不知道你"选中"了什么，
   它拿到的是：① 你说的话（转写文本）② 全屏幕截图。你"选中了问题"这个动作
   本身不会被感知，起作用的是你**说出来的**那句话。
3. 转写文本 + 截图（base64）+ 最近 10 轮对话历史，发给**当前配置的视觉模型**
   （默认 `qwen3-vl-plus`），以 OpenAI 兼容格式 SSE 流式返回回答。
4. 回答里的 `[POINT:x,y:标签]` 标签被解析成屏幕坐标（0–1000 归一化网格），
   蓝色小三角沿贝塞尔曲线飞过去指。
5. 去掉坐标标签后的纯文本切成句对齐分块，逐块发给 TTS 合成 WAV，`AVAudioPlayer` 播放。

一句话总结：**它听到你说的话 + 看到你全部屏幕，回答并朗读，还会飞过去指。**

---

## 2. 改造清单（改造前 → 现状）

| 能力 | 原来 | 现在 | 文件 |
|---|---|---|---|
| 语音转文字 | AssemblyAI（经 Worker 拿临时 token） | `qwen3-asr-flash-realtime` websocket 直连 | `BailianRealtimeTranscriptionProvider.swift`（新） |
| 看屏幕回答 | Anthropic Claude | `qwen3-vl-plus`（可选 flash）OpenAI 兼容 SSE | `BailianVisionChatAPI.swift`（新） |
| 朗读 | ElevenLabs | `qwen-audio-3.1-tts-flash`，音色=赵今麦克隆音色（voice-enrollment 复刻，想换回官方音色改 `BailianConfiguration.textToSpeechVoice` 为 `yuxiaoyun_v3.1` 等） | `BailianTTSClient.swift`（新） |
| 分析上报 | PostHog（传转写/回答/邮箱） | **无** | `WannaAnalytics.swift` 已删 |
| 密钥 | 硬编码 / Worker 环境变量 | gitignored `BailianSecrets.plist`（首次播种用） | `BailianConfiguration.swift`（新）、`AppBundleConfiguration.swift`（扩展） |
| 模型可配置 | 三个模型全部写死在代码里，换模型要改代码重编译 | 设置窗口里填 URL / API Key / 模型名，**保存后立即生效** | `ModelSettingsView.swift`、`ModelConfiguration.swift`、`ModelConfigurationStore.swift`（均为新增） |

删除的文件：`ClaudeAPI.swift`、`ElevenLabsTTSClient.swift`、`WannaAnalytics.swift`。
`worker/` 目录（改造前的 Cloudflare 代理，转发 Anthropic / ElevenLabs）已移出仓库。
`OpenAIAudioTranscriptionProvider.swift`、`AssemblyAIStreamingTranscriptionProvider.swift`、
`OpenAIAPI.swift` 当时是死代码、保留未删；2026-09-26 已连同它们唯一的一处接线
（`BuddyTranscriptionProvider` 的候选表）一起删除。

### 密钥怎么放（新机器必做）

两个文件都叫 `BailianSecrets.plist`，内容相同：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BailianAPIKey</key>
    <string>sk-你的百炼API-KEY</string>
    <key>BailianWorkspaceBaseURL</key>
    <string>https://ws-你的工作空间ID.cn-beijing.maas.aliyuncs.com</string>
</dict>
</plist>
```

一份放在仓库里（`Wanna/BailianSecrets.plist`，已 gitignore，Xcode 打包用），
一份放在 `~/Library/Application Support/Wanna/BailianSecrets.plist`（兜底，
防止 Xcode 没把 loose plist 拷进包里；`AppBundleConfiguration` 会自动找到它）：

```bash
mkdir -p ~/Library/Application\ Support/Wanna
cp Wanna/BailianSecrets.plist ~/Library/Application\ Support/Wanna/BailianSecrets.plist
chmod 600 ~/Library/Application\ Support/Wanna/BailianSecrets.plist
```

端点和密钥在百炼控制台「模型服务 → API-KEY」和工作空间管理页拿。
注意是**工作空间专属端点**（`ws-….maas.aliyuncs.com`），不是公共 `dashscope.aliyuncs.com`。

### 换模型怎么换（推荐用设置窗口）

点菜单栏面板右上角的**齿轮** → 打开「Wanna 模型设置」独立窗口。里面按三角色列出当前在用的模型：

```
当前使用
  👂 听   [服务商 ▾]  [模型名        ]
  🧠 想   [服务商 ▾]  [模型名        ]
  👄 说   [服务商 ▾]  [模型名        ]
     音色 [音色名                      ]

服务商
  阿里云百炼  承担：👂 👄   URL / API Key   推理 [开关]
  DeepSeek    承担：🧠      URL / API Key   推理 [开关]
```

- **一个服务商一套 URL + API Key**，模型名按「服务商 × 角色」分别记住，来回切不用重填。
- 每张服务商卡上有一个 **「推理」开关**（默认**关**）：打开就是「让模型先推理再回答」，
  每次大约多等 3.4 秒，难题可能答得更准；关掉就是直接回答。只影响 🧠 想。
  详细实测见第 6 节。
- 底部 **测试连接** 会逐角色发一个最小请求，把服务端返回的**原始报错**显示出来
  （`AllocationQuota.FreeTierOnly`、`InvalidApiKey`、`Model not exist` 之类），
  所以「到底哪里不对」不用猜。
- 路径由协议决定，不用手填 endpoint：百炼走 `/compatible-mode/v1/chat/completions`，
  **DeepSeek 走 `https://api.deepseek.com` + `/chat/completions`（没有 `/v1`）**。
  DeepSeek 没有 ASR / TTS，所以只能承担 🧠。
- **保存后立即生效**，不用重启。正在朗读的那一句会念完，下一句才换。
- 删掉一个正在承担角色的服务商时，会弹确认框写明「删除后 X 角色将不可用」，
  并且**不会**把角色偷偷转给另一家（那等于把你的屏幕截图发给别人）。

配置文件 `~/Library/Application Support/Wanna/ModelConfiguration.json` 是纯 JSON，
手改也行，但要**重启 app 才生效**（不做文件监听）。

### 本机现在的初始配置（已写好，开箱即用）

本机的 `ModelConfiguration.json` 已经生成好了，三个角色是这么分的：

| 角色 | 服务商 | 模型 |
|---|---|---|
| 👂 听 | 阿里云百炼 | `qwen3-asr-flash-realtime` |
| 🧠 想 | **DeepSeek** | `deepseek-flash` |
| 👄 说 | 阿里云百炼 | `qwen-audio-3.1-tts-flash` + 赵今麦克隆音色 |

也就是说：**看屏幕回答问题走 DeepSeek，听和说仍然走百炼**（DeepSeek 没有语音转写和
语音合成，这两件事它做不了，硬要它做只能报错）。想改回百炼看图，打开设置窗口把 🧠 的
服务商换回「阿里云百炼」即可 —— 百炼卡上已经预填好 `qwen3-vl-plus`，不用重新输。

三个角色**都实测过**（用的是配置文件里存的那把 key，不是另找的）：视觉带图 200 并能输出
`[POINT:坐标:标签]`、TTS 200 并返回音频、ASR websocket 握手 101。所以配置本身没有问题，
出问题时先查账号额度，再看是不是模型名填错了。

DeepSeek 的 key 在设置窗口的 DeepSeek 卡里，想换直接改；百炼的 key 不必动。

---

## 3. 遇到过的所有问题（症状 → 根因 → 解决）

按时间顺序，每个都有实锤证据，不是猜测。

### ① 构建失败（最初）

- **症状**：Xcode 构建直接报错，起不来。
- **根因**：多个 —— 改造前签名钉死了原来那个实现的团队 ID（一个别人的 team ID），任何别的机器都
  编不过；同时引入百炼代码后 PostHog 等依赖需要一并处理。
- **解决**：app target 改签名（见 ②），删除/替换三个海外服务的客户端文件。

### ② 权限反复弹窗，每次重建都要重新授权

- **症状**：屏幕录制、辅助功能、麦克风权限反复要，体验极差。
- **根因**（有实锤）：临时签名（ad-hoc）的代码签名指定要求是
  `designated => cdhash H"…"`——**绑定二进制哈希**，每重建一次哈希就变一次，
  macOS 把它当成一个全新的 app，TCC 权限全部重置。证书签名的 app 的要求是
  `… certificate leaf[subject.OU] = "团队ID"`，跨重建稳定。
- **解决**：Xcode → Settings → Accounts 登录 Apple ID（免费个人团队即可），
  app target 签名设为 Automatic + Apple Development + 个人团队。
  本机实测 `codesign -dv` 显示 `TeamIdentifier=8WS2Z3JL4F` 后权限不再重置。
- **注意**：换签名的**第一次**构建后，三项权限仍需手动重新给一次（身份变了），
  之后就不会再问了。

### ③ 按键后无限转圈，app 冻结（最凶险的一个）

- **症状**：按住 ctrl+option 说话、松开 → 转圈永远不停，进程杀不掉。
- **根因**（四份崩溃报告 + 符号分析实锤）：
  `BailianRealtimeTranscriptionSession` 的 `deinit` 调用了 `cancel()`，
  而 `cancel()` 内部是 `stateQueue.async { self.… }`——**逃逸出强引用 self**。
  时序：松手 → owner 显式 `cancel()`（入队 block A，持有 self）→ owner 释放
  session → block A 跑完被释放，引用归零 → **deinit 在 stateQueue 线程上执行**
  → 又入队 block B，强引用一个正在析构的对象 → block B 被 `_Block_release`
  时对已释放内存做 `objc_release` → SIGSEGV。Xcode 调试器接住信号把进程冻住
  （TX 状态），表现就是无限转圈。
- **解决**：`deinit` 只直接消息对象（关 websocket），绝不调 `cancel()`；
  owner 在每条拆卸路径上显式调 `cancel()`。
- **教训**：凡是"串行队列 + async 闭包持有 self"的类，deinit 里不能调任何
  会入队 self 的方法。改造前那份上传式转写 provider 有同样的写法（死代码所以
  没炸，该文件已在 2026-09-26 删除），`AppleSpeechTranscriptionProvider` 的
  `cancel()` 没有逃逸 self，安全。

### ④ 语音回答永远重复"抱歉，没回答上来"

- **症状**：app 能用了，但无论问什么，语音都念同一句道歉。
- **关键认知**：这不是"模型答不上来"——抓 app 日志实锤：**视觉模型每次都正常
  回答了**（连坐标标签都对），**只有 TTS 被 403 挡住**：
  ```
  ⚠️ Bailian TTS error: Text-to-speech API error (403):
     {"code":"AllocationQuota.FreeTierOnly",
      "message":"Free quota exhausted... disable the \"use free tier only\" mode"}
  ```
  而 `speakCreditsErrorFallback(failure:)` 的设计是：TTS 失败就用系统语音念固定道歉——
  于是每次都"道歉"。**账号问题伪装成了模型问题。**
- **解决**：二选一（控制台操作）——给账户充值，或关掉"仅使用免费额度"模式；
  本机最终选择了换到**免费额度独立的**新模型 `qwen-audio-3.1-tts-flash`（见 ⑤）。
- **现在**：道歉语音保留（用户在等声音，静默更糟），但同一段报错同时会存进
  `CompanionManager.lastErrorMessage`，在菜单栏面板上用红字**原文**显示出来。
  再加上设置窗口里的「测试连接」，以后这类问题不用再靠 curl 猜。
- **排查方法**：同一个 key 用 curl 直连两个端点对比——视觉 200、TTS 403，
  一分钟定位是哪条链路、什么错误。

### ⑤ 换 TTS 模型后连环 400/报错（端点、音色都不能混）

- **症状**：把模型名改成 `qwen-audio-3.1-tts-flash` 后：
  ① `400 InvalidParameter: url error, please check url`
  ② 换对端点后又报 `[cosyvoice:]Engine error [411]`
- **根因**（官方文档实锤，`非实时语音合成` 用户指南）：
  > 端点不可混用 —— Qwen-Audio-TTS / CosyVoice 用
  > `/api/v1/services/audio/tts/SpeechSynthesizer`，
  > Qwen-TTS（`qwen3-tts-flash`）用 `/api/v1/services/aigc/multimodal-generation/generation`。
  报错文案完全不提"端点配错了"，极易误判。音色同理：
  **音色名不能跨模型族**，Qwen-TTS 的 `Cherry` 被 Qwen-Audio-TTS 拒绝（Engine 411），
  后者的音色是 `yuxiaoyun_v3.1`、`yeqinghe_v3.1` 这类带 `_v3.1` 后缀的名字。
- **请求体字段也不同**：Qwen-TTS 用 `input.{text, voice, language_type}`；
  Qwen-Audio-TTS 用 `input.{text, voice, format, sample_rate}`（没有 language_type）。
- **解决**：模型、音色、字段、路径**四件套一起换**。现在这四样在设置窗口里是同一个
  服务商卡片下的联动项，而且设置窗口的「测试连接」会用**和正式请求一样的请求体**
  合成两个字，所以音色配错族当场就会报 411，不用等真回答时才发现没声音。
  实测 400/900/1500 字符均 200，下载到有效 WAV（24kHz 单声道）。
- **教训**：百炼的"语音合成"不是一个端点，是**两族**。判断一个模型属于哪族，
  用 `bl model code --model 模型名 --sdk dashscope`：输出 websocket `tts_v2`
  样例的是 Qwen-Audio-TTS 族，输出 HTTP multimodal 样例的是 Qwen-TTS 族。

### ⑥ ASR websocket 的静默坑（开发期实测确认）

以下每条都是实测踩过/验证过的，写进代码注释了：

- 必须 **HTTP/1.1**（HTTP/2 握手 400）——`URLSessionWebSocketTask` 天然满足；
- 音频是 **base64 的裸 PCM16 / 16000Hz / 单声道**，100ms 一帧塞进
  `input_audio_buffer.append` 事件；
- 握手后要先发 `session.update` 配 `turn_detection: null`（手动提交模式），
  松手时发 `input_audio_buffer.commit`；
- 中间结果和最终结果的**字段名不同**：中间是 `text`+`stash`，最终是
  **`transcript`**（不是 `text`）——抄错就永远拿不到最终结果；
- **所有流式 ASR 会话共享一个长生命周期 `URLSession`**（provider 持有，不是
  session 持有）。每会话新建/销毁会破坏系统连接池，快速重连几次后报
  "Socket is not connected"；
- 服务端确认 `session.updated` 有时超时（日志里见过 `No session.updated within
  3.0s — starting audio anyway`），代码做了超时兜底，不影响功能。

### ⑦ 坐标指不准的静默失败

- **根因**：Qwen 视觉模型内部会把图缩放，`[POINT:x,y]` 坐标是 **0–1000 归一化
  网格**，不是截图像素。归一化值和像素值肉眼无法区分，跳过换算的表现就是
  光标指到大约 78% 的位置、不报错。
- **解决**：`screenshotPixelCoordinate(fromNormalizedPoint:…)` 按
  `值 / 1000 × 截图维度` 换算后再转屏幕坐标。
- **遗留问题**：`CompanionManager.swift` 的**新手引导提示词**还写着"用像素尺寸
  当坐标空间"，与归一化网格矛盾，引导演示可能指偏（主流程不受影响，未修）。

### ⑧ 隐私问题（改造时顺手根除）

改造前 PostHog 上报的是：**你的原始语音转写、模型的原始回答、你的邮箱**，
而且发到**那个实现的个人账号**（对用户零价值），还在主线程同步写盘。
本次彻底移除，不是"匿名化保留"。

---

## 4. 新电脑快速部署清单（照抄即可）

```bash
# 0)（国内网络）克隆前先测速选源
for url in \
  "https://github.com/nash-aigc/wanna/archive/refs/heads/main.tar.gz" \
  "https://gh-proxy.com/https://github.com/nash-aigc/wanna/archive/refs/heads/main.tar.gz" \
  "https://ghfast.top/https://github.com/nash-aigc/wanna/archive/refs/heads/main.tar.gz" \
  "https://ghproxy.net/https://github.com/nash-aigc/wanna/archive/refs/heads/main.tar.gz"; do
  echo "$url => $(curl -sL -o /dev/null --connect-timeout 5 --max-time 15 \
    -w '%{http_code} total:%{time_total}s' "$url")"
done
# 选最快且 200 的源来 clone（仓库大时差异明显）

# 1) clone（以 gh-proxy 为例）
git clone https://gh-proxy.com/https://github.com/nash-aigc/wanna.git
cd wanna

# 2) 放密钥（见第 2 节的 plist 模板，两处都放）
mkdir -p ~/Library/Application\ Support/Wanna
cp Wanna/BailianSecrets.plist ~/Library/Application\ Support/Wanna/BailianSecrets.plist
chmod 600 ~/Library/Application\ Support/Wanna/BailianSecrets.plist

# 3) 通电自检（可选但强烈建议，30 秒确认 key/额度/三路都通）
BASE=$(python3 -c "import plistlib;print(plistlib.load(open('$HOME/Library/Application Support/Wanna/BailianSecrets.plist','rb'))['BailianWorkspaceBaseURL'].rstrip('/'))")
KEY=$(python3 -c "import plistlib;print(plistlib.load(open('$HOME/Library/Application Support/Wanna/BailianSecrets.plist','rb'))['BailianAPIKey'])")
# 视觉：
curl -s -w "\nHTTP %{http_code}\n" -X POST "$BASE/compatible-mode/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"qwen3-vl-flash","max_tokens":16,"messages":[{"role":"user","content":"回复两个字：正常"}]}'
# TTS（注意端点族！qwen-audio 走 SpeechSynthesizer）：
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST \
  "$BASE/api/v1/services/audio/tts/SpeechSynthesizer" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"qwen-audio-3.1-tts-flash","input":{"text":"测试","voice":"yuxiaoyun_v3.1","format":"wav","sample_rate":24000}}'
# 两个都 200 才继续。TTS 若 403 AllocationQuota.FreeTierOnly → 见坑 A。
```

```text
4) Xcode：打开 Wanna.xcodeproj
   - Settings → Accounts 登录 Apple ID（免费的就行）
   - app target → Signing & Capabilities：
     Team 选你的个人团队（Automatic + Apple Development）
   - Cmd+R 运行

5) 权限：第一次运行会要 屏幕录制 / 辅助功能 / 麦克风，全部允许。
   ⚠️ 只要签名变了，这三项会重新要一次 —— 只此一次，之后稳定。

6) 端到端验证：菜单栏图标 → 按住 ctrl+option 说一句中文 → 松开
   应看到：实时转写 → 蓝色光标旁出文字气泡 → 朗读（当前为赵今麦克隆音色）→
   问"某某按钮在哪"会看到蓝三角飞过去指。

7) 换模型：面板右上角齿轮 → 「Wanna 模型设置」→ 填 URL / API Key / 模型名
   → 「测试连接」确认三路都 ✅ → 「保存」（立即生效，不用重启）。
   第 2 步放的 plist 只负责第一次启动时的初始值。
```

### 部署时最可能遇到的坑（按命中概率排序）

| # | 坑 | 识别特征 | 解法 |
|---|---|---|---|
| A | TTS 403 `AllocationQuota.FreeTierOnly` | 语音永远念同一句道歉 | 控制台充值，或关"仅使用免费额度"；或确认模型免费额度未用完。**现在面板会把这句原始报错用红字显示出来**，不用再猜 |
| B | 权限反复弹 | 每次重建都要授权 | 用证书签名（Automatic + 团队），别用 ad-hoc |
| C | TTS 400 `url error` | 换了模型名就报 | 端点族配错了，见第 3 节 ⑤ |
| D | TTS `Engine error [411]` | 音色名跨族 | 换本族音色名（`yuxiaoyun_v3.1` 等） |
| E | 转写有中间结果、没有最终结果 | 波形停了不出字 | 检查解析的是 `transcript` 字段（不是 `text`） |
| F | 光标指不到位、不报错 | 指到 ~78% 处 | 走 0–1000 归一化换算，别当像素用 |
| G | 快速连按几次后 ASR 失联 `Socket is not connected` | 用几次就哑 | 确认共享 URLSession 的写法没被改掉 |
| H | 终端跑 `xcodebuild` 后权限全重置 | 授权又来一遍 | 永远用 Xcode GUI 构建，别在终端跑 xcodebuild |
| I | 设置窗口打得开、但输入框打不进字 | 光标在闪，敲键盘没反应 | 是 `LSUIElement` 应用没激活导致的（非 key window 会吞掉按键）。`presentWindow()` 里必须调 `NSApp.activate()`，见 `ModelSettingsWindowController.swift` |
| J | 换了模型，提问没反应（连道歉都没有） | 光标闪一下就没下文 | 推理模型把 `max_tokens` 吃在 reasoning 上，HTTP 200 但 `content` 为空。已把上限提到 **32768**，且空回答会显式抛错显示在面板上 |
| N | **问一句要等好几秒才出声** | 面板一直转圈 | 两段耗时叠加：**推理（约 3.4 秒）+ TTS 合成（约 2 秒）**。推理默认已关（首字从 4.3 秒降到 0.8 秒），设置窗口里每个服务商卡上的「推理」开关自己也控制得住；TTS 是按字数线性增长、没有开关，答案越长等越久。详见第 6 节 |
| O | 想关推理，试了 `enable_thinking:false` 没用 | 首字还是 3.8 秒 | 这个参数在 `deepseek-flash` 上**不生效**（实测仍有 629 个 reasoning token），`chat_template_kwargs.thinking:false` 也不生效（378 个）。**只有 `thinking:{"type":"disabled"}` 和 `reasoning_effort:"none"` 真正关得掉**（0 个）。代码里用的是前者，由设置窗口的「推理」开关驱动 |
| M | 想调大 `max_tokens`，但不知道上限 | 设大了某一家就报 400 | 两家的上限差一个数量级：**DeepSeek `[1, 393216]`，百炼只有 `[1, 32768]`**。代码里是**共用一个常量**，所以只能取交集，**32768 就是天花板**。按 DeepSeek 的上限去设，换回百炼立刻 400 |
| K | 设置窗口里填好了，但语音转文字还是不走 | 重启才生效 | 已知问题，已修：`BuddyDictationManager` 每次开始录音前会重解析一次 provider |
| L | 把 🧠 换成 DeepSeek 后，提问报「图片不支持」 | DeepSeek 返回 Unsupported Image | DeepSeek 这个端点上**只有 `deepseek-flash` 能看图**，`deepseek-v4-pro` 是纯文本模型。用 `deepseek-flash` |

---

## 5. 费用参考（北京地域，实测当时价格）

| 模型 | 用途 | 价格 |
|---|---|---|
| `qwen3-asr-flash-realtime` | 听 | 0.00033 元/秒 |
| `qwen3-vl-plus` | 看+想 | 输入 1 元/百万 token |
| `qwen-audio-3.1-tts-flash` | 说 | 1 元/万字符（RPS 限 3） |

日常问几句话，一个月通常在几毛到几块钱量级。

---

## 6. 为什么问一句要等这么久（逐环节实测）

> 2026-09-21 实测。app 自己**没有任何日志**（stdout 是 `/dev/null`），所以这里是拿
> **和 app 完全一样的请求体**（1280×827 JPEG 截图 + 那个 4923 字符的系统提示词）
> 逐段打表量出来的，不是估的。

### 修之前的实测拆解

| 环节 | 耗时 | 说明 |
|---|---|---|
| TLS 握手 | 47ms | 可以忽略 |
| 截图（ScreenCaptureKit 缩放到 1280 宽 JPEG q0.8） | —— | **不是整屏原图**，约 294KB，base64 后 392KB |
| 上传 + 等服务端开工 | 476ms | 0.39MB 请求体 |
| **推理（首字节 → 第一个正文字）** | **3664ms** | ← **罪魁祸首**，664 个 reasoning token |
| 正文流式输出 | 342ms | 真正的回答只有这么点时间 |
| 视觉小计 | **4482ms** | |
| TTS 合成首段 | **2026ms** | 90 字 |
| 下载 WAV | 137ms | |
| **合计** | **约 6.6 秒** | 到听见声音为止 |

**面板为什么一直转圈**：`voiceState` 要等 TTS 真的开始播放才从 `.processing` 变
`.responding`，而 TTS 又排在整个视觉回答**之后**。所以这 6.6 秒全程都是转圈。
而且 `onTextChunk` 是空的（`No streaming text display`）——**回答的文字从不显示**，
用户只能听。这也是「感觉它没回我」的来源之一。

### 结论：DeepSeek Flash 慢，是因为它在"想"

`deepseek-flash` 是**推理模型**（百炼官方模型目录里它的 capability 就标着 `Reasoning`）。
问「屏幕右上角有什么？」这种纯感知问题，它也要先烧 664–868 个 reasoning token。
你想的「1 秒内出结果」对**非推理模型**成立，对推理模型不成立。

### 修法：把推理关掉（已改，在 `BailianVisionChatAPI.swift`，开关在设置窗口）

同一条问题、同一张截图，各开关实测：

| 参数 | 首字 | 总计 | reasoning token |
|---|---|---|---|
| 不加参数（原状） | 4298ms | 4668ms | 868 |
| `enable_thinking:false` | 3814ms | 4184ms | 629 ❌ 没用 |
| `chat_template_kwargs.thinking:false` | 2579ms | 3052ms | 378 ❌ 没用 |
| `reasoning_effort:"minimal"` | 1410ms | 1841ms | 112 |
| **`thinking:{"type":"disabled"}`** | **934ms** | **1377ms** | **0** ✅ |
| **`reasoning_effort:"none"`** | **980ms** | **1539ms** | **0** ✅ |

选了 `thinking:{"type":"disabled"}`。

**开关归用户**：设置窗口里**每张服务商卡片**都有一个「推理」开关
（`ProviderProfile.visionReasoningEnabled`），**默认关**——不开设置窗口的人直接就是快的那条路。
打开就是「让模型先推理再回答」，每次大约多等 3.4 秒。开关**按服务商存**，所以百炼和 DeepSeek
各记各的，来回切不用重设。保存后立即生效，下一次提问就换。

一个实现细节值得记着：这个字段存成 **`Bool?`（可选）**，因为 Swift 自动合成的 `Codable`
**遇到缺字段会直接抛错**——加一个非可选的 `Bool`，所有旧配置文件立刻全部读不出来。
`nil` 表示"从没设过"，读出来当"关"。开关一旦被点过就写明确的 `true`/`false`，
免得将来改了默认值、旧文件跟着偷偷变。

**关掉推理会不会变笨？** 连测 4 轮不同区域的问题，4/4 都给出了格式正确的
`[POINT:x,y:标签]`，坐标都在 0–1000 网格内：

```
右上角  [POINT:960,10:time in menu bar]   底部  [POINT:450,995:Dock栏]
左上角  [POINT:20,15:苹果菜单]             中间  [POINT:500,50:终端标签页]
首字延迟中位 817ms · 总耗时中位 1120ms
```

**修之后**：视觉 4482ms → **约 1120ms**，端到端 6.6 秒 → **约 3.1 秒**。

### 剩下的那 2 秒是 TTS，没有开关

TTS 合成耗时**按字数线性增长**（约 19ms/字 + 450ms 固定）：

| 答案长度 | 合成 | 音频时长 |
|---|---|---|
| 10 字 | 657ms | 1.6s |
| 90 字（典型） | 1756ms | 18.4s |
| 250 字 | 4615ms | 54.7s |
| 600 字 | 8948ms | 101.8s |

因为 `maximumCharactersPerChunk = 500`，常见回答都是**一整块**，所以要整段合成完才出声。
想再快只能：让回答更短（系统提示词已经要求「一两句话」），或者对长回答改成
**第一句先合成先播、剩下的边流边合成**（目前没做）。

### 换成百炼看图的对照

同一个请求打给百炼（非推理模型）：`qwen3-vl-plus` 首字 663ms / 总计 2016ms，
`qwen3-vl-flash` 首字 475ms / 总计 1305ms，都是 0 个 reasoning 帧。
所以要极致速度，把 🧠 换回百炼 `qwen3-vl-flash` 也是一条路。

