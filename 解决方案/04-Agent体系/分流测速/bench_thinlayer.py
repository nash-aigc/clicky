#!/usr/bin/env python3
"""一次调用·两问分流基准 —— JEV 薄层：脚本池匹配 + 三分类，同价双答案。

用户 2026-09-25 的定案（原话摘要）：
  「关键词匹配这一层也改用 JEV 做——先匹配用户需求与已固化的量化脚本，
    同时匹配它与纯视觉/纯文本/执行类的关系，把推荐度做排名：
    命中脚本优先执行脚本，没命中就按分类走。两层合成一个薄层。」

官方依据（05-手册 §3.3，实测数字）：一次调用问多题按"次"计费不按题——
2 题比 1 题只多 $0.0000014（约 1/10 增量）。所以"两层"的正确实现就是
**一次调用里的两个 question**，排名由代码比较两个 confidence 完成（零模型）。

判据表来自真 catalog.json 的条目（label + when 语义），no_match 占位符照旧。
每题返回：{script: {choice, confidence}, cls: {choice, confidence}}。

密钥：读 JEV 自己的 .env（jev.load_credentials），不回显。
"""
import json
import sys

sys.path.insert(0, "/Users/mjm/Documents/SuperAgent/Agent/Wanna/instant-agent")
import jev  # noqa: E402

# ── 脚本池：真 catalog 条目抽 14 条（含埋雷句的诱饵：计算器/蓝牙/音量）──
CATALOG = {
    "open_calculator": "打开计算器 App",
    "open_wechat": "打开微信 App",
    "open_safari": "打开 Safari 浏览器",
    "settings_bluetooth": "打开系统设置里的蓝牙面板",
    "volume_set": "把系统音量设置为一个明确数值",
    "mute": "把系统静音",
    "brightness_set": "把屏幕亮度设置为一个明确百分比",
    "lock": "立即锁定屏幕",
    "screenshot_clip": "截屏并把图存进剪贴板",
    "empty_trash": "清空废纸篓",
    "hide_others": "隐藏除当前应用以外的所有应用窗口",
    "dark_mode": "切换系统的深色/浅色模式",
    "tile_left": "把当前窗口贴到屏幕左半",
    "clock_now": "报告现在的时间或日期",
}

# ── 三分类（上一轮已 19/19 的题面，原样搬）──────────────────────────
CLASSES = {
    "纯文本": "回答这句话只需要文字本身（翻译、写作、问答、讲解、读屏问答）。"
              "注意：句子里出现了执行词不代表要执行——被引用、被翻译、"
              "被当例子的执行词不算执行请求。",
    "纯视觉": "要让光标飞到某个位置、画圈、画箭头、画图讲解——屏幕上多了指示"
              "或图形，但 App、系统、文件不发生任何变化。",
    "混合执行": "要让机器状态真的变化：点击、打字、开关 App、调节音量亮度、"
                "读写文件。一句话里既有执行又有其他意图时也算这一类。",
}

GATE = 0.55  # 与 jev.py 的 CONF_GATE 同源

# 句子：上一轮的 19 条难句 + 3 条误触发回归例；期望是（脚本 or None, 类）
SENTENCES = [
    ("请翻译一下打开计算器这六个字", None, "纯文本", "执行词在引号里"),
    ("打开蓝牙设置这个说法是什么意思", None, "纯文本", "哨兵词"),
    ("帮我写一篇文章，里面举个例子说明怎么打开 Safari", None, "纯文本", "写作嵌 App 名"),
    ("如果我说打开微信，会发生什么", None, "纯文本", "条件句"),
    ("翻译成英文：把音量调到最大", None, "纯文本", "执行词是翻译对象"),
    ("open Safari for me", "open_safari", "混合执行", "英语直接执行"),
    ("set my volume to 30", "volume_set", "混合执行", "英语参数化执行"),
    ("在计算器里看一下数字7，然后去 Google 搜一下它是什么星座",
     None, "混合执行", "跨App多意图：单条脚本接不住"),
    ("打开微信，然后把刚才那句话发给他", None, "混合执行", "指代+多步"),
    ("把屏幕亮度调成 70，顺便告诉我现在几点了", None, "混合执行", "执行+问答混合"),
    ("圈出截图里那个报错的位置", None, "纯视觉", "只画不动"),
    ("在第一个按钮那里画个圈标一下", None, "纯视觉", "指位画圈"),
    ("帮我点一下屏幕上的登录按钮", None, "混合执行", "真点击，非固定脚本"),
    ("鼠标飞到设置图标那里指一下就行，别点", None, "纯视觉", "「别点」排除执行"),
    ("静音", "mute", "混合执行", "裸高频指令：应命中脚本"),
    ("刚才那个圈画得不对，音量倒是没问题，再帮我静音一次",
     None, "混合执行", "回顾+本轮诉求；口语长句不该命表"),
    ("「删除」在英文里是不是就是 backspace 的意思", None, "纯文本", "词义问答"),
    ("先别动，我是想问点登录按钮一般要等多久才有反应", None, "纯文本", "对动作的提问"),
    ("帮我看看屏幕上有多少个图标", None, "纯文本", "读屏问答"),
    # ── 三条误触发回归例（本设计的靶子）──────────────────────
    ("在计算器里看一下数字然后搜索", None, "混合执行", "回归例1"),
    ("请翻译打开计算器", None, "纯文本", "回归例2"),
    ("打开某软件，然后翻译，请打开计算器", None, "混合执行", "回归例3：泛化App名+多步"),
    # ── 正向对照：这些必须命中脚本，否则薄层白造 ──────────────
    ("打开计算器", "open_calculator", "混合执行", "正例"),
    ("清空废纸篓", "empty_trash", "混合执行", "正例"),
    ("把别的窗口都藏起来", "hide_others", "混合执行", "正例"),
    ("现在几点了", "clock_now", "混合执行", "正例（或纯文本，两可——记录）"),
]


def run_one(need: str):
    r = jev.ask(need, {
        "script": jev.choice_q(
            "这条需求是否完全等于下面某一条已固化操作？只有用户想要的"
            "就是该条本身（参数也给得出）才算；句子里只是**提到/引用/翻译**"
            "这些操作，或需求是多步/带指代/比该条多任何东西，都不算——选 no_match。",
            {**CATALOG, jev.NO_MATCH: jev.NO_MATCH_CRITERION}),
        "cls": jev.choice_q("判断这条需求属于哪一类任务。", CLASSES),
    })
    if r.get("error"):
        return None, r
    a = r["answers"] or {}
    return a, r


def main():
    rows = []
    for sent, exp_script, exp_cls, why in SENTENCES:
        a, r = run_one(sent)
        if a is None:
            print(f"调用失败：{r.get('error')}  ｜ {sent}")
            continue
        sc = (a.get("script") or {})
        cc = (a.get("cls") or {})
        got_script = sc.get("choice")
        got_cls = cc.get("choice")
        sconf = float(sc.get("confidence") or 0)
        cconf = float(cc.get("confidence") or 0)
        # 排名规则（纯代码）：脚本题非 no_match 且 conf≥门槛 → 走脚本
        decision = (f"脚本:{got_script}" if got_script != jev.NO_MATCH and sconf >= GATE
                    else f"分类:{got_cls}")
        ok_s = (got_script == exp_script) if exp_script else \
               (got_script == jev.NO_MATCH or sconf < GATE)
        ok_c = got_cls == exp_cls
        rows.append({"q": sent, "why": why, "expect_script": exp_script,
                     "script": got_script, "script_conf": sconf,
                     "expect_cls": exp_cls, "cls": got_cls, "cls_conf": cconf,
                     "decision": decision, "script_ok": ok_s, "cls_ok": ok_c,
                     "ms": r["latency_ms"], "cost": r["cost"]})
        print(f"{sent[:26]:<28} 脚本:{got_script}({sconf:.2f}) "
              f"类:{got_cls}({cconf:.2f}) → {decision} "
              f"{'✓✓' if ok_s and ok_c else '✗'} {r['latency_ms']}ms  {why}")

    n = len(rows)
    cs = sum(r["script_ok"] for r in rows)
    cc_ = sum(r["cls_ok"] for r in rows)
    both = sum(r["script_ok"] and r["cls_ok"] for r in rows)
    ms = sorted(r["ms"] for r in rows)
    med = ms[len(ms) // 2] if ms else 0
    print(f"\n== 汇总（{n} 句，一次调用两问）==")
    print(f"脚本题对 {cs}/{n} · 分类题对 {cc_}/{n} · 双题全对 {both}/{n} · 中位 {med}ms")
    bad = [r for r in rows if not (r["script_ok"] and r["cls_ok"])]
    for r in bad:
        print(f"  偏差：{r['q']} ｜期望 脚本{r['expect_script']}/类{r['expect_cls']}"
              f" → 实得 {r['script']}({r['script_conf']:.2f})/{r['cls']}({r['cls_conf']:.2f})")
    total_cost = sum(r["cost"] for r in rows)
    print(f"总成本 ${total_cost:.6f}（{n} 次调用两问）")
    dest = "/Users/mjm/Documents/SuperAgent/APP/Design/wanna/解决方案/04-Agent体系/分流测速/薄层两问结果.json"
    json.dump({"rows": rows, "score": {"script_ok": f"{cs}/{n}",
                                       "cls_ok": f"{cc_}/{n}",
                                       "both_ok": f"{both}/{n}",
                                       "median_ms": med,
                                       "total_cost_usd": total_cost}},
              open(dest, "w"), ensure_ascii=False, indent=1)
    print(f"结果文件：{dest}")


if __name__ == "__main__":
    main()
