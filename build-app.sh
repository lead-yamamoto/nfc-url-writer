#!/usr/bin/env bash
#
# build-app.sh — SwiftUI ネイティブアプリ「NFC URL Writer.app」をビルドする。
#                write-url.sh / build-tools.sh をアプリ内に同梱し、URL は実行時に
#                TARGET_URL 環境変数で渡す（バンドルは書き換えない）。
#
# 前提: Xcode または Command Line Tools（swiftc）。
# 使い方: ./build-app.sh   →  ./"NFC URL Writer.app" が生成される
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="NFC URL Writer"
APP="$APP_NAME.app"
SRC="app-src/NFCURLWriter.swift"
BIN_NAME="NFCURLWriter"
MIN="12.0"

command -v swiftc >/dev/null 2>&1 || { echo "ERROR: swiftc が必要です（Xcode か 'xcode-select --install'）。"; exit 1; }
[ -f "$SRC" ] || { echo "ERROR: $SRC がありません。"; exit 1; }
SDK="$(xcrun --show-sdk-path)"

# アイコンが無ければ生成
if [ ! -f AppIcon.icns ]; then
  echo "==> アイコンを生成 (make-icon.sh)"
  ./make-icon.sh
fi

build="$(mktemp -d -t nfcapp.XXXXXX)"
trap 'rm -rf "$build"' EXIT

compile() { # $1=arch
  swiftc -parse-as-library -O -sdk "$SDK" \
    -target "$1-apple-macos$MIN" "$SRC" -o "$build/$1"
}

echo "==> コンパイル (arm64)"
compile arm64
archs=("$build/arm64")

echo "==> コンパイル (x86_64)"
if compile x86_64 2>"$build/x86.log"; then
  archs+=("$build/x86_64")
else
  echo "    x86_64 のビルドに失敗 → arm64 単体で作成します（Intel Mac では再ビルドが必要）。"
  tail -2 "$build/x86.log" | sed 's/^/      /' || true
fi

echo "==> $APP を組み立て"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${archs[@]}" -output "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.local.nfcurlwriter</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>NFC URL Writer</string>
</dict>
</plist>
PLIST

echo "==> スクリプト・アイコンを同梱"
cp write-url.sh build-tools.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> アドホック署名（ローカル起動用。配布先では右クリック→開く が必要）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    codesign は省略（未署名）"

echo
echo "完成: $SCRIPT_DIR/$APP"
echo "起動: Finder でダブルクリック、または  open \"$APP\""
