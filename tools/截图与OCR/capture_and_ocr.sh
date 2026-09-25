#!/bin/bash
# 截屏并 OCR —— Clicky 工具库 · 截图与OCR
# 用法:
#   capture_and_ocr.sh <区域> <输出前缀>
#   区域: left | right | top | bottom | full | X,Y,W,H(逻辑坐标)
#   输出前缀: 产物为 <前缀>.png（原图）与 <前缀>.txt（OCR 文本），目录不存在自动创建
# 依赖: screencapture(系统) + ocr(Vision 助手，见 build.sh)
# 实测: 端到端热身 1.5s；OCR 首跑 35s 为模型一次性初始化（预热见 05 文档 §八）
set -euo pipefail

REGION="${1:?用法: capture_and_ocr.sh <left|right|top|bottom|full|X,Y,W,H> <输出前缀>}"
PREFIX="${2:?缺少输出前缀}"

mkdir -p "$(dirname "$PREFIX")"

# 主显示器逻辑尺寸（Finder 桌面窗口 bounds = 逻辑点；返回带逗号，先去掉）
BOUNDS=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | tr ',' ' ')
read -r _ _ DW DH <<< "$BOUNDS"

case "$REGION" in
  left)   RECT="0,0,$((DW/2)),$DH" ;;
  right)  RECT="$((DW/2)),0,$((DW/2)),$DH" ;;
  top)    RECT="0,0,$DW,$((DH/2))" ;;
  bottom) RECT="0,$((DH/2)),$DW,$((DH/2))" ;;
  full)   RECT="" ;;
  *)      RECT="$REGION" ;;  # X,Y,W,H 原样透传
esac

PNG="${PREFIX}.png"
if [ -n "$RECT" ]; then
  screencapture -x -R"$RECT" "$PNG"
else
  screencapture -x "$PNG"
fi

DIR_OF_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
"$DIR_OF_SCRIPT/ocr" "$PNG" zh-Hans,en > "${PREFIX}.txt"
echo "完成: ${PNG} + ${PREFIX}.txt"
