//
//  VoiceCatalog.swift
//  leanring-buddy
//
//  三个对话模式各自的音色表 —— 一等数据，不是散落在各处的字符串数组。
//
//  WHY THIS FILE EXISTS. 「音色」在百炼不是全局的：**每个模型只认自己那一组音色**，
//  填错会让整条 `session.update` 被拒绝（实测 `Unsupported voice: 'Tina'`），而且
//  失败是**连带的** —— voice、instructions、tools 一起失效，表现成「工具有时能用
//  有时不能用」，完全指不到音色上。所以「这个音色能不能用在当前模式 / 当前模型上」
//  必须是一个**可查询的判断**，而不是每个界面各写一遍的 if。
//
//  三套音色互不相交，而且**三套的来源都不一样**：
//
//   · 三段式 —— 跟合成模型走。`qwen-audio-3.1-tts-flash` **没有音色列表 API**
//     （实测 `bl speech synthesize --list-voices --model qwen-audio-3.1-tts-flash`
//     返回 "No built-in voice list available"，只有 CosyVoice 系才有），所以这张
//     表是**内置契约**，取自官方音色列表页。
//   · 全双工语音 —— **按模型版本分组**：3.0 Plus/Flash 只有 5 个系统音色，
//     3.1 Plus 在这 5 个之外另有 8 个。VoiceWeb 当年硬编码的那 19 个里有一大半
//     （`longanhuan_v3.6` / `loongmary` / `daniel` / `echo` / `hannah` / `sherry` …）
//     在今天的官方列表里根本不存在 —— **故意不照搬**，照搬会让整条会话被拒。
//   · 全双工全模态 —— 固定的 10 个，官方 doc 逐字确认；其中 `Cherry`/`Kai` 只属于
//     旧 qwen3 系、`Serena`/`Aiden` 只属于 qwen3.5 系，所以还要按模型族再筛一层。
//
//  这里**不做任何网络请求**：这些表是契约，服务端改了要跟着改，不能靠运行时猜。
//  数据来源与抓取日期写在每张表上。
//

import Foundation

/// 一个可选音色。`id` 就是填进 `voice` 参数的原值（**区分大小写**）。
nonisolated struct VoiceOption: Identifiable, Equatable, Hashable {

    let id: String
    let displayName: String

    /// 「男」/「女」/空 —— 官方表里带的，只用于展示。
    var gender: String = ""

    /// 一句话说明：声线特质、适用场景、或支持的语言方言。
    var note: String = ""

    /// **只有全模态用**：这个音色属于哪个模型族 —— `v3` 仅旧 qwen3 系、
    /// `v35` 仅 qwen3.5 系、空 = 两族都能用。
    ///
    /// 这一层筛选是必须的：配错不会在 `session.update` 被拒，而是**延迟到
    /// `response.create` 才报 1007**（`session.created`、VAD、转写全程正常），
    /// 所以从日志上极难定位。
    var modelFamily: String = ""
}

nonisolated enum VoiceCatalog {

    // MARK: - 三段式（按合成模型）

    /// `qwen-audio-3.1-tts-flash` 的系统音色。
    ///
    /// **这张表必须内置**：该模型没有 `--list-voices`，没有任何运行时途径能问出
    /// 它支持什么。
    ///
    // GENERATED — do not hand-edit. Source: the official 百炼 voice-list page
// https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list
// ids: the page as fetched 2026-09-24 (68). names: VoiceWeb's
// `system_voices.json` at bd94dec, joined on id; 7 ids the page no longer lists
// were dropped, because an id the model rejects is InvalidParameter.
    static let threeStageVoices: [VoiceOption] = [
        VoiceOption(id: "longanhuan_v3.1", displayName: "龙安欢", gender: "女", note: "女 · 重庆话 宁波话 韩语 印尼语"),
        VoiceOption(id: "longanlingxin_v3.1", displayName: "龙安灵心", gender: "女", note: "女 · 云南话 陕西话 上海话 法语 意大利语"),
        VoiceOption(id: "longanfengyue_v3.1", displayName: "龙安风悦", gender: "女", note: "女 · 东北话 越南语 日语"),
        VoiceOption(id: "xunanchuan_v3.1", displayName: "许南川", gender: "男", note: "男 · 多语种方言"),
        VoiceOption(id: "yuxiaoyun_v3.1", displayName: "于小云", gender: "女", note: "女 · 元气、亲切、自然 广告营销、广播、客服助手、旁白"),
        VoiceOption(id: "qiaoxiaojiao_v3.1", displayName: "乔小娇", gender: "女", note: "女 · 俏丽、可爱 广告营销、客服助手、有声书"),
        VoiceOption(id: "xiaxiaochen_v3.1", displayName: "夏小晨", gender: "女", note: "女 · 元气、明亮 广告营销、有声书"),
        VoiceOption(id: "anmingyuan_v3.1", displayName: "安明远", gender: "男", note: "男 · 清亮、自然 广告营销、有声书、旁白"),
        VoiceOption(id: "wenhuaiqing_v3.1", displayName: "温怀清", gender: "女", note: "女 · 清亮、柔和 儿童故事、客服助手、广告营销、新闻播报"),
        VoiceOption(id: "anxiaolan_v3.1", displayName: "安小岚", gender: "女", note: "女 · 清甜、纯净 有声书、客服助手、旁白、新闻播报、广告营销"),
        VoiceOption(id: "xieshurou_v3.1", displayName: "谢舒柔", gender: "女", note: "女 · 柔和、自然、知性 有声书、客服助手、旁白"),
        VoiceOption(id: "baiqinglan_v3.1", displayName: "白清岚", gender: "女", note: "女 · 明亮、清纯 语音助手、客服助手"),
        VoiceOption(id: "xuyuyuan_v3.1", displayName: "许玉远", gender: "女", note: "女 · 知性、成熟、质感 广告营销、新闻播报、旁白、客服助手、有声书"),
        VoiceOption(id: "anruorou_v3.1", displayName: "安若柔", gender: "女", note: "女 · 气声、知性 旁白、语音助手"),
        VoiceOption(id: "wenhuaizhi_v3.1", displayName: "闻怀之", gender: "女", note: "女 · 稳重、成熟 有声书、新闻播报、广告营销、客服助手、旁白"),
        VoiceOption(id: "xiaoxingzhi_v3.1", displayName: "萧行之", gender: "女", note: "女 · 端庄、贵气 新闻播报、有声书、旁白、客服助手"),
        VoiceOption(id: "guyunshu_v3.1", displayName: "顾云舒", gender: "女", note: "女 · 成熟、稳重 音乐电台、客服助手、有声书、旁白"),
        VoiceOption(id: "huozhuoshi_v3.1", displayName: "霍拙石", gender: "男", note: "男 · 清亮 有声书、广告营销、旁白"),
        VoiceOption(id: "yeqinghe_v3.1", displayName: "叶清禾", gender: "女", note: "女 · 亲切、温柔 有声书、广告营销、旁白、客服助手"),
        VoiceOption(id: "yunhuanhuan_v3.1", displayName: "云欢欢", gender: "女", note: "女 · 高亢、热情 有声书、旁白、客服助手"),
        VoiceOption(id: "xuxiaoqiao_v3.1", displayName: "徐小俏", gender: "女", note: "女 · 自然、俏皮 有声书、旁白、客服助手"),
        VoiceOption(id: "baianran_v3.1", displayName: "白安然", gender: "女", note: "女 · 低沉、浑厚、气声 配音讲解、有声书、旁白"),
        VoiceOption(id: "xuyanchu_v3.1", displayName: "许言初", gender: "女", note: "女 · 沉稳、磁性 新闻播报、有声书"),
        VoiceOption(id: "yezhiqing_v3.1", displayName: "叶知晴", gender: "女", note: "女 · 轻快、自然 儿童故事、客服助手、语音助手"),
        VoiceOption(id: "andi_v3.1", displayName: "安迪", gender: "男", note: "男 · ABC口音 语音助手"),
        VoiceOption(id: "anyuqing_v3.1", displayName: "安语晴", gender: "女", note: "女 · 甜妹"),
        VoiceOption(id: "Emily_v3.1", displayName: "Emily", gender: "女", note: "女 · 英式女声 Luna"),
        VoiceOption(id: "Luna_v3.1", displayName: "Luna", gender: "女", note: "女 · 英式口音"),
        VoiceOption(id: "Eric_v3.1", displayName: "Eric", gender: "男", note: "男 · 英式口音"),
        VoiceOption(id: "Luca_v3.1", displayName: "Luca", gender: "男", note: "男 · 英式口音"),
        VoiceOption(id: "Abby_v3.1", displayName: "Abby", gender: "女", note: "女 · 美式女声 Annie"),
        VoiceOption(id: "Annie_v3.1", displayName: "Annie", gender: "女", note: "女 · 美式口音"),
        VoiceOption(id: "Ava_v3.1", displayName: "Ava", gender: "女", note: "女 · 美式女声 Beth"),
        VoiceOption(id: "Beth_v3.1", displayName: "Beth", gender: "女", note: "女 · 美式口音"),
        VoiceOption(id: "Betty_v3.1", displayName: "Betty", gender: "女", note: "女 · 美式女声 Cally"),
        VoiceOption(id: "Cally_v3.1", displayName: "Cally", gender: "女", note: "女 · 美式口音"),
        VoiceOption(id: "Cindy_v3.1", displayName: "Cindy", gender: "女", note: "女 · 美式女声 Donna"),
        VoiceOption(id: "Donna_v3.1", displayName: "Donna", gender: "女", note: "女 · 美式口音"),
        VoiceOption(id: "Andy_v3.1", displayName: "Andy", gender: "男", note: "男 · 美式口音"),
        VoiceOption(id: "Brian_v3.1", displayName: "Brian", gender: "男", note: "男 · 美式口音"),
        VoiceOption(id: "David_v3.1", displayName: "David", gender: "男", note: "男 · 美式口音"),
        VoiceOption(id: "longanyuanfei_v3.1", displayName: "龙安元妃", gender: "女", note: "女 · 高傲妃子音 社交陪伴"),
        VoiceOption(id: "longjielidou_v3.1", displayName: "龙杰力豆", gender: "男", note: "男 · 天真男童音 儿童陪伴"),
        VoiceOption(id: "longanlingxi_v3.1", displayName: "龙安灵希", gender: "女", note: "女 · 可爱甜美音 社交陪伴（精品中文）"),
        VoiceOption(id: "longhuohuo_v3.1", displayName: "龙火火", gender: "男", note: "男 · 顽皮少年音 角色音"),
        VoiceOption(id: "longyingtao_v3.1", displayName: "龙应桃", gender: "女", note: "女 · 温柔淡定女 客服"),
        VoiceOption(id: "longanya_v3.1", displayName: "龙安雅", gender: "女", note: "女 · 高雅气质女 社交陪伴"),
        VoiceOption(id: "longwan_v3.1", displayName: "龙婉", gender: "女", note: "女 · 细腻柔声女 社交陪伴"),
        VoiceOption(id: "longxing_v3.1", displayName: "龙星", gender: "女", note: "女 · 温婉邻家女 社交陪伴"),
        VoiceOption(id: "longhua_v3.1", displayName: "龙华", gender: "女", note: "女 · 元气甜美女 社交陪伴"),
        VoiceOption(id: "longhan_v3.1", displayName: "龙寒", gender: "男", note: "男 · 温暖痴情男 社交陪伴"),
        VoiceOption(id: "longanzhi_v3.1", displayName: "龙安智", gender: "男", note: "男 · 睿智轻熟男 社交陪伴"),
        VoiceOption(id: "longzhe_v3.1", displayName: "龙哲", gender: "男", note: "男 · 呆板大暖男 社交陪伴"),
        VoiceOption(id: "longanyang_v3.1", displayName: "龙安洋", gender: "男", note: "男 · 阳光大男孩 社交陪伴（标杆音色）"),
        VoiceOption(id: "libai_v3.1", displayName: "李白", gender: "男", note: "男 · 古代诗仙男 诗词朗诵"),
        VoiceOption(id: "longling_v3.1", displayName: "龙铃", gender: "女", note: "女 · 稚气呆板女 童声"),
        VoiceOption(id: "longniuniu_v3.1", displayName: "龙牛牛", gender: "男", note: "男 · 阳光男童声 消费电子-儿童有声书"),
        VoiceOption(id: "longshanshan_v3.1", displayName: "龙闪闪", gender: "男", note: "男 · 戏剧化童声 消费电子-儿童有声书"),
        VoiceOption(id: "longpaopao_v3.1", displayName: "龙泡泡", gender: "女", note: "女 · 飞天泡泡音 消费电子-儿童陪伴 loongstella_v3.1 loongstella_v3.1 女 飒爽利落"),
        VoiceOption(id: "loongstella_v3.1", displayName: "Stella", gender: "女", note: "女 · 飒爽利落"),
        VoiceOption(id: "longyuan_v3.1", displayName: "龙媛", gender: "女", note: "女 · 温暖治愈女 有声书"),
        VoiceOption(id: "longmiao_v3.1", displayName: "龙妙", gender: "女", note: "女 · 抑扬顿挫女 有声书"),
        VoiceOption(id: "longsanshu_v3.1", displayName: "龙三叔", gender: "男", note: "男 · 沉稳质感男 有声书"),
        VoiceOption(id: "longanli_v3.1", displayName: "龙安莉", gender: "女", note: "女 · 利落从容女 语音助手"),
        VoiceOption(id: "longanwen_v3.1", displayName: "龙安温", gender: "女", note: "女 · 优雅知性女 语音助手"),
        VoiceOption(id: "longanlang_v3.1", displayName: "龙安朗", gender: "男", note: "男 · 清爽利落男 语音助手"),
        VoiceOption(id: "longxiaoxia_v3.1", displayName: "龙小夏", gender: "女", note: "女 · 沉稳权威女 语音助手"),
        VoiceOption(id: "longanchong_v3.1", displayName: "龙安冲", gender: "男", note: "男 · 激情推销男 直播带货 ​"),
    ]

    /// 一些合成模型**有** live 音色表（CosyVoice 系走
    /// `bl speech synthesize --list-voices`）；`qwen-audio-3.1-tts-flash` 没有，
    /// 所以它只能靠上面那张内置表。记在这里是为了下次有人问「为什么不做成
    /// 运行时查询」时有个答案。
    static let modelsWithLiveVoiceList = ["cosyvoice-v1", "cosyvoice-v2", "cosyvoice-v3-flash", "cosyvoice-v3-plus"]

    /// 两个实时模式当前的默认模型。
    ///
    /// **它决定可用音色**，所以不是一个随便的默认值：全双工取 3.0 Flash 时只有
    /// 5 个系统音色，取 3.1 Plus 才有 13 个。这里取 VoiceWeb 实测过的那个
    /// （3.0 Flash），换 3.1 Plus 是一个**有价格含义**的选择（¥30/¥100 对
    /// ¥40/¥150 每百万 token），所以由用户来定，不由这里悄悄选。
    ///
    /// Phase 2/3 会把它做成设置项；在那之前这两个常量是唯一的真相，写在数据层
    /// 而不是散在视图里。
    static let defaultDuplexModel = "qwen-audio-3.0-realtime-flash"
    /// 全模态模型。用户 2026-09-24 指定 3.8（价格还更优：图/文入 1.5、音频入 6、
    /// 文本出 4.5、音频出 12 —— 元/每百万 tokens，官方目录）。
    static let defaultOmniModel = "qwen3.8-omni-flash-realtime"
    /// 「理解」的默认模型。**必须是 deepseek**：三段式的理解现在走的是 HTTP 图文
    /// 那条路，全双工/多模态模型当理解还没有接线 —— 角色没单独配过时，这一栏
    /// 显示的必须是引擎真的在用的那个，而不是清单里的第一行。
    static let defaultUnderstandingModel = "deepseek-flash"
    /// 「表达」的默认模型（三段式真正在用的合成模型，支持克隆）。
    static let defaultExpressionModel = "qwen-audio-3.1-tts-flash"

    // MARK: - 表头下拉的模型清单（用户 2026-09-24 收窄后的五个模型）

    /// 一个可选模型。`supportsVision` 决定它能不能当「理解」用在开了摄像头/屏幕的
    /// 会话里；价格全部取自官方模型目录（2026-09-24，元/每百万 tokens）。
    nonisolated struct ModelChoice: Identifiable, Equatable {
        let id: String
        let displayName: String
        let architectureNote: String
        let priceNote: String
        let supportsVision: Bool
    }

    /// 识别模型的三个**大类**（用户 2026-09-24：「全双工语音会比非流式的流畅很多，
    /// 所以一定要先做这样的分类」，而且这三个分类要**持续保留**）。
    static let recognitionModelCategories = ["全双工语音", "流式", "非流式"]

    /// 音色面板的三个分类 —— 与识别的大类同名同序（用户要求两处都持续保留）。
    static let voiceCategories = ["全双工语音", "流式", "非流式"]

    /// 「全双工语音」类可选的**实时语音模型**（用户 2026-09-24 指定）。
    /// 它们的音色表不同（3.0 Flash 5 个、3.1 Plus 13 个），所以选模型决定音色清单。
    /// 架构描述与价格取自官方模型页
    /// （https://bailian.console.aliyun.com/cn-beijing/model/market/detail/qwen-audio-3.0-realtime-flash
    /// 及 3.1 Plus 的对应页，元/每百万 tokens）。
    static let duplexModelChoices: [ModelChoice] = [
        ModelChoice(
            id: "qwen-audio-3.0-realtime-flash",
            displayName: "3.0 Flash",
            architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
            priceNote: "音频入 6 · 文本出 4.5 · 音频出 12",
            supportsVision: false
        ),
        ModelChoice(
            id: "qwen-audio-3.1-realtime-plus",
            displayName: "3.1 Plus",
            architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
            priceNote: "音频入 40 · 文本出 40 · 音频出 150",
            supportsVision: false
        ),
    ]

    /// 「识别」的候选，按用户的分类法分组（2026-09-24 原话）：
    /// 「先按照全双工和非全双工来分类……第一大类是全双工，第二大类是 ASR。
    /// ASR 里面分成两类，流式和非流式」。
    /// `recognitionModelChoices[0]` 是识别的默认（全双工 3.0 Flash），控制器的
    /// 兜底读它 —— 调整顺序时不要把全双工挪出最前。
    static let recognitionModelChoices: [(category: String, choice: ModelChoice)] = [
        (
            "全双工语音",
            ModelChoice(
                id: "qwen-audio-3.0-realtime-flash",
                displayName: "3.0 Flash",
                architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
                priceNote: "音频入 6 · 文本出 4.5",
                supportsVision: false
            )
        ),
        (
            "全双工语音",
            ModelChoice(
                id: "qwen-audio-3.1-realtime-plus",
                displayName: "3.1 Plus",
                architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
                priceNote: "音频入 40 · 文本出 40",
                supportsVision: false
            )
        ),
        (
            "ASR · 流式",
            ModelChoice(
                id: "qwen3-asr-flash-realtime",
                displayName: "3 代实时识别",
                architectureNote: "边听边出字 · 上一代，准确率弱一些",
                priceNote: "按 token 计费",
                supportsVision: false
            )
        ),
        (
            "ASR · 非流式",
            ModelChoice(
                id: "qwen-audio-3.1-asr-flash",
                displayName: "3.1 ASR（整句一次认）",
                architectureNote: "说完再认 · 没有中间文字",
                priceNote: "入 0.8 · 出 2.7",
                supportsVision: false
            )
        ),
    ]

    /// 「理解」的候选，同样按用户的分类法（2026-09-24 原话）：「理解模型也分
    /// 两类，第一类是全双工，第二类是多模态，第三类是图文或纯文本这种」。
    ///
    /// **全双工两条是"能理解"的模型进清单，接线是另一回事**：三段式的理解现在
    /// 走 `BailianVisionChatAPI`（HTTP 图文），实时全双工模型当理解要开实时会话，
    /// 这条路还没接 —— 选中后先记录在角色上，接线上是下一批的事。
    static let understandingModelChoices: [(category: String, choice: ModelChoice)] = [
        (
            "全双工语音",
            ModelChoice(
                id: "qwen-audio-3.0-realtime-flash",
                displayName: "3.0 Flash",
                architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
                priceNote: "音频入 6 · 文本出 4.5",
                supportsVision: false
            )
        ),
        (
            "全双工语音",
            ModelChoice(
                id: "qwen-audio-3.1-realtime-plus",
                displayName: "3.1 Plus",
                architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
                priceNote: "音频入 40 · 文本出 40",
                supportsVision: false
            )
        ),
        (
            "多模态",
            ModelChoice(
                id: "qwen3.8-omni-flash-realtime",
                displayName: "3.8 Omni Flash",
                architectureNote: "全模态实时 · 支持文字、图像、语音输入输出",
                priceNote: "图文入 1.5 · 音频入 6 · 文本出 4.5 · 音频出 12",
                supportsVision: true
            )
        ),
        (
            "多模态",
            ModelChoice(
                id: "qwen3.5-omni-flash-realtime-2026-03-15",
                displayName: "3.5 Omni Flash",
                architectureNote: "全模态实时 · 上一代 · 输出仅对音频计费",
                priceNote: "图文入 3.3 · 音频入 27 · 文本出 20 · 音频出 107",
                supportsVision: true
            )
        ),
        (
            "图文 / 纯文本",
            ModelChoice(
                id: "deepseek-flash",
                displayName: "DeepSeek Flash",
                architectureNote: "文本+图片理解 · 开摄像头/屏幕必须用它",
                priceNote: "入 0.3 · 出 1.2",
                supportsVision: true
            )
        ),
    ]

    /// 「表达」的候选（合成模型），同样按用户的分类法（2026-09-24 原话）：
    /// 「表达这块也分成两类，第一类是全双工，第二类是 TTS」。
    /// 全双工两条的接线同样是"下一批"：三段式的实时合成还没接全双工音色，
    /// 选中先记录。
    static let expressionModelChoices: [(category: String, choice: ModelChoice)] = [
        (
            "全双工语音",
            ModelChoice(
                id: "qwen-audio-3.0-realtime-flash",
                displayName: "3.0 Flash",
                architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
                priceNote: "音频入 6 · 文本出 4.5 · 音频出 12",
                supportsVision: false
            )
        ),
        (
            "全双工语音",
            ModelChoice(
                id: "qwen-audio-3.1-realtime-plus",
                displayName: "3.1 Plus",
                architectureNote: "全双工语音模型（识别、理解、表达）· 支持文字、图像输入输出",
                priceNote: "音频入 40 · 文本出 40 · 音频出 150",
                supportsVision: false
            )
        ),
        (
            "TTS",
            ModelChoice(
                id: "qwen-audio-3.1-tts-flash",
                displayName: "3.1 TTS Flash",
                architectureNote: "支持音色克隆 + 68 个系统音色",
                priceNote: "按字符计费",
                supportsVision: false
            )
        ),
    ]

    /// 「全双工全模态」可选的**实时全模态模型**（用户 2026-09-24 指定补充）。
    ///
    /// 一个模型包办识别/理解/表达，所以三栏都由它接管；`supportsVision` 是真的 ——
    /// 官方文档：Qwen-Omni-Realtime「能同时理解流式的音频与图像输入（例如从视频流中
    /// 实时抽取的连续图像帧）」。
    ///
    /// 价格取自官方《模型调用价格》千问 Omni-Realtime 表，**华北2（北京）**地域
    /// （2026-09-24 抓取，元/每百万 tokens；Qwen3.5-Omni-Realtime 系列输出仅对音频
    /// 计费，对应文本不计费）：
    ///
    /// | 模型 | 图/文/视频入 | 音频入 | 文本出 | 音频出 |
    /// |---|---|---|---|---|
    /// | qwen3.8-omni-flash-realtime | 1.5 | 6 | 4.5 | 12 |
    /// | qwen3.5-omni-flash-realtime-2026-03-15 | 3.3 | 27 | 20 | 107 |
    /// | qwen3.5-omni-plus-realtime-2026-03-15 | 10 | 80 | 60 | 300 |
    static let omniModelChoices: [ModelChoice] = [
        ModelChoice(
            id: "qwen3.8-omni-flash-realtime",
            displayName: "3.8 Omni Flash",
            architectureNote: "全模态实时（识别、理解、表达）· 支持文字、图像、语音输入输出",
            priceNote: "图文入 1.5 · 音频入 6 · 文本出 4.5 · 音频出 12",
            supportsVision: true
        ),
        ModelChoice(
            id: "qwen3.5-omni-flash-realtime-2026-03-15",
            displayName: "3.5 Omni Flash",
            architectureNote: "全模态实时 · 上一代 · 输出仅对音频计费",
            priceNote: "图文入 3.3 · 音频入 27 · 文本出 20 · 音频出 107",
            supportsVision: true
        ),
        ModelChoice(
            id: "qwen3.5-omni-plus-realtime-2026-03-15",
            displayName: "3.5 Omni Plus",
            architectureNote: "全模态实时 · 上一代旗舰 · 输出仅对音频计费",
            priceNote: "图文入 10 · 音频入 80 · 文本出 60 · 音频出 300",
            supportsVision: true
        ),
    ]

    // MARK: - 全双工全模态

    /// 全模态的 10 个内置音色 —— 官方 omni 音色列表逐字确认。
    static let omniVoices: [VoiceOption] = [
        VoiceOption(id: "Ethan", displayName: "Ethan", note: "阳光男声"),
        VoiceOption(id: "Cherry", displayName: "Cherry", note: "阳光女声", modelFamily: "v3"),
        VoiceOption(id: "Tina", displayName: "Tina", note: "甜美女声"),
        VoiceOption(id: "Dylan", displayName: "Dylan", note: "沉稳男声"),
        VoiceOption(id: "Jennifer", displayName: "Jennifer", note: "知性女声"),
        VoiceOption(id: "Kai", displayName: "Kai", note: "活力男声", modelFamily: "v3"),
        VoiceOption(id: "Momo", displayName: "Momo", note: "活泼女声"),
        VoiceOption(id: "Ryan", displayName: "Ryan", note: "磁性男声"),
        VoiceOption(id: "Serena", displayName: "Serena", note: "qwen3.5 新增", modelFamily: "v35"),
        VoiceOption(id: "Aiden", displayName: "Aiden", note: "qwen3.5 新增", modelFamily: "v35"),
    ]

    // MARK: - 全双工语音（按模型版本）

    /// 3.0 Plus/Flash 与 3.1 Plus **共有**的 5 个系统音色。
    static let duplexSharedVoices: [VoiceOption] = [
        VoiceOption(id: "longanqian", displayName: "longanqian"),
        VoiceOption(id: "longanlingxin", displayName: "龙安灵心"),
        VoiceOption(id: "longanlingxi", displayName: "龙安灵希"),
        VoiceOption(id: "longanxiaoxin", displayName: "longanxiaoxin"),
        VoiceOption(id: "longanlufeng", displayName: "longanlufeng"),
    ]

    /// **仅 3.1 Plus 新增**的 8 个。名字只在官方 3.1 音色表确实给出时才写，
    /// 其余保持原 id —— 不编中文名。
    static let duplex31OnlyVoices: [VoiceOption] = [
        VoiceOption(id: "longanqian_v3.1", displayName: "longanqian_v3.1"),
        VoiceOption(id: "longanhuan_v3.1", displayName: "龙安欢"),
        VoiceOption(id: "longanlingxin_v3.1", displayName: "龙安灵心"),
        VoiceOption(id: "longanfengyue_v3.1", displayName: "龙安风悦"),
        VoiceOption(id: "xunanchuan_v3.1", displayName: "许南川"),
        VoiceOption(id: "beth_v3.1", displayName: "beth_v3.1"),
        VoiceOption(id: "betty_v3.1", displayName: "betty_v3.1"),
        VoiceOption(id: "cally_v3.1", displayName: "cally_v3.1"),
    ]

    // MARK: - 查询

    /// 全双工模式下可以选的**全部**模型：全双工语音（不能吃画面）+ 全双工全模态（能吃画面）。
    ///
    /// 注意：**这是"能力清单"，不是"某个聊天类型能选的清单"**。语音聊天只出全双工语音
    /// 那一半（用户 2026-09-24 确认的严格限制），过滤发生在预设层
    /// （`VoiceChatPreset.presets(for:engine:)`），不在这一份数据上。
    static var fullDuplexModelChoices: [ModelChoice] {
        duplexModelChoices + omniModelChoices
    }

    /// 可复制给 AI 的**模型清单**（按类别分组）。
    ///
    /// 用户 2026-09-25：「这些可选择的模型可以通过折叠按钮展开，点击复制按钮就能自动复制」
    /// —— 设置页的角色编辑器里用它列「这个模式还能用哪些模型」。列的是**完整 id**，
    /// 因为复制出去是给 AI 看的，短名（3.0 Flash）它认不出来。
    ///
    /// 分两族：全双工那一行给**该聊天类型允许**的实时模型（语音聊天只有全双工语音、
    /// 视频聊天才是全模态 —— 用户定的严格限制）；三段式给三个位置的候选。
    static func modelInventory(
        for engine: VoiceChatEngine,
        channel: VoiceChatChannel
    ) -> [(category: String, choices: [ModelChoice])] {
        switch engine {
        case .duplexVoice, .omni:
            return channel.allowsVideoInputAtAll
                ? [("全双工 · 全模态（能接收画面）", omniModelChoices)]
                : [("全双工 · 语音（不接收画面）", duplexModelChoices)]
        case .threeStage:
            var groups: [(String, [ModelChoice])] = [
                ("识别（听）", recognitionModelChoices.map(\.choice)),
                ("理解（想）", understandingModelChoices.map(\.choice)),
                ("表达（说）", expressionModelChoices.map(\.choice)),
            ]
            groups.insert(("全双工语音模型（可当识别/理解/表达）", duplexModelChoices), at: 0)
            return groups
        }
    }

    static func modelChoice(withID modelID: String) -> ModelChoice? {
        if let match = duplexModelChoices.first(where: { $0.id == modelID }) { return match }
        if let match = omniModelChoices.first(where: { $0.id == modelID }) { return match }
        if let match = recognitionModelChoices.first(where: { $0.choice.id == modelID })?.choice { return match }
        if let match = understandingModelChoices.first(where: { $0.choice.id == modelID })?.choice { return match }
        return expressionModelChoices.first(where: { $0.choice.id == modelID })?.choice
    }

    /// 这个模型能不能**理解图片**（截图 / 摄像头画面）。
    ///
    /// 判据来自用户 2026-09-24 的定义：「只要这个模型能理解图片就可以，它可能是图文的，
    /// 可能是全模态的，也可能是多模态的」。认不出来的模型一律当作**不能** ——
    /// 猜它支持会让用户开着一个什么都不送的开关。
    static func modelCanUnderstandImages(_ modelID: String) -> Bool {
        modelChoice(withID: modelID)?.supportsVision ?? false
    }

    /// 这个 id 是不是**实时模型**（`qwen-audio-*-realtime-*` / `qwen*-omni-*-realtime`）。
    ///
    /// 它决定「理解」这一步走哪条管线：实时走 WebSocket 会话（喂文字收文字），
    /// 其余走 HTTP 图文。**这正是"每个预设背后是一条不同的管线"的落点**
    /// （用户 2026-09-24：「每一个预设背后都是不同的管线」）。
    ///
    /// 注意 ASR 系（`qwen3-asr-flash-realtime`）虽然名字里有 realtime，但它只会转写、
    /// 不会生成回复；它出现在「理解」位置的情况被清单本身挡住了（识别的清单里才有它）。
    static func isRealtimeModel(_ modelID: String) -> Bool {
        modelID.contains("realtime") && !modelID.contains("asr")
    }

    /// 这个 id 是不是全模态（omni）实时模型 —— 决定它用哪张音色表。
    static func isOmniRealtimeModel(_ modelID: String) -> Bool {
        modelID.contains("omni")
    }

    /// 当前选择下的**依赖真相**。
    ///
    /// 用户 2026-09-24 的原话：「你当前所做的所有功能，只不过是一个样式，它并没有
    /// 真正实现功能，也没有真正实现相互之间的依赖关系」——这个类型就是那条依赖关系
    /// **唯一的一处实现**。界面和引擎读同一份：界面据此置灰与留空，引擎据此取音色，
    /// 于是"看得见"和"真的会生效"在结构上不可能分家。
    nonisolated struct VoiceChatCapability {
        /// 屏幕 / 摄像头能不能开。
        let isVideoInputAllowed: Bool
        /// 主音色族 —— 决定用哪张音色表。
        let effectiveVoiceEngine: VoiceChatEngine
        /// 引擎**真正会用的**那个音色 id（已校验；非法的会被换成兜底值）。
        let effectiveVoiceID: String
        /// 音色面板里哪几族可以点。空 = 现在没有可用的音色族。
        let usableVoiceEngines: [VoiceChatEngine]
        /// 画面为什么不能开（nil = 能开）。
        let videoDisabledReason: String?
        /// 给用户看的说明（自动纠正、未接线等），由界面逐条显示。
        let notes: [String]
    }

    /// 算出当前预设下的依赖真相。见 `VoiceChatCapability`。
    static func capability(
        for preset: VoiceChatPreset,
        channel: VoiceChatChannel,
        role: VoiceChatRole
    ) -> VoiceChatCapability {
        var notes: [String] = []

        // ── 音色族：全双工看"那一个模型"，三段式看"表达" ──────────────────────
        let voiceEngine: VoiceChatEngine
        let voiceModelID: String
        let storedVoiceID: String
        var usableVoiceEngines: [VoiceChatEngine]

        switch preset.engine {
        case .duplexVoice:
            let modelID = preset.duplexModelID ?? defaultDuplexModel
            let isOmni = isOmniRealtimeModel(modelID)
            voiceEngine = isOmni ? .omni : .duplexVoice
            voiceModelID = modelID
            storedVoiceID = isOmni ? role.omniVoice : role.duplexVoice
            usableVoiceEngines = [voiceEngine]

        case .threeStage, .omni:
            let expressionModelID = preset.expressionModelID ?? defaultExpressionModel
            voiceModelID = expressionModelID
            if expressionModelID.contains("tts") {
                // 合成音色（系统 + 克隆）只属于 TTS 族。
                voiceEngine = .threeStage
                storedVoiceID = role.ttsVoice
                usableVoiceEngines = [.threeStage]
            } else {
                // 表达用的是实时模型：音色得由那个模型自己发声，这条链路还没接。
                // 此时**没有可用的音色族** —— 界面据此把音色按钮置灰。
                voiceEngine = isOmniRealtimeModel(expressionModelID) ? .omni : .duplexVoice
                storedVoiceID = ""
                usableVoiceEngines = []
                notes.append(
                    "表达用的是实时模型（\(expressionModelID)）：它用自己的声音说话，这条合成链路还没接，所以音色暂时不生效。"
                )
            }
        }

        // 预设自带的音色优先于角色上的存储值（预设换了，音色跟着换才有意义），
        // 但它同样要过一遍合法性检查。
        let preferredVoiceID = preset.preferredVoiceID ?? storedVoiceID
        let effectiveVoiceID = legalVoice(
            preferredVoiceID,
            for: voiceEngine,
            model: voiceModelID,
            notes: &notes
        )

        // ── 画面：聊天类型是硬闸，模型能不能吃图是第二道闸 ────────────────────
        let understandingModelID = preset.engine == .threeStage
            ? (preset.understandingModelID ?? defaultUnderstandingModel)
            : (preset.duplexModelID ?? defaultDuplexModel)
        let modelCanSee = modelCanUnderstandImages(understandingModelID)
        let isVideoInputAllowed = channel.allowsVideoInputAtAll && modelCanSee

        let videoDisabledReason: String?
        if !channel.allowsVideoInputAtAll {
            videoDisabledReason = "语音聊天不用画面"
        } else if !modelCanSee {
            videoDisabledReason = "所选模型（\(understandingModelID)）不能理解图片，屏幕和摄像头在它上面用不了"
        } else {
            videoDisabledReason = nil
        }

        return VoiceChatCapability(
            isVideoInputAllowed: isVideoInputAllowed,
            effectiveVoiceEngine: voiceEngine,
            effectiveVoiceID: effectiveVoiceID,
            usableVoiceEngines: usableVoiceEngines,
            videoDisabledReason: videoDisabledReason,
            notes: notes
        )
    }

    /// 存储的音色合法就用它，不合法换成该族的兜底值，并记一条给人看的说明。
    ///
    /// **引擎永远拿不到非法音色**：跨族音色会让整条 `session.update` 被拒（实测
    /// `Unsupported voice: 'Tina'`），而那句错误完全不提音色 —— 与其让服务端拒，
    /// 不如在这里换掉并说清楚。
    private static func legalVoice(
        _ storedVoiceID: String,
        for engine: VoiceChatEngine,
        model: String,
        notes: inout [String]
    ) -> String {
        let trimmed = storedVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSelectable(trimmed, for: engine, model: model) { return trimmed }
        let fallback = fallbackVoice(for: engine, model: model)
        if !trimmed.isEmpty {
            notes.append("音色「\(trimmed)」不属于当前模型，已自动改用「\(fallback)」。")
        }
        return fallback
    }

    /// 当前模式 + 当前模型下**可以选**的系统音色。
    static func systemVoices(for engine: VoiceChatEngine, model: String) -> [VoiceOption] {
        switch engine {
        case .threeStage:
            return threeStageVoices
        case .omni:
            let family = omniModelFamily(for: model)
            return omniVoices.filter { $0.modelFamily.isEmpty || $0.modelFamily == family }
        case .duplexVoice:
            return duplexSharedVoices + (is31PlusDuplex(model) ? duplex31OnlyVoices : [])
        }
    }

    /// 选中的音色不在当前模式/模型的表里时，用它兜底。
    ///
    /// 兜底**不是**可选的礼貌：跨家族音色会让整条 `session.update` 被拒，
    /// 所以宁可换一个能用的音色并说明，也不能把用户选的填进去。
    static func fallbackVoice(for engine: VoiceChatEngine, model: String) -> String {
        switch engine {
        case .threeStage:
            return threeStageVoices.first?.id ?? ""
        case .omni:
            // 官方把 Ethan 定为全模态的默认音色。
            return "Ethan"
        case .duplexVoice:
            // 官方：3.1 Plus 默认 `longanqian_v3.1`，3.0 Plus/Flash 默认 `longanqian`。
            return is31PlusDuplex(model) ? "longanqian_v3.1" : "longanqian"
        }
    }

    /// 这个音色能不能用在当前模式 + 模型上。
    ///
    /// 判据分两步，第二步是让**克隆音色**通过的关键：克隆出来的 id 是不透明的
    /// （形如 `qwen-audio-3.1-tts-flash-zjm-7f08…`），不可能出现在任何内置表里，
    /// 所以只能反过来问 —— 它是不是**别的家族的**系统音色？是就拒，不是就放行。
    static func isSelectable(_ voice: String, for engine: VoiceChatEngine, model: String) -> Bool {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if systemVoices(for: engine, model: model).contains(where: { $0.id == trimmed }) { return true }

        // **本族、但不是「本代」的系统音色，对这个模型同样不合法。**
        //
        // 实测（2026-09-25，日志原文）：默认全双工模型 `qwen-audio-3.0-realtime-flash`
        // 发出去的 `voice` 是 `longanqian_v3.1`（3.1 那一代的名字），服务端把**整条
        // `session.update`** 拒了，并在错误里回出它真正支持的清单：
        //
        //   Unsupported voice: 'longanqian_v3.1'.
        //   Supported voices: longanqian, longanlingxin, … , longanhuan_v3.6, … , sherry
        //
        // 3.0 这一代要的是 `longanqian`（**没有后缀**），清单里带 `_v3.1` 的一个都没有。
        //
        // 原先这里只判"是不是外族"，而 `longanqian_v3.1` 属于本族 → 放行 → 会话连不上。
        // 后果比一句音色错误严重得多：界面立刻挂断、相位回 idle，用户看到的是
        // **「刘海左右两侧什么都不显示」**，而不是"音色选错了"。
        //
        // 所以判据收紧成：在本引擎**全部**系统音色里出现过、但不在**本模型**可用列表里
        // 的，一律判非法 —— 它会走 `legalVoice` 换成该模型的兜底音色，并给出一条说明。
        if allSystemVoices(for: engine).contains(where: { $0.id == trimmed }) { return false }

        return !isForeignSystemVoice(trimmed, for: engine)
    }

    /// 本引擎**所有代数**的系统音色（不按模型过滤）。
    ///
    /// 只用来回答"这个 id 是不是我们自己的音色" —— 是，但不在本模型列表里，
    /// 那就属于"异代"，见 `isSelectable`。与 `systemVoices(for:model:)` 的区别
    /// 正是**有没有按模型过滤**，两者不要合并。
    private static func allSystemVoices(for engine: VoiceChatEngine) -> [VoiceOption] {
        switch engine {
        case .threeStage:
            return threeStageVoices
        case .omni:
            return omniVoices
        case .duplexVoice:
            return duplexSharedVoices + duplex31OnlyVoices
        }
    }

    /// 是不是**别的**模式的内置系统音色。
    private static func isForeignSystemVoice(_ voice: String, for engine: VoiceChatEngine) -> Bool {
        switch engine {
        case .threeStage:
            return omniVoices.contains { $0.id == voice }
                || duplexSharedVoices.contains { $0.id == voice }
                || duplex31OnlyVoices.contains { $0.id == voice }
        case .omni:
            // 官方只列了这 10 个；克隆音色在全模态下**未经验证**，所以除了表里的
            // 一律拒 —— 这一条比 VoiceWeb 更严，因为配错是延迟到 response 才报。
            return true
        case .duplexVoice:
            return omniVoices.contains { $0.id == voice }
                || threeStageVoices.contains { $0.id == voice }
        }
    }

    /// 全模态的模型族：`qwen3.5` 开头是 v35，其余是 v3。
    static func omniModelFamily(for model: String) -> String {
        model.hasPrefix("qwen3.5") ? "v35" : "v3"
    }

    /// 这个全双工模型是不是 3.1 Plus 系（决定 `_v3.1` 那 8 个音色能不能选）。
    static func is31PlusDuplex(_ model: String) -> Bool {
        model.hasPrefix("qwen-audio-3.1")
    }
}
