#!/usr/bin/env python3
"""JEV 追问上下文该带多少 —— 三档对照（仅本轮 / +上一句 / +10 句标注远近）。

用户定案：追问必须带屏幕 + 之前 10 句、且标注远近，让模型区分重点。
那是**大模型**侧的规则（它有对话历史、要承接指代）。JEV 是选择器，不是对话解析器——
本脚本量的是：这份"10 句标注"塞给 JEV，它的**分类**是变准还是变糊。
"""
import sys

sys.path.insert(0, "/Users/mjm/Documents/SuperAgent/Agent/Wanna/instant-agent")
import jev  # noqa: E402

Q_GOAL = {
    "图形": "用户要在屏幕上**看到**一个图形结果：光标飞过去指、画圈/画框/画箭头、生成 SVG 图形或图解。",
    "文字": "用户要的是一段文字本身：问答、翻译、写作、讲解、总结。",
    "执行": "用户要让机器状态真的变化：点、按、打字、开关 App、调音量亮度、读写文件、运行工作流。",
}

HISTORY = ["打开计算器", "把音量调到 30", "打开蓝牙设置", "圈一下屏幕上那个图标",
           "把它翻译成英文", "关掉微信", "把亮度调到 70", "现在几点了",
           "打开 Safari", "打开备忘录"]

CASES = [
    ("这句话什么意思", "文字"), ("那这句呢", "文字"), ("再上面那句", "文字"),
    ("帮我把它翻译成英文", "文字"), ("那把它关掉", "执行"),
    ("放大一点", "执行"), ("圈一下", "图形"),
]

def ctx_none():
    return ""

def ctx_prev():
    return f"\n（上一句用户说的是：{HISTORY[-1]}）"

def ctx_ten_labeled():
    return ("\n（本次会话最近 10 句用户原话，由近及远：\n"
            f"  上一句：{HISTORY[9]}\n  上上一句：{HISTORY[8]}\n"
            f"  更早：{'；'.join(reversed(HISTORY[:8]))}\n"
            "  指代（它/那个/刚才）优先指向最近提到的对象。）")

def ctx_ten_flat():
    return "\n（本次会话用户之前说过：" + "；".join(HISTORY) + "）"

def goal(need, ctx):
    r = jev.ask(need, {"goal": jev.choice_q("这条需求的目标是什么？", Q_GOAL)},
                state_suffix=ctx)
    a = (r["answers"] or {}).get("goal") or {}
    return a.get("choice"), float(a.get("confidence") or 0)

def main():
    variants = [("仅本轮", ctx_none), ("+上一句", ctx_prev),
                ("+10句平铺", ctx_ten_flat), ("+10句标注", ctx_ten_labeled)]
    print(f"{'追问句':<22}" + "".join(f"{n:<16}" for n, _ in variants))
    total = {n: 0 for n, _ in variants}
    probs = {n: [] for n, _ in variants}
    for sent, exp in CASES:
        cells = []
        for name, fn in variants:
            c, conf = goal(sent, fn())
            ok = c == exp
            total[name] += ok
            probs[name].append(conf)
            cells.append(f"{c}({conf:.2f}){'✓' if ok else '✗'}")
        print(f"{sent:<22}" + "".join(f"{c:<16}" for c in cells))
    n = len(CASES)
    print("\n分类命中：" + " · ".join(f"{k} {v}/{n}" for k, v in total.items()))
    print("平均置信：" + " · ".join(
        f"{k} {sum(v)/len(v):.2f}" for k, v in probs.items()))

if __name__ == "__main__":
    main()
