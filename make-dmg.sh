#!/usr/bin/env bash
#
# make-dmg.sh — 配布用の DMG（ドラッグして Applications へインストール）を作る。
#               "NFC URL Writer.app" と /Applications へのシンボリックリンクを
#               同梱し、開いたウインドウでドラッグ＆ドロップできるようにする。
#
#               可能なら「見た目を整えた」DMG を作る:
#                 - .background/bg.png を背景に敷き（中央に右向き矢印＋案内文）
#                 - アイコン表示・アイコンサイズ・アプリと Applications の位置を設定
#               この整形は Finder の AppleScript 自動化に依存し、環境によっては
#               権限やタイミングで失敗する。失敗した場合は「素の」ドラッグ＆ドロップ
#               DMG（従来どおり動く）へ自動フォールバックし、ビルドは止めない。
#
# 使い方: ./make-dmg.sh   →  ./NFC-URL-Writer.dmg が生成される
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP="NFC URL Writer.app"
VOLNAME="NFC URL Writer"
DMG="NFC-URL-Writer.dmg"
BG_W=600
BG_H=400
ICON_SIZE=96

# アプリが無ければビルド
if [ ! -d "$APP" ]; then
  echo "==> $APP が無いので build-app.sh を実行します"
  ./build-app.sh
fi
[ -d "$APP" ] || { echo "ERROR: $APP がありません（build-app.sh が失敗）。"; exit 1; }

# 古い DMG を削除
rm -f "$DMG"

# 以前のマウントが残っていれば外す
detach_vol() {
  # $1 = ボリューム名（/Volumes/<name>）
  if [ -d "/Volumes/$1" ]; then
    hdiutil detach "/Volumes/$1" -force >/dev/null 2>&1 || true
  fi
}
detach_vol "$VOLNAME"

# ステージング用の一時ディレクトリ（EXIT で必ず掃除）
STAGE="$(mktemp -d -t nfcdmg.XXXXXX)"
RWDMG="$(mktemp -u -t nfcdmg-rw.XXXXXX).dmg"
cleanup() {
  detach_vol "$VOLNAME"
  rm -rf "$STAGE"
  rm -f "$RWDMG"
}
trap cleanup EXIT

echo "==> ステージングを準備: $STAGE"
# .app をコピー（シンボリックリンクなどをそのまま保持）
cp -R "$APP" "$STAGE/"
# Applications へのシンボリックリンク（ドラッグ先）
ln -s /Applications "$STAGE/Applications"

# ---- 背景画像を用意（.background/bg.png、隠しフォルダ）--------------------
# app-src/render-dmg-bg.swift を swiftc でビルドして PNG を生成する。
# ここで失敗しても致命的ではない（styling をスキップして素の DMG になる）。
BG_OK=0
BG_SRC="$SCRIPT_DIR/app-src/render-dmg-bg.swift"
if command -v swiftc >/dev/null 2>&1 && [ -f "$BG_SRC" ]; then
  echo "==> 背景 PNG を生成 (.background/bg.png)"
  mkdir -p "$STAGE/.background"
  BG_BIN="$STAGE/.render-dmg-bg"
  if swiftc -O "$BG_SRC" -o "$BG_BIN" >/dev/null 2>&1 \
     && "$BG_BIN" "$STAGE/.background/bg.png" "$BG_W" "$BG_H" >/dev/null 2>&1 \
     && [ -f "$STAGE/.background/bg.png" ]; then
    BG_OK=1
  else
    echo "    背景 PNG の生成に失敗（styling をスキップします）"
  fi
  rm -f "$BG_BIN"
else
  echo "==> swiftc または render-dmg-bg.swift が無いため背景生成をスキップ"
fi

# ---- 素の DMG を作る関数（フォールバック）--------------------------------
make_plain_dmg() {
  echo "==> 素の DMG を作成（フォールバック）: $DMG"
  detach_vol "$VOLNAME"
  hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null
}

# ---- 見た目を整えた DMG を作る（失敗したら 1 を返す）----------------------
STYLED=0
make_styled_dmg() {
  # 背景が無ければ styling する意味が薄い → 早期に失敗を返す
  [ "$BG_OK" -eq 1 ] || { echo "    背景が無いため styling を行いません"; return 1; }

  echo "==> 書き込み可能な DMG(UDRW) を作成して整形します"
  rm -f "$RWDMG"
  detach_vol "$VOLNAME"

  # UDRW（読み書き可能）で作成。srcfolder に .background も含む。
  if ! hdiutil create \
        -volname "$VOLNAME" \
        -srcfolder "$STAGE" \
        -ov \
        -format UDRW \
        "$RWDMG" >/dev/null 2>&1; then
    echo "    UDRW DMG の作成に失敗"
    return 1
  fi

  # マウント
  local MOUNT_OUT DEV MNT
  MOUNT_OUT="$(hdiutil attach "$RWDMG" -readwrite -noverify -noautoopen 2>/dev/null)" || {
    echo "    UDRW DMG のマウントに失敗"
    return 1
  }
  # デバイスノードとマウントポイントを取得
  DEV="$(printf '%s\n' "$MOUNT_OUT" | grep -Eo '^/dev/disk[0-9]+' | head -n1)"
  MNT="/Volumes/$VOLNAME"
  if [ ! -d "$MNT" ]; then
    echo "    マウントポイント $MNT が見つかりません"
    [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
    return 1
  fi

  # Finder の AppleScript で整形（フレーキーな箇所。失敗しても捕捉する）。
  # 60 秒でタイムアウトさせ、ハングを防ぐ。
  if osascript - "$VOLNAME" "$ICON_SIZE" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set volName to item 1 of argv
  set iconSize to (item 2 of argv) as integer
  with timeout of 60 seconds
    tell application "Finder"
      tell disk volName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- ウインドウ位置とサイズ（背景 600x400 に合わせる）
        set the bounds of container window to {200, 120, 800, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to iconSize
        set text size of opts to 12
        set background picture of opts to file ".background:bg.png"
        -- アイコン配置（左: アプリ / 右: Applications）
        set position of item "NFC URL Writer.app" of container window to {150, 180}
        set position of item "Applications" of container window to {450, 180}
        update without registering applications
        delay 1
        close
      end tell
    end tell
  end timeout
end run
APPLESCRIPT
  then
    STYLE_APPLIED=1
  else
    STYLE_APPLIED=0
  fi

  # .DS_Store を確実に書き出すため少し待つ
  sync
  # アンマウント
  hdiutil detach "$MNT" -force >/dev/null 2>&1 || {
    [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
  }

  if [ "${STYLE_APPLIED:-0}" -ne 1 ]; then
    echo "    Finder の AppleScript 整形に失敗（権限/タイミング）"
    return 1
  fi

  # UDRW → 圧縮 UDZO へ変換
  echo "==> UDZO へ圧縮変換: $DMG"
  if ! hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null 2>&1; then
    echo "    UDZO への変換に失敗"
    return 1
  fi
  return 0
}

# ---- 実行: まず styled を試し、失敗したら plain へフォールバック ----------
if make_styled_dmg; then
  STYLED=1
else
  echo "==> 整形に失敗したため、素の DMG にフォールバックします"
  make_plain_dmg
  STYLED=0
fi

# 結果を表示
SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
if [ "$STYLED" -eq 1 ]; then
  echo "==> 完了（整形あり / styled）: $SCRIPT_DIR/$DMG ($SIZE)"
else
  echo "==> 完了（素 / plain fallback）: $SCRIPT_DIR/$DMG ($SIZE)"
fi
