#!/usr/bin/env python3
"""一次调用·四问定案基准 —— 2026-09-25 最终架构：目标分类 × 方案分类 × 脚本池 × 点名。

用户定案（原话摘要）：
  「按用户的需求来分类标签。目标三类：图形（UI性显示）/ 文字（生成内容）/ 执行（混合）。
    每一类再分两种方案：系统直出（提示词写进系统提示词，模型直接产出结果，第一优先级）
    和 agent 类（封闭 agent + 外循环，≤10 次失败交 Claude Code，再失败通知用户）。
    所有工具/脚本/MCP 全交给 JEV 看，减少 token；大模型只看到选择之后的结果。」

本脚本验证：这四个问题能否装进**一次** JEV 调用、答案是否够准。
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ.get(
    "WANNA_INSTANT_AGENT",
    str(Path.home() / "Documents/SuperAgent/Agent/Wanna/instant-agent")))
import jev  # noqa: E402

HERE = Path(__file__).resolve().parent

Q_GOAL = {
    "图形": "用户要在屏幕上**看到**一个图形结果：光标飞过去指、画圈/画框/画箭头、"
            "生成 SVG 图形或图解。机器状态不变，变的是屏幕上的画面。",
    "文字": "用户要的是一段文字本身：问答、翻译、写作、讲解、总结——"
            "包括那些需要查知识库/翻文件才能回答、但产出仍是文字的需求。",
    "执行": "用户要让机器状态真的变化：点、按、打字、开关 App、调音量亮度、"
            "读写文件、运行工作流。",
}
Q_WAY = {
    "直出": "不需要任何封闭 agent 或外部工具：主模型拿到提示词就能一次产出"
            "最终结果（坐标、参数、文字），一步完成。",
    "agent": "必须借助封闭 agent / MCP / 技能 / 工具组合才能完成：要查知识库、"
             "要跑多步工具链、要生成复杂产物（如 SVG 图解工程）。",
}
Q_AGENT = {
    # 判据措辞修正（实测 2026-09-25：原「无点名：正常处理」版把「复盘」一句吸走，
    # conf 0.41；把「无点名」改成**否定式判据**后 5/5，复盘句 conf 0.75）。
    # 教训：choice 题里那个"其他/否"选项的判据必须写成对其它选项的否定，
    # 不能只写「没有/正常」——它会被当成一个语义空洞的兜底项吸走近义词。
    "claude-code": "用户话里直接出现了指名词：claude / cloud（语音同音）/ cc / "
                   "Claude Code，并让它去做某事。",
    "复盘": "用户话里直接出现了指名词「复盘」，要求回顾、总结历史任务或提出固化优化。",
    "无点名": "话里读不到上面任何指名词——正常处理。",
}
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

SENTENCES = [
    # (句子, 期望点名, 期望目标, 期望方案, 期望脚本)
    ("打开计算器", "无点名", "执行", "直出", "open_calculator"),
    ("帮我把音量调到 30", "无点名", "执行", "直出", "volume_set"),
    ("把这个按钮圈出来", "无点名", "图形", "直出", None),
    ("画个流程图给我讲讲 TCP 三次握手", "无点名", "图形", "agent", None),
    ("我昨天做了什么", "无点名", "文字", "agent", None),
    ("一加一等于几", "无点名", "文字", "直出", None),
    ("帮我把这段总结存到我的 Notion 笔记里", "无点名", "执行", "agent", None),
    ("翻译成英文：把音量调到最大", "无点名", "文字", "直出", None),
    ("用 Claude Code 帮我调研一下这个报错", "claude-code", None, None, None),
    ("帮我复盘一下最近的任务", "复盘", None, None, None),
]


def run(need):
    return jev.ask(need, {
        "goal": jev.choice_q("这条需求的目标是什么？", Q_GOAL),
        "way": jev.choice_q(
            "完成它需不需要封闭 agent / 外部工具 / 多步工具链？", Q_WAY),
        "agent": jev.choice_q("用户是否点名了某个专门执行体？", Q_AGENT,
                              "只有话里能直接读到指名词才算点名。"),
        "script": jev.choice_q(
            "这条需求是否完全等于下面某一条已固化操作？只是提到/引用/翻译、"
            "多步、带指代、比该条多任何东西，都选 no_match。",
            {**CATALOG, jev.NO_MATCH: jev.NO_MATCH_CRITERION}),
    })


def main():
    rows = []
    for sent, ea, eg, ew, es in SENTENCES:
        r = run(sent)
        if r.get("error"):
            print("调用失败", sent, r["error"]); continue
        a = r["answers"] or {}
        g = (a.get("goal") or {}); w = (a.get("way") or {})
        ag = (a.get("agent") or {}); sc = (a.get("script") or {})
        row = {"q": sent, "goal": g.get("choice"), "goal_conf": g.get("confidence"),
               "way": w.get("choice"), "way_conf": w.get("confidence"),
               "agent": ag.get("choice"), "agent_conf": ag.get("confidence"),
               "script": sc.get("choice"), "script_conf": sc.get("confidence"),
               "ms": r["latency_ms"], "cost": r["cost"],
               "expect": {"agent": ea, "goal": eg, "way": ew, "script": es}}
        hits = []
        if ea: hits.append(row["agent"] == ea)
        if eg: hits.append(row["goal"] == eg)
        if ew: hits.append(row["way"] == ew)
        if es: hits.append(row["script"] == es)
        elif ea is None: hits.append(row["script"] == jev.NO_MATCH
                                     or (row["script_conf"] or 0) < 0.55)
        row["hit"] = all(hits)
        rows.append(row)
        print(f"{sent[:24]:<26} 目标:{row['goal']}({row['goal_conf']}) "
              f"方案:{row['way']}({row['way_conf']}) "
              f"点名:{row['agent']}({row['agent_conf']}) "
              f"脚本:{row['script']}({row['script_conf']}) "
              f"{'✓' if row['hit'] else '✗'} {row['ms']}ms")
    n = len(rows); h = sum(r["hit"] for r in rows)
    ms = sorted(r["ms"] for r in rows)
    print(f"\n== {h}/{n} · 中位 {ms[len(ms)//2]}ms · "
          f"总成本 ${sum(r['cost'] for r in rows):.6f}（{n} 次·每次四问）==")
    dest = str(HERE / "一次四问结果.json")
    json.dump({"rows": rows, "score": {"hit": f"{h}/{n}",
                                       "median_ms": ms[len(ms)//2] if ms else 0,
                                       "total_cost_usd": sum(r["cost"] for r in rows)}},
              open(dest, "w"), ensure_ascii=False, indent=1)
    print("结果文件：", dest)


if __name__ == "__main__":
    main()
