# 截图与OCR 工具

v2 框架 ②纯代码类的第一个正式工具（2026-09-25 从实测探针固化，实测数据见
`开发经验/04-Agent体系/主控循环Agent/05-截图与OCR.md` §八）。

## 文件

| 文件 | 作用 |
|---|---|
| `ocr_to_file.swift` | Vision OCR 助手源码（`VNRecognizeTextRequest`，`.accurate`，语言纠正开） |
| `ocr` | 编译产物（`build.sh` 生成，不入 git 的话见 `.gitignore`） |
| `build.sh` | 一次性编译：`swiftc -O -o ocr ocr_to_file.swift` |
| `capture_and_ocr.sh` | 编排脚本：区域 → 原图 PNG + 文本 TXT 两个产物 |

## 用法

```bash
tools/截图与OCR/capture_and_ocr.sh <区域> <输出前缀>
# 区域: left | right | top | bottom | full | X,Y,W,H（逻辑坐标）
# 产物: <前缀>.png（原图物理像素）+ <前缀>.txt（OCR 文本）
```

## 实测（本机）

- 端到端热身 **~1.5–2.4s**（截屏 0.23s + OCR 1.1s）
- 区域全覆盖：left/right 1728×2234、top/bottom 3456×1116、full 3456×2234——全是物理像素原图
- OCR 首跑 35s = Vision 模型一次性初始化；**App 接入时必须预热**（05 §八 修正 3）
- 准确率：中英正文 ~95%+；弱项 = 代码符号 / emoji / 手写体（详表见 05 §八）

## 已修的坑

- Finder 桌面 bounds 返回 `0, 0, 1728, 1117`（带逗号空格）——解析时**逗号只能换成空格**，`tr -d ' ,'` 会把数字粘连成 `0017281117`
