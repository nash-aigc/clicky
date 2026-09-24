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
    static let defaultOmniModel = "qwen3.5-omni-flash-realtime"

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
        return !isForeignSystemVoice(trimmed, for: engine)
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
