#!/usr/bin/env python3
"""一次调用·三问定案基准 —— JEV 薄层的最终形态。

用户 2026-09-25 定案（原话摘要）：
  「一次就可以了，但这一次必须包含所有全量已固化的脚本（甚至不需要参数的），
    还要包含标签化 agent——Claude Code 有没有这样的词、复盘有没有这样的词。
    有点名词直接调那个 agent；没有就先分类，然后做加权：脚本优先级高，
    没碰到脚本才用次优先级。发送两次 API 不如一次把问题问清楚。」

于是这一层 = **一次 JEV 调用，三个 question**：
  q_agent  点名：claude-code / 复盘 / 无点名
  q_script 脚本池全量 choice（≤254 + no_match，超限才分片——jev.screen 已有）
  q_cls    三分类：纯文本 / 纯视觉 / 混合执行
仲裁纯代码（零模型）：点名 > 脚本（且须分类题同判混合执行）> 分类 > 低置信兜底纯文本。
"""
import json
import sys

sys.path.insert(0, "/Users/mjm/Documents/SuperAgent/Agent/Wanna/instant-agent")
import jev  # noqa: E402

GATE = 0.55
AGENT_GATE = 0.80   # 点名是"明确说了才算"，阈值刻意高于普通路由

Q_AGENT = {
    "无点名": "用户没有指名要用哪个专门执行体，正常处理即可。",
    "claude-code": "用户**明确点名**要把这活交给 Claude Code：句子里出现 "
                   "claude / cloud（语音同音）/ cc / Claude Code 这样的指名词，"
                   "并让它去做某事。仅仅话题和代码/文件有关但没点名，不算。",
    "复盘": "用户**明确点名**要复盘：出现「复盘」这样的指名词，"
            "要求回顾历史任务、总结、提出固化优化。",
}
Q_AGENT_RULES = "只有在用户的话里能直接读到指名词才算点名；读不到就选「无点名」。"

# 脚本池：真 catalog.json 全量 81 条的语义标签（这里取 14 条做基准，
# 生产形态是全部 81 条一次装进——上限 254，远未到分片线）
CATALOG = {
    "open_calculator": "打开计算器 App", "open_wechat": "打开微信 App",
    "open_safari": "打开 Safari 浏览器",
    "settings_bluetooth": "打开系统设置里的蓝牙面板",
    "volume_set": "把系统音量设置为一个明确数值", "mute": "把系统静音",
    "brightness_set": "把屏幕亮度设置为一个明确百分比", "lock": "立即锁定屏幕",
    "screenshot_clip": "截屏并把图存进剪贴板", "empty_trash": "清空废纸篓",
    "hide_others": "隐藏除当前应用以外的所有应用窗口",
    "dark_mode": "切换系统的深色/浅色模式", "tile_left": "把当前窗口贴到屏幕左半",
    "clock_now": "报告现在的时间或日期",
}

Q_CLS = {
    "纯文本": "回答这句话只需要文字本身（翻译、写作、问答、讲解、读屏问答）。"
              "句子里被引用、被翻译、被当例子的执行词不算执行请求。",
    "纯视觉": "让光标飞过去指、画圈、画箭头、画图讲解——屏幕多了指示图形，"
              "但 App、系统、文件不发生任何变化。",
    "混合执行": "要让机器状态真的变化：点击、打字、开关 App、调音量亮度、读写文件。"
                "多意图叠加里含执行也算这类。",
}

SENTENCES = [
    # (句子, 期望点名, 期望脚本, 期望类)  — None 表示该维度不参与判分
    ("用 Claude Code 帮我调研一下这个报错", "claude-code", None, None),
    ("cloud，把这份文档重写得更简洁", "claude-code", None, None),
    ("cc 修一下那个项目的登录 bug", "claude-code", None, None),
    ("帮我复盘一下最近的任务，看看有什么能固化成脚本", "复盘", None, None),
    ("这个项目 success 了吗", "无点名", None, "纯文本"),      # 含"cc"字母串不许误点名
    ("打开计算器", "无点名", "open_calculator", "混合执行"),
    ("清空废纸篓", "无点名", "empty_trash", "混合执行"),
    ("现在几点了", "无点名", "clock_now", None),               # 查询脚本，类两可
    ("翻译成英文：把音量调到最大", "无点名", None, "纯文本"),
    ("打开蓝牙设置这个说法是什么意思", "无点名", None, "纯文本"),
    ("在计算器里看一下数字7，然后去Google搜它是谁", "无点名", None, "混合执行"),
    ("圈出截图里那个报错的位置", "无点名", None, "纯视觉"),
    ("帮我看看屏幕上有多少个图标", "无点名", None, None),      # 边界句，记录 conf
    ("静音", "无点名", "mute", None),
]

def run(need):
    r = jev.ask(need, {
        "agent": jev.choice_q("用户是否点名了某个专门执行体？", Q_AGENT, Q_AGENT_RULES),
        "script": jev.choice_q(
            "这条需求是否完全等于下面某一条已固化操作？只有用户想要的就是该条本身"
            "（参数也给得出）才算；句子里只是提到/引用/翻译这些操作，或需求是多步、"
            "带指代、比该条多任何东西，都不算——选 no_match。",
            {**CATALOG, jev.NO_MATCH: jev.NO_MATCH_CRITERION}),
        "cls": jev.choice_q("判断这条需求属于哪一类任务。", Q_CLS),
    })
    return r

def arbitrate(a):
    ag = (a.get("agent") or {})
    sc = (a.get("script") or {})
    cc = (a.get("cls") or {})
    agent, aconf = ag.get("choice"), float(ag.get("confidence") or 0)
    script, sconf = sc.get("choice"), float(sc.get("confidence") or 0)
    cls, cconf = cc.get("choice"), float(cc.get("confidence") or 0)
    if agent in ("claude-code", "复盘") and aconf >= AGENT_GATE:
        return f"点名→{agent}", (agent, aconf, script, sconf, cls, cconf)
    if script != jev.NO_MATCH and sconf >= GATE and (
            cls == "混合执行" or script == "clock_now"):
        return f"脚本→{script}", (agent, aconf, script, sconf, cls, cconf)
    if cconf >= GATE and cls != "纯文本":
        return f"分类→{cls}", (agent, aconf, script, sconf, cls, cconf)
    return "兜底→纯文本", (agent, aconf, script, sconf, cls, cconf)

def main():
    rows = []
    for sent, ea, es, ec in SENTENCES:
        r = run(sent)
        if r.get("error"):
            print(f"调用失败 {sent}: {r['error']}")
            continue
        a = r["answers"] or {}
        decision, (agent, aconf, script, sconf, cls, cconf) = arbitrate(a)
        ok_a = ea is None or agent == ea
        ok_s = (es is None and (script == jev.NO_MATCH or sconf < GATE)) or es == script
        ok_c = ec is None or cls == ec
        # 最终决策期望：点名 > 脚本 > 分类（纯文本期望 = 决策落纯文本，两路皆可）
        exp_decision = None
        if ea in ("claude-code", "复盘"):
            exp_decision = f"点名→{ea}"
        elif es:
            exp_decision = f"脚本→{es}"
        elif ec:
            exp_decision = f"分类→{ec}"
        hit = (exp_decision is None) or (
            decision == exp_decision or
            (ec == "纯文本" and decision.startswith(("分类→纯文本", "兜底"))))
        rows.append({"q": sent, "agent": agent, "agent_conf": aconf,
                     "script": script, "script_conf": sconf,
                     "cls": cls, "cls_conf": cconf, "decision": decision,
                     "expect": exp_decision, "hit": hit,
                     "ms": r["latency_ms"], "cost": r["cost"]})
        print(f"{sent[:26]:<28} A:{agent}({aconf:.2f}) S:{script}({sconf:.2f}) "
              f"C:{cls}({cconf:.2f}) → {decision}  {'✓' if hit else '✗ 期望 '+str(exp_decision)}  {r['latency_ms']}ms")
    n = len(rows)
    hits = sum(r["hit"] for r in rows)
    ms = sorted(r["ms"] for r in rows)
    print(f"\n== 汇总 == 最终决策 {hits}/{n} · 中位 {ms[len(ms)//2]}ms · "
          f"总成本 ${sum(r['cost'] for r in rows):.6f}（{n} 次调用·每次三问）")
    dest = "/Users/mjm/Documents/SuperAgent/APP/Design/wanna/解决方案/04-Agent体系/分流测速/一次三问结果.json"
    json.dump({"rows": rows, "score": {"hit": f"{hits}/{n}",
                                       "median_ms": ms[len(ms) // 2] if ms else 0,
                                       "total_cost_usd": sum(r["cost"] for r in rows)}},
              open(dest, "w"), ensure_ascii=False, indent=1)
    print("结果文件：", dest)

if __name__ == "__main__":
    main()
