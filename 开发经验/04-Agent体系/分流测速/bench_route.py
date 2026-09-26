#!/usr/bin/env python3
"""路由速度基准：JEV choice 原语 vs DeepSeek 闭集分类。20 候选 × 10 查询。"""
import sys, os, json, time, http.client, urllib.parse
from pathlib import Path
sys.path.insert(0, os.environ.get(
    "WANNA_INSTANT_AGENT",
    str(Path.home() / "Documents/SuperAgent/Agent/Wanna/instant-agent")))
import jev

HERE = Path(__file__).resolve().parent

# ── 20 个候选（真实目录条目的中文标签）──
CANDIDATES = {
 "vol_set": "设置系统音量为指定值",
 "vol_up": "音量增大一格",
 "vol_down": "音量减小一格",
 "mute": "静音",
 "brightness_set": "设置屏幕亮度为指定百分比",
 "tile_left": "窗口贴左半屏",
 "tile_right": "窗口贴右半屏",
 "maximize": "当前窗口最大化",
 "center_window": "窗口居中",
 "show_desktop": "显示桌面",
 "mission_control": "打开调度中心",
 "launchpad": "打开启动台",
 "dark_mode": "切换深色/浅色模式",
 "night_shift": "切换夜览模式",
 "dnd": "切换勿扰模式",
 "screenshot_clip": "截屏到剪贴板",
 "lock": "锁定屏幕",
 "empty_trash": "清空废纸篓",
 "settings_bluetooth": "打开蓝牙设置",
 "hide_others": "隐藏除当前应用外的所有应用",
}

QUERIES = [  # (查询原文, 期望 id)
 ("把音量调到 30", "vol_set"),
 ("屏幕太亮了，调到 70", "brightness_set"),
 ("当前窗口贴到左半屏", "tile_left"),
 ("帮我静音", "mute"),
 ("换成深色模式", "dark_mode"),
 ("截个屏放到剪贴板", "screenshot_clip"),
 ("我要离开一下，把电脑锁了", "lock"),
 ("打开蓝牙设置", "settings_bluetooth"),
 ("把别的窗口都藏起来", "hide_others"),
 ("清空一下废纸篓", "empty_trash"),
]

# ── JEV ──
def bench_jev():
    results = []
    for q, expect in QUERIES:
        t0 = time.perf_counter()
        r = jev.screen(q, CANDIDATES)
        ms = (time.perf_counter() - t0) * 1000
        got = r.get("choice") or jev.NO_MATCH
        conf = r.get("confidence")
        results.append((q, ms, got, conf, got == expect))
    return results

# ── DeepSeek（keep-alive，对齐 JEV 的连接复用口径）──
KEY = open(os.environ.get("DS_KEY_FILE", "/tmp/dskey_138")).read().strip()
catalog_text = "\n".join(f"{k} | {v}" for k, v in CANDIDATES.items())
SYS = ("你是动作路由器。只能从下面目录里选一个 id，或输出 no_match。"
       "只输出 id 本身，不解释：\n" + catalog_text)
_dsconn = None
def ds_call(need):
    global _dsconn
    body = json.dumps({"model": "deepseek-flash", "temperature": 0, "max_tokens": 60, "stream": False,
        "thinking": {"type": "disabled"},
        "messages": [{"role": "system", "content": SYS},
                     {"role": "user", "content": need}]}, ensure_ascii=False).encode()
    global_conn = _dsconn is None
    if global_conn:
        _dsconn = http.client.HTTPSConnection("api.deepseek.com", timeout=60)
    t0 = time.perf_counter()
    try:
        _dsconn.request("POST", "/chat/completions",
                 body=body, headers={"Content-Type": "application/json",
                                     "Authorization": "Bearer " + KEY})
        resp = _dsconn.getresponse(); data = resp.read()
    except Exception:
        _dsconn = http.client.HTTPSConnection("api.deepseek.com", timeout=60)
        raise
    ms = (time.perf_counter() - t0) * 1000
    out = json.loads(data)
    got = out["choices"][0]["message"]["content"].strip()
    return ms, got

def bench_ds():
    results = []
    for q, expect in QUERIES:
        ms, got = ds_call(q)
        results.append((q, ms, got, None, got == expect))
    return results

print("=== 预热（不计入）===")
jev.screen("预热", CANDIDATES)
ds_call("预热")
print("=== JEV 10 条 ===")
jr = bench_jev()
for q, ms, got, conf, ok in jr:
    print(f"{ms:7.0f}ms  {'✓' if ok else '✗'} {got} (conf {conf})  {q}")
print("=== DeepSeek 10 条 ===")
dr = bench_ds()
for q, ms, got, _, ok in dr:
    print(f"{ms:7.0f}ms  {'✓' if ok else '✗'} {got}  {q}")

import statistics
jm = statistics.median(x[1] for x in jr); dm = statistics.median(x[1] for x in dr)
ja = sum(x[1] for x in jr)/10; da = sum(x[1] for x in dr)/10
jc = sum(1 for x in jr if x[4]); dc = sum(1 for x in dr if x[4])
print("=== 汇总 ===")
print(f"JEV       中位 {jm:.0f}ms  平均 {ja:.0f}ms  命中 {jc}/10")
print(f"DeepSeek  中位 {dm:.0f}ms  平均 {da:.0f}ms  命中 {dc}/10")
print(f"倍差      中位 {dm/jm:.1f}x  平均 {da/ja:.1f}x")
json.dump({"jev": jr, "ds": dr, "jev_median": jm, "ds_median": dm,
           "jev_avg": ja, "ds_avg": da, "jev_correct": jc, "ds_correct": dc},
          open("/tmp/bench_result.json", "w"), ensure_ascii=False)
