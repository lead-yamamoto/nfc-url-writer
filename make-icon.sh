#!/usr/bin/env bash
#
# make-icon.sh — app-src/render-icon.swift から AppIcon.icns を生成する。
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v swiftc  >/dev/null 2>&1 || { echo "ERROR: swiftc が必要です。"; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "ERROR: iconutil が必要です。"; exit 1; }

SDK="$(xcrun --show-sdk-path)"
tmp="$(mktemp -d -t nfcicon.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

echo "==> アイコンレンダラをコンパイル"
swiftc -O -sdk "$SDK" app-src/render-icon.swift -o "$tmp/render"

echo "==> PNG を生成"
"$tmp/render" "$tmp/AppIcon.iconset"

echo "==> .icns に変換"
iconutil -c icns "$tmp/AppIcon.iconset" -o AppIcon.icns

echo "完成: $(pwd)/AppIcon.icns"
