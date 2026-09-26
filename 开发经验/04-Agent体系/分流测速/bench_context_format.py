#!/usr/bin/env python3
"""追问上下文格式实测 —— 「带两句」vs「带 10 句」vs「带 10 句且标注远近」。

用户 2026-09-25 定案：
  「追问时一定要带两样东西：① 屏幕，必须带屏幕；② 之前的原话、之前的内容。
    带一句话可能不够，至少带 10 轮、10 句，但带太多也没有意义。
    同时一定要标注出来哪一句是最近的、哪一句是上一句、哪些是更早的话，
    让 AI 能区分它们的重点，而不是把它们并列放在一起。」

本脚本量的是"标注远近"这件事本身值不值：同一段 10 句历史，三种塞法，
问同一个指代问题，看 JEV 选得对不对、自信不自信。指代解析是选池题
（池 = 历史里被提到过的 10 个对象），所以用 choice 直接量。
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ.get(
    "WANNA_INSTANT_AGENT",
    str(Path.home() / "Documents/SuperAgent/Agent/Wanna/instant-agent")))
import jev  # noqa: E402

HERE = Path(__file__).resolve().parent

# 10 句历史（由早到晚），每句提到一个不同对象
HISTORY = [
    "打开计算器",          # 1 最早
    "把音量调到 30",       # 2
    "打开蓝牙设置",        # 3
    "圈一下屏幕上那个图标",  # 4
    "把它翻译成英文",      # 5
    "关掉微信",            # 6
    "把亮度调到 70",       # 7
    "现在几点了",          # 8
    "打开 Safari",         # 9
    "打开备忘录",          # 10 上一句（最近）
]
# 池：历史里出现过的对象
POOL = {
    "计算器": "打开计算器 App", "音量": "把系统音量调到某值",
    "蓝牙": "打开蓝牙设置面板", "屏幕图标": "在屏幕上圈一个图标",
    "翻译": "把某段文字翻译成英文", "微信": "关闭微信 App",
    "亮度": "调节屏幕亮度", "时间": "报时",
    "Safari": "打开 Safari", "备忘录": "打开备忘录 App",
}

# 三种上下文塞法
def flat_early_to_late():
    return "（本次会话用户之前说过，按时间从早到晚：" + "；".join(HISTORY) + "）"

def flat_late_to_early():
    return "（本次会话用户之前说过，按时间从晚到早：" + "；".join(reversed(HISTORY)) + "）"

def labeled():
    return ("（本次会话用户之前说过的 10 句话，**由近及远**标注：\n"
            f"  最近一句（上一句）：{HISTORY[9]}\n"
            f"  上上一句：{HISTORY[8]}\n"
            f"  再往前：{HISTORY[7]}；{HISTORY[6]}；{HISTORY[5]}；{HISTORY[4]}；"
            f"{HISTORY[3]}；{HISTORY[2]}；{HISTORY[1]}\n"
            f"  最早一句：{HISTORY[0]}\n"
            "  越靠前的标注越新，指代「那个/它/刚才」优先指向最近提到的对象。）")

def brief():
    return f"（上一句用户说的是：{HISTORY[9]}）"

# 三个指代问题：答案分别依赖「最近」「最早」「最近」
CASES = [
    ("再打开一次", "备忘录", "最近提到的可打开对象"),
    ("最开始那个再打开一次", "计算器", "最早提到的"),
    ("把它关掉", "微信", "最近提到的可关闭对象"),
]

FORMATS = [("仅上一句", brief), ("10 句·早→晚平铺", flat_early_to_late),
           ("10 句·晚→早平铺", flat_late_to_early), ("10 句·标注远近", labeled)]

def run(need, ctx):
    r = jev.ask(need, {"pick": jev.choice_q(
        "用户这句里的「它/那个/再」指的是下面哪一个对象？",
        {**POOL, jev.NO_MATCH: jev.NO_MATCH_CRITERION})}, state_suffix="\n" + ctx)
    a = (r["answers"] or {}).get("pick") or {}
    return a.get("choice"), float(a.get("confidence") or 0), r["latency_ms"]

def main():
    print(f"{'格式':<18} " + " ".join(f"{q[:8]:<18}" for q, _, _ in CASES))
    score = {}
    for name, fn in FORMATS:
        cells, hits = [], 0
        for q, exp, _ in CASES:
            c, conf, ms = run(q, fn())
            ok = c == exp
            hits += ok
            cells.append(f"{c or '?'}({conf:.2f}){'✓' if ok else '✗'}")
        score[name] = hits
        print(f"{name:<18} " + " ".join(f"{c:<18}" for c in cells))
    print("\n命中数：", " · ".join(f"{k} {v}/3" for k, v in score.items()))
    for q, exp, why in CASES:
        print(f"  {q} → 期望 {exp}（{why}）")

if __name__ == "__main__":
    main()
