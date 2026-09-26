#!/usr/bin/env python3
"""三分类分流基准 —— JEV choice 原语 vs DeepSeek，判「纯文本 / 纯显示 / 混合执行」。

背景（用户 2026-09-25 的判定）：L0 关键词直执在「用户的话里只是出现了执行触发词」
（翻译/引用/别的软件/英语/叠加多意图）时必误触发，所以分流交给模型做。这个脚本
量两件事：① JEV 三分类在这批难句上的**准确率**；② 与 DeepSeek 分类的**速度差**。

判据按用户口径写进题面：
  纯文本 = 答案就是话本身（翻译/写作/问答/讲解），不碰机器也不画到屏幕
  纯显示 = 只在屏幕上指/画/标注，机器状态零变化
  混合执行 = 要让机器状态发生变化（点击/按键/开关/文件/App/系统项）

生产形态提示（脚本不模拟，但记录里注明）：JEV 的 state 会带上「当前前台 App」
一行辅助信息——这是分类「在计算器里看一下数字」这类句子的关键上下文。

密钥：JEV 读它自己的 .env（JEV_ENV_PATH），DeepSeek 读 $DS_KEY_FILE（0600 文件），
两者都不回显、不进仓库。
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, "/Users/mjm/Documents/SuperAgent/Agent/Wanna/instant-agent")
import jev  # noqa: E402

# ── 三分类题面 ────────────────────────────────────────────────────────
CLASSES = {
    "纯文本": "回答这句话只需要文字本身（翻译、写作、问答、讲解、闲聊）。"
              "注意：句子里出现了执行词不代表要执行——「翻译『打开计算器』」"
              "「比如打开蓝牙设置是什么意思」要的是解释或翻译，不是动作。",
    "纯显示": "要让蓝色光标飞到某个位置、画圈、画箭头、画图讲解——"
              "只是屏幕上多了指示或图形，App、系统、文件都不发生任何变化。",
    "混合执行": "要让机器的状态真的发生变化：点击、打字、按键、滚动、"
                "打开或关闭 App、调节音量亮度、开关系统项、读写文件。"
                "一句话里既有执行又有其他意图时，也算这一类。",
}
RULES = ("先看用户到底要什么：是话本身、是屏幕上的指示、还是机器动起来。"
         "引用的话、例子、翻译对象里的执行词一律不算执行请求。")

# 当前前台 App——JEV 生产 state 里会带这行；这里每条句子配一个场景。
# None = 无特殊场景（默认桌面）。
SENTENCES = [
    # (句子, 前台App, 期望, 为什么难)
    ("请翻译一下打开计算器这六个字",  None, "纯文本",   "执行词在引号里"),
    ("打开蓝牙设置这个说法是什么意思", None, "纯文本",   "哨兵词「什么意思」"),
    ("帮我写一篇文章，里面举个例子说明怎么打开 Safari", None, "纯文本", "写作里嵌了 App 名"),
    ("如果我说打开微信，会发生什么",     None, "纯文本",   "条件句，不是请求"),
    ("翻译成英文：把音量调到最大",        None, "纯文本",   "执行词是翻译对象"),
    ("open Safari for me",           None, "混合执行", "英语直接执行请求"),
    ("set my volume to 30",          None, "混合执行", "英语参数化执行"),
    ("在计算器里看一下数字7，然后去 Google 搜一下它是什么星座",
     "Calculator", "混合执行", "跨 App 多意图叠加"),
    ("打开微信，然后把刚才那句话发给他",   "WeChat",  "混合执行", "指代+执行"),
    ("把屏幕亮度调成 70，顺便告诉我现在几点了", None, "混合执行", "执行+问答混合"),
    ("圈出截图里那个报错的位置",          None, "纯显示",   "只画不动"),
    ("在第一个按钮那里画个圈标一下",       "System Settings", "纯显示", "指位画圈"),
    ("帮我点一下屏幕上的登录按钮",        "WeChat",  "混合执行", "真要点"),
    ("鼠标飞到设置图标那里指一下就行，别点", "Finder", "纯显示", "「别点」排除执行"),
    ("静音",                         None, "混合执行", "裸触发词：该走 L0，模型判也对"),
    ("刚才那个圈画得不对，音量倒是没问题，再帮我静音一次", None, "混合执行",
     "回顾显示+执行，本轮诉求是执行"),
    # ── 对抗样本（第二轮加的，专门找错）──────────────────────────
    ("「删除」在英文里是不是就是 backspace 的意思", "Finder", "纯文本",
     "App 里问词义，执行词是讨论对象"),
    ("先别动，我是想问点登录按钮一般要等多久才有反应", "WeChat", "纯文本",
     "「先别动」+对动作的提问"),
    ("帮我看看屏幕上有多少个图标", "Finder", "纯文本",
     "「屏幕/看」但不指不画不动——读屏问答归纯文本"),
]

# ── DeepSeek 分类（对照）──────────────────────────────────────────────
KEY_FILE = os.environ.get("DS_KEY_FILE", "/tmp/dskey_138")
if not os.path.exists(KEY_FILE):
    sys.exit(f"找不到 DeepSeek key 文件：{KEY_FILE}（用 DS_KEY_FILE 指定）")
DS_KEY = open(KEY_FILE).read().strip()
DS_SYS = ("你是任务分流器。把用户需求分成且仅分成一类，只输出类别名本身：\n"
          "纯文本：回答只需要文字本身（翻译/写作/问答/讲解）。"
          "句子里被引用、被当作例子、被当作翻译对象的执行词不算执行请求。\n"
          "纯显示：只在屏幕上指位置/画圈/画图，机器状态零变化。\n"
          "混合执行：要让机器状态真的变化（点击/打字/开关/文件/App/音量亮度），"
          "多意图叠加里含执行也算这类。\n")
_conn = None


def ds_classify(need: str, front_app: str | None) -> tuple[str, int]:
    global _conn
    import http.client
    state = need + (f"（当前前台 App：{front_app}）" if front_app else "")
    body = json.dumps({"model": "deepseek-flash", "temperature": 0,
                       "max_tokens": 8, "thinking": {"type": "disabled"},
                       "messages": [{"role": "system", "content": DS_SYS},
                                    {"role": "user", "content": state}]}).encode()
    t0 = time.perf_counter()
    try:
        if _conn is None:
            _conn = http.client.HTTPSConnection("api.deepseek.com", timeout=20)
        _conn.request("POST", "/chat/completions", body=body,
                      headers={"Content-Type": "application/json",
                               "Authorization": "Bearer " + DS_KEY})
        raw = json.loads(_conn.getresponse().read())
        text = (raw["choices"][0]["message"]["content"] or "").strip()
    except Exception:  # noqa: BLE001 —— 连接类异常重连一次
        _conn = None
        return ds_classify(need, front_app) if t0 else ("?", 0)
    ms = round((time.perf_counter() - t0) * 1000)
    hit = next((c for c in CLASSES if c in text), "?")
    return hit, ms


def jev_classify(need: str, front_app: str | None) -> tuple[str, int, float]:
    suffix = f"\n（当前前台 App：{front_app}）" if front_app else ""
    r = jev.ask(need, {"cls": jev.choice_q(
        "判断这条需求属于哪一类任务。", CLASSES, RULES)}, state_suffix=suffix)
    if r.get("error"):
        return "?", r["latency_ms"], 0.0
    ans = (r["answers"].get("cls") or {})
    return (ans.get("choice") or "?", r["latency_ms"],
            float(ans.get("confidence") or 0))


def main():
    rows = []
    print(f"{'句子':<30} 期望→JEV / DS        conf   JEVms  DSms  说明")
    for sent, app, expect, why in SENTENCES:
        jc, jm, jconf = jev_classify(sent, app)
        dc, dm = ds_classify(sent, app)
        rows.append({"q": sent, "front": app, "expect": expect,
                     "jev": jc, "jev_ms": jm, "jev_conf": jconf,
                     "ds": dc, "ds_ms": dm, "why": why})
        mark = "✓" if jc == expect else "✗"
        markd = "✓" if dc == expect else "✗"
        print(f"{sent[:28]:<30} {expect}→J:{mark}{jc:<5} D:{markd}{dc:<5} "
              f"{jconf:.2f}  {jm:>5}  {dm:>5}  {why}")

    jev_ok = sum(r["jev"] == r["expect"] for r in rows)
    ds_ok = sum(r["ds"] == r["expect"] for r in rows)
    jms = sorted(r["jev_ms"] for r in rows if r["jev_ms"])
    dms = sorted(r["ds_ms"] for r in rows if r["ds_ms"])
    med = lambda a: a[len(a) // 2] if a else 0
    out = {
        "rows": rows,
        "score": {"jev_hit": f"{jev_ok}/{len(rows)}",
                  "ds_hit": f"{ds_ok}/{len(rows)}",
                  "jev_median_ms": med(jms), "ds_median_ms": med(dms),
                  "jev_p95_ms": jms[min(int(len(jms) * .95), len(jms) - 1)] if jms else 0,
                  "ds_p95_ms": dms[min(int(len(dms) * .95), len(dms) - 1)] if dms else 0},
    }
    dest = "/Users/mjm/Documents/SuperAgent/APP/Design/wanna/解决方案/04-Agent体系/分流测速/三分类结果.json"
    with open(dest, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("\n== 汇总 ==")
    print(json.dumps(out["score"], ensure_ascii=False))
    for r in rows:
        if r["jev"] != r["expect"]:
            print(f"JEV 误判：{r['q']} → {r['jev']}（应 {r['expect']}）conf={r['jev_conf']}")
    for r in rows:
        if r["ds"] != r["expect"]:
            print(f"DS 误判：{r['q']} → {r['ds']}（应 {r['expect']}）")
    print(f"结果文件：{dest}")


if __name__ == "__main__":
    main()
