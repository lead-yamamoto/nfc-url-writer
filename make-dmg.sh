#!/usr/bin/env bash
#
# make-dmg.sh — 配布用の DMG（ドラッグして Applications へインストール）を作る。
#               "NFC URL Writer.app" と /Applications へのシンボリックリンクを
#               同梱し、開いたウインドウでドラッグ＆ドロップできるようにする。
#
# 使い方: ./make-dmg.sh   →  ./NFC-URL-Writer.dmg が生成される
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP="NFC URL Writer.app"
VOLNAME="NFC URL Writer"
DMG="NFC-URL-Writer.dmg"

# アプリが無ければビルド
if [ ! -d "$APP" ]; then
  echo "==> $APP が無いので build-app.sh を実行します"
  ./build-app.sh
fi
[ -d "$APP" ] || { echo "ERROR: $APP がありません（build-app.sh が失敗）。"; exit 1; }

# 古い DMG を削除
rm -f "$DMG"

# 以前のマウントが残っていれば外す
if [ -d "/Volumes/$VOLNAME" ]; then
  echo "==> 残っているマウント /Volumes/$VOLNAME を detach"
  hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
fi

# ステージング用の一時ディレクトリ（EXIT で必ず掃除）
STAGE="$(mktemp -d -t nfcdmg.XXXXXX)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "==> ステージングを準備: $STAGE"
# .app をコピー（シンボリックリンクなどをそのまま保持）
cp -R "$APP" "$STAGE/"
# Applications へのシンボリックリンク（ドラッグ先）
ln -s /Applications "$STAGE/Applications"

echo "==> DMG を作成: $DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

# 結果を表示
SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> 完了: $SCRIPT_DIR/$DMG ($SIZE)"
