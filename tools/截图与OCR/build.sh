#!/bin/bash
# 编译 OCR 助手（一次性）：swiftc -O -o ocr ocr_to_file.swift
set -e
cd "$(dirname "$0")"
swiftc -O -o ocr ocr_to_file.swift
echo "已编译: $(pwd)/ocr"
