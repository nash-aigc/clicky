#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
desktop_file_agent.py — Wanna 第四出口的最小实现。

职责只做一件事：对 ~/Desktop（桌面）里的文件做 查看 / 读取 / 写入 / 修改。
它是 Wanna 的第四个出口：语音模型在回复里写 [PY_AGENT:任务]，
Wanna 就用这条命令把任务交给本脚本：

    python3 desktop_file_agent.py "任务"

设计原则：
  - 模型只做封闭选择：只能调下面三个工具，参数不合就报错，没有兜底。
  - 能力边界写死在代码里：一切路径必须落在 ~/Desktop 之内，出了就拒绝。
  - 最终答复只打印到 stdout（Wanna 只读这个），过程日志走 stderr。
  - 零依赖：只用 Python 标准库，换任何机器都能跑，不用 pip install。

用法：
    python3 desktop_file_agent.py "看看桌面上有什么文件"
    python3 desktop_file_agent.py "把 北京北京/todo.txt 的内容改成……"
"""

import json
import os
import sys
from pathlib import Path
from http.client import HTTPSConnection

# ── 配置 ──────────────────────────────────────────────────────────────

# DeepSeek 密钥。**不指向任何外部项目** —— 和百炼那个 key 一样，放在 app 自己的
# 配置目录里（0600），或者用环境变量覆盖：
#   优先  $WANNA_DEEPSEEK_KEY 指定的文件
#   否则  ~/Library/Application Support/Wanna/DeepSeekKey
DEEPSEEK_KEY_PATH = Path(os.environ.get(
    "WANNA_DEEPSEEK_KEY",
    str(Path.home() / "Library/Application Support/Wanna/DeepSeekKey")))
DEEPSEEK_HOST = "api.deepseek.com"
MODEL_NAME = "deepseek-chat"
MAX_STEPS = 10                 # 循环上限：安全带
MAX_READ_BYTES = 200_000       # 单次最多读 200KB，防止把上下文撑爆
REQUEST_TIMEOUT_SECONDS = 60   # 单次模型调用的超时

# 能力边界：只准碰桌面。这是整个 agent 的安全边界，写死，不给模型选。
DESKTOP_ROOT = Path.home() / "Desktop"


# ── DeepSeek 调用（标准库版，接口与 openai 的 chat.completions 等价）────

def call_model(messages):
    """发一轮对话给 DeepSeek，返回模型的回复消息（dict）。"""
    api_key = DEEPSEEK_KEY_PATH.read_text().strip()
    body = json.dumps({
        "model": MODEL_NAME,
        "messages": messages,
        "tools": TOOLS,
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

    return payload["choices"][0]["message"]


# ── 路径安全：一切路径必须落在桌面之内 ────────────────────────────────

def resolve_inside_desktop(raw_path: str) -> Path:
    """把模型给的路径解析成桌面内的绝对路径；出了桌面就抛错。

    接受两种写法：绝对路径（/Users/xx/Desktop/...），或相对桌面的路径
    （todo.txt、北京北京/笔记.md）。允许 ..，但解析完必须还在桌面里。
    """
    given = Path(raw_path).expanduser()
    absolute = given if given.is_absolute() else (DESKTOP_ROOT / given)
    resolved = absolute.resolve()
    if resolved != DESKTOP_ROOT and DESKTOP_ROOT not in resolved.parents:
        raise ValueError(f"路径越界：{raw_path} 不在桌面（{DESKTOP_ROOT}）里，本工具只管桌面。")
    return resolved


# ── 三个工具（能力边界 = 这个 agent 的全部能力）────────────────────────

def tool_list_files(path: str = ".") -> str:
    target = resolve_inside_desktop(path)
    if not target.exists():
        return f"错误：{target} 不存在。"
    if target.is_file():
        return f"{target} 是一个文件，{target.stat().st_size} 字节。"
    entries = sorted(target.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))
    if not entries:
        return f"{target} 是空文件夹。"
    lines = []
    for entry in entries[:200]:  # 目录项太多就截断，保护上下文
        kind = "文件夹" if entry.is_dir() else "文件"
        size = "" if entry.is_dir() else f"，{entry.stat().st_size} 字节"
        lines.append(f"- {entry.name}（{kind}{size}）")
    if len(entries) > 200:
        lines.append(f"……共 {len(entries)} 项，只列了前 200 项。")
    return "\n".join(lines)


def tool_read_file(path: str) -> str:
    target = resolve_inside_desktop(path)
    if not target.exists():
        return f"错误：{target} 不存在。"
    if not target.is_file():
        return f"错误：{target} 是文件夹不是文件，要看内容清单用 list_files。"
    data = target.read_bytes()
    if len(data) > MAX_READ_BYTES:
        head = data[:MAX_READ_BYTES].decode("utf-8", errors="replace")
        return f"错误：文件太大（{len(data)} 字节，上限 {MAX_READ_BYTES}），只读前一段：\n{head}"
    return data.decode("utf-8", errors="replace")


def tool_write_file(path: str, content: str) -> str:
    target = resolve_inside_desktop(path)
    if target.exists() and target.is_dir():
        return f"错误：{target} 是文件夹，不能当文件写。"
    target.parent.mkdir(parents=True, exist_ok=True)  # 缺中间文件夹就建好（仍在桌面内）
    target.write_text(content, encoding="utf-8")
    return f"已写入 {target}（{len(content)} 字符）。"


# ── 工具表（喂给模型的说明书）─────────────────────────────────────────

TOOLS = [
    {"type": "function", "function": {
        "name": "list_files",
        "description": "列出桌面里某个文件夹的内容。path 可省略，默认列出桌面本身。",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string",
                     "description": "桌面内的路径，如 'todo.txt' 或 '北京北京'。可省略。"}}}}},
    {"type": "function", "function": {
        "name": "read_file",
        "description": "读取桌面里某个文本文件的内容。",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "桌面内的文件路径"}},
            "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "write_file",
        "description": "把内容写入（新建或覆盖）桌面里的某个文本文件。",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "桌面内的文件路径"},
            "content": {"type": "string", "description": "要写入的完整内容"}},
            "required": ["path", "content"]}}},
]

TOOL_FUNCTIONS = {
    "list_files": tool_list_files,
    "read_file": tool_read_file,
    "write_file": tool_write_file,
}


# ── 循环 ─────────────────────────────────────────────────────────────

def log(message: str) -> None:
    print(message, file=sys.stderr)  # 过程日志走 stderr，不污染给 Wanna 的结果


def run_task(task: str) -> str:
    messages = [
        {"role": "system", "content": (
            "你是一个桌面文件管家，只管理 ~/Desktop 里的文件：查看、读取、写入、修改。"
            "全程只用中文回复，不要夹杂英文单词。"
            "用提供的工具完成任务；任务完成后，用一句简短的中文总结做了什么（这是要念给用户听的）。"
            "工具返回'错误：'开头的消息说明操作没成功，要如实告诉用户，不要假装成功。"
        )},
        {"role": "user", "content": task},
    ]

    for step in range(MAX_STEPS):
        message = call_model(messages)

        tool_calls = message.get("tool_calls")
        if not tool_calls:                       # 模型不要工具了 = 完成
            return message.get("content") or "（没有返回内容）"

        messages.append(message)                 # 带着工具调用请求一起回填
        for call in tool_calls:
            name = call["function"]["name"]
            try:
                arguments = json.loads(call["function"].get("arguments") or "{}")
                result = TOOL_FUNCTIONS[name](**arguments)
            except Exception as error:           # 路径越界、参数缺失……如实报错，不兜底
                result = f"错误：{error}"
            log(f"[step {step + 1}] {name}({call['function'].get('arguments')}) -> {result[:120]}")
            messages.append({"role": "tool",
                             "tool_call_id": call["id"],
                             "content": result})

    return "步数用完还没做完，只完成了部分。"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print('用法: python3 desktop_file_agent.py "任务"', file=sys.stderr)
        sys.exit(2)
    try:
        print(run_task(sys.argv[1]))             # 只有最终答复进 stdout
    except Exception as error:
        log(f"agent 失败: {error}")
        print(f"桌面管家启动失败：{error}")
        sys.exit(1)
