#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
figure_agent.py — Wanna 第五出口的最小实现。

职责只做一件事：把用户的「画图」需求变成一张精确的几何/SVG 图，
放到 checkout 的 Wanna图形/ 里并自动打开预览。

它是 Wanna 的第五个出口：语音模型在回复里写 [SVG_AGENT:任务]，
Wanna 就用这条命令把任务交给本脚本：

    python3 figure_agent.py "任务"

分工（模型只描述，编译器算坐标）：
  - DeepSeek 只负责把需求翻译成 geometry-dsl 的 .geom 描述文本，
    不生成任何命令、不算任何坐标。
  - geometry-dsl 编译器（本地 Node）负责全部几何计算和 SVG 渲染，
    语法错误带机器可读的错误码返回给模型修，最多修 MAX_FIX_ROUNDS 轮。
  - 文件名、存放位置、是否打开预览都由本脚本决定（能力边界写死，
    模型不给路径），输出只准落在 FIGURE_OUTPUT_DIR。
  - 最终答复只打印到 stdout（Wanna 只读这个），过程日志走 stderr。
  - 零依赖：只用 Python 标准库 + 本地 node。

用法：
    python3 figure_agent.py "画一个圆，标出圆心 O 和一条直径 AB"
    python3 figure_agent.py --no-open "画一个直角三角形"   # 只出文件，不弹预览
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from http.client import HTTPSConnection

# ── 配置 ──────────────────────────────────────────────────────────────

# DeepSeek 密钥。**不指向任何外部项目** —— 和百炼那个 key 一样，放在 app 自己的
# 配置目录里（0600），或者用环境变量覆盖。和 `tools/desktop-agent/` 的桌面管家共用同一个文件。
#   优先  $WANNA_DEEPSEEK_KEY 指定的文件
#   否则  ~/Library/Application Support/Wanna/DeepSeekKey
DEEPSEEK_KEY_PATH = Path(os.environ.get(
    "WANNA_DEEPSEEK_KEY",
    str(Path.home() / "Library/Application Support/Wanna/DeepSeekKey")))
DEEPSEEK_HOST = "api.deepseek.com"
MODEL_NAME = "deepseek-chat"
REQUEST_TIMEOUT_SECONDS = 90   # 单次模型调用的超时（写一整份 .geom 比分类慢）

# 引擎就住在本脚本旁边（geometry-dsl/），认脚本自己所在的目录 ——
# 整个文件夹挪到哪都还能用，不写死绝对路径
GEOMETRY_DSL_ROOT = Path(__file__).resolve().parent
# node 从 PATH 里找，找不到才回落到两个常见的安装位置。写死 /opt/homebrew/bin/node
# 在别人机器上（Intel Mac、nvm、asdf）会直接失败，而失败原因是「找不到 node」——
# 报错在编译阶段才出现，很难往路径上想。
NODE_PATH = (shutil.which("node")
             or next((c for c in ("/opt/homebrew/bin/node", "/usr/local/bin/node")
                      if Path(c).exists()), "node"))
MAX_FIX_ROUNDS = 3                            # 编译报错后最多让模型修 3 轮

# 能力边界：产物只准落在这个文件夹里。写死，不给模型选。
# 产物目录跟着 checkout 走，不写死绝对路径 —— 脚本住在 <checkout>/geometry-dsl/ 下，
# 所以上两级就是 checkout 根。和 Swift 那边的 `WorkspaceDirectory.figuresURL` 指同一个地方。
CHECKOUT_ROOT = Path(__file__).resolve().parent.parent
FIGURE_OUTPUT_DIR = CHECKOUT_ROOT / "Wanna图形"


# ── DeepSeek 调用（标准库版）──────────────────────────────────────────

def call_model(messages):
    """发一轮对话给 DeepSeek，返回模型回复的文本内容。"""
    api_key = DEEPSEEK_KEY_PATH.read_text().strip()
    body = json.dumps({
        "model": MODEL_NAME,
        "messages": messages,
        "temperature": 0.2,     # 画图要稳定，不要发散
    }).encode("utf-8")

    connection = HTTPSConnection(DEEPSEEK_HOST, timeout=REQUEST_TIMEOUT_SECONDS)
    try:
        connection.request(
            "POST", "/chat/completions", body=body,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"})
        response = connection.getresponse()
        payload = json.loads(response.read().decode("utf-8"))
        if response.status != 200:
            raise RuntimeError(f"DeepSeek 返回 {response.status}: {payload}")
    finally:
        connection.close()

    return payload["choices"][0]["message"].get("content") or ""


# ── .geom 说明书写给模型（浓缩自 geometry-dsl 的 SKILL.md）────────────

GEOM_SYSTEM_PROMPT = """你是一个画图助手，把用户的画图需求写成 geometry-dsl 的 .geom 源码。
只输出 .geom 源码本身，不要解释、不要 markdown 代码块标记。

语法规则：
- 每行一个定义：名字 = 表达式。用双引号字符串，# 注释，不写分号。
- 先定义后使用，名字不能重复赋值。用 _ 丢弃不需要的结果。
- 只支持 + - * / 和括号。没有循环、没有条件、没有 sqrt、没有约束求解。
- 内置颜色：black white gray red orange yellow green cyan blue purple；十六进制色要加引号。

构造器（全部支持的就这些）：
- point(x, y, styles...) 固定坐标的点；point(已有点, styles...) 同位置可再画一个。
- along(A, B, t) 在 A→B 上取 t 位置的点（t=0.5 是中点）。
- line(A, B, kind=segment|ray|infinite, extend=0, styles...) 线段/射线/直线。
- circle(center, radius) 半径画圆；circle(center, pointOnCircle) 过点画圆；circle(A, B, C) 过三点画圆。
- arc(circle, startPoint, endPoint, sweep=short|long|cw|ccw) 圆弧。
- path(P1, P2, ..., closed=false, smooth=false) 折线/闭合路径/平滑曲线。
- text(x, y, "内容") 独立文字；text(区域, "内容") 自动放进区域里。点的标签用 point 的 label="P" 参数。
- inside(圆或闭合路径) 内部区域；union / intersection / difference 组合区域。
- project(P, lineOrCircleOrArcOrPath) 垂足/最近点。
- intersect(对象1, 对象2, pick=i) 交点（返回列表，pick 取第 i 个）。
- transform(对象, move|rotate|mirror|scale, 参数...) 平移/旋转（角度制）/镜像/缩放。
- mark(right, A, B, C) 标直角；mark(equal, 线段1, 线段2) 标等长；mark(parallel, 线1, 线2) 标平行。

常用 styles：
- 通用：visible、color、opacity、layer（大的在上面）
- 线/圆/弧/路径/标记：width、dashed
- 点：size、shape=dot|circle|square|cross、label、label_pos=above|below|left|right|above_left|above_right|below_left|below_right
- 区域：fill、opacity
- 线：arrow=none|start|end|both

作图思路：
1. 先放几个带坐标的锚点（坐标系大致 -6 到 6），其余点用 along/project/intersect/transform 推出来。
2. 辅助线（构型用但不该看见的）加 visible=false。
3. 先定拓扑（点、线、圆的关系），最后加标签、填充和标记。
4. 图要居中、大小合适，标签不要互相压住。

画出来的东西必须有名字（关键，违反了图就是空的）：
- 凡是要显示在图上的对象（line、circle、arc、path、区域、text、mark……）都必须赋一个名字，
  如 AB = line(A, B)、外接圆 = circle(A, B, C)。赋给 _ 的对象会被丢弃、根本不会画出来。
- _ 只用于真正不要的中间结果（如交点列表取一个之后剩下的返回值）。

颜色硬性规定（不许偏离）：
- 所有线、圆、弧、路径、点、直角/等长/平行标记、文字标签一律用 color="#21D657"（系统的标注绿）。
  这是宿主应用的标注系统色，用户要求图形跟系统绿圈完全一致。
- 线条要醒目（宿主系统的绿圈是 3.5pt 粗线，图必须一样粗才显得亮）：
  width=6 起，被遮挡的虚线 width=4；所有线条 opacity=1，不要半透明线。
  点要大：size=6 以上，文字标签明显（font_size 默认即可，不要缩小）。
- 填充区域也用这个绿，默认 opacity=0.15；只有用户明确说出别的填充色（如「黄色填充」）才用别的颜色。
- 不要用 black、默认色或任何其他颜色的线条和文字。
"""


def extract_geom_source(reply: str) -> str:
    """取模型回复里的 .geom 源码：容忍它套了 ``` 代码块。"""
    text = reply.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        # 去掉第一行 ``` 和最后一行 ```
        lines = [line for line in lines[1:] if not line.strip().startswith("```")]
        text = "\n".join(lines).strip()
    return text


# ── 编译与渲染（常量命令，模型永远不碰命令行）─────────────────────────

def run_validate(geom_path: Path) -> str:
    """跑官方校验脚本。通过返回空字符串；失败返回错误输出（给模型修）。"""
    completed = subprocess.run(
        [NODE_PATH, str(GEOMETRY_DSL_ROOT / "scripts/validate_geometry.mjs"), str(geom_path)],
        capture_output=True, text=True, timeout=60, cwd=str(GEOMETRY_DSL_ROOT))
    output = (completed.stdout + completed.stderr).strip()
    # 通过时脚本打印 "OK: …" 且退出码为 0；失败时退出码非 0
    return "" if completed.returncode == 0 else output


def run_render(geom_path: Path, svg_path: Path) -> None:
    """跑官方 CLI 编译出 SVG。失败抛 RuntimeError 带错误输出。"""
    completed = subprocess.run(
        [NODE_PATH, str(GEOMETRY_DSL_ROOT / "dist/cli.js"),
         str(geom_path), "-o", str(svg_path)],
        capture_output=True, text=True, timeout=60, cwd=str(GEOMETRY_DSL_ROOT))
    if completed.returncode != 0 or not svg_path.exists():
        raise RuntimeError((completed.stderr or completed.stdout).strip())


# ── 循环：写 → 校验 → 报错回填 → 修 → 渲染 ────────────────────────────

def log(message: str) -> None:
    print(message, file=sys.stderr)  # 过程日志走 stderr，不污染给 Wanna 的结果


# ── 讲解步骤规划（屏幕白板的逐笔动画用）─────────────────────────────

STEP_PLANNER_PROMPT = """你是讲解助手。下面是一个画图任务的 .geom 源码，每行一个图形对象，按定义顺序编号 1,2,3…。
把画图过程拆成讲解步骤，让用户看着图形一步步被画出来、同时听每一步的讲解：
- n = 图形对象的定义顺序号（从 1 开始）。第一步通常是打底的点或线，最后一步必须是最后一个对象的序号，保证整张图都画完。
- text = 这一步的一句话讲解（口语、15-40 字），讲这一步在解题或构造中的作用，像老师在黑板上一边画一边说。
- 只输出 JSON 数组，不要解释、不要 markdown 代码块。示例：[{"n":1,"text":"先画底边 AB，长度是 4"},{"n":2,"text":"过 A 作垂线…"}]
- 相关联的对象可以合并进同一步（只写第一个对象的 n，其余对象会跟着一起出现）。
- 最多 10 步。如果这个任务不是讲解类（用户只是随便要一张图），输出 []。

.geom 源码：
"""


def plan_steps(task: str, geom_source: str) -> list:
    """让模型把图拆成讲解步骤。返回 [{"n": 对象序号, "text": 一句话}]，任何失败返回 []。"""
    try:
        reply = call_model([
            {"role": "system", "content": STEP_PLANNER_PROMPT + geom_source},
            {"role": "user", "content": task},
        ])
        start = reply.find("[")
        end = reply.rfind("]")
        if start < 0 or end <= start:
            return []
        raw_steps = json.loads(reply[start:end + 1])
        steps = []
        for entry in raw_steps:
            n = entry.get("n")
            text = str(entry.get("text", "")).strip()
            if isinstance(n, int) and n >= 1 and text:
                steps.append({"n": n, "text": text})
        # 讲解顺序必须按对象序号递增（逐步累加显示的前提），去重并排序
        steps.sort(key=lambda step: step["n"])
        unique = []
        for step in steps:
            if not unique or step["n"] != unique[-1]["n"]:
                unique.append(step)
        return unique
    except Exception as error:  # 步骤规划失败不该影响出图，静默降级为一次性显示
        log(f"[步骤规划失败，降级为一次性显示] {error}")
        return []


def run_task(task: str, open_preview: bool = True) -> str:
    messages = [
        {"role": "system", "content": GEOM_SYSTEM_PROMPT},
        {"role": "user", "content": task},
    ]

    geom_source = None
    for round_index in range(MAX_FIX_ROUNDS + 1):
        reply = call_model(messages)
        geom_source = extract_geom_source(reply)
        if not geom_source:
            raise RuntimeError("模型没有返回任何 .geom 源码。")

        # 校验：源码写进固定工作文件，再跑官方校验脚本
        work_path = WORK_GEOM_PATH
        work_path.write_text(geom_source, encoding="utf-8")
        error_output = run_validate(work_path)

        if not error_output:
            break
        log(f"[校验第 {round_index + 1} 轮] 未通过：\n{error_output[:800]}")
        if round_index == MAX_FIX_ROUNDS:
            raise RuntimeError(f"修了 {MAX_FIX_ROUNDS} 轮还是有语法错误：\n{error_output[:500]}")
        messages.append({"role": "assistant", "content": reply})
        messages.append({"role": "user", "content":
                         "校验失败，请修正后重新输出完整的 .geom 源码（只输出源码）：\n" + error_output[:2000]})

    # 渲染到正式位置
    FIGURE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    svg_path = FIGURE_OUTPUT_DIR / f"图形-{stamp}.svg"
    run_render(work_path, svg_path)
    shutil.copy2(work_path, svg_path.with_suffix(".geom"))  # 源码放旁边，用户以后可以改

    # 打开预览（常量动作，不是模型决定的）。屏幕白板模式（--no-open）跳过：
    # Wanna 会把 SVG 直接画在屏幕上，弹预览反而多余。
    if open_preview:
        # 固定用「预览」打开：SVG 的默认打开方式可能是浏览器，用户不希望弹浏览器
        subprocess.run(["open", "-a", "Preview", str(svg_path)], timeout=15, check=False)
    else:
        # 屏幕白板模式：顺手把图拆成讲解步骤（sidecar JSON），Wanna 逐笔画、逐句讲。
        # 失败只降级为一次性显示，不影响出图。
        steps = plan_steps(task, geom_source)
        if steps:
            steps_path = svg_path.with_suffix(".steps.json")
            steps_path.write_text(json.dumps(steps, ensure_ascii=False), encoding="utf-8")
            log(f"[讲解步骤] {len(steps)} 步 → {steps_path.name}")

    # 第一行固定是「图已画好：<路径>」，Wanna 的屏幕白板靠这一行取路径
    return (f"图已画好：{svg_path}\n"
            f".geom 源码也放在旁边（{svg_path.with_suffix('.geom').name}），想改随时能改。")


# 工作文件：校验用的临时 .geom，固定放在脚本旁边（校验脚本要能反复读写）
WORK_GEOM_PATH = Path(__file__).resolve().parent / "work.geom"


if __name__ == "__main__":
    arguments = sys.argv[1:]
    no_open = "--no-open" in arguments
    arguments = [arg for arg in arguments if arg != "--no-open"]
    if len(arguments) < 1:
        print('用法: python3 figure_agent.py [--no-open] "画图任务"', file=sys.stderr)
        sys.exit(2)
    try:
        print(run_task(arguments[0], open_preview=not no_open))  # 只有最终答复进 stdout
    except Exception as error:
        log(f"agent 失败: {error}")
        print(f"画图助手失败：{error}")
        sys.exit(1)
