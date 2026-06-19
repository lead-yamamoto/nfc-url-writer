#!/usr/bin/env bash
#
# build-tools.sh — libfreefare の mifare-classic-* ツールが PATH 上に無い場合の
#                  フォールバック。examples/*.c をソースから取得して ./bin にビルドする。
#
# 前提: brew install libnfc libfreefare 済み(ヘッダ/ライブラリが必要)。
#       clang(Xcode Command Line Tools)と curl が必要。
#
# 通常は write-url.sh から自動的に呼ばれます。単体実行も可能:
#   ./build-tools.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_BIN="$SCRIPT_DIR/bin"
REF="${LIBFREEFARE_REF:-libfreefare-0.4.0}"   # brew の libfreefare バージョンに合わせる
TOOLS=(mifare-classic-format mifare-classic-write-ndef mifare-classic-read-ndef)
BASE_URL="https://raw.githubusercontent.com/nfc-tools/libfreefare/$REF/examples"

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v brew  >/dev/null 2>&1 || die "Homebrew が必要です。https://brew.sh"
command -v clang >/dev/null 2>&1 || die "clang が必要です。'xcode-select --install' を実行してください。"
command -v curl  >/dev/null 2>&1 || die "curl が必要です。"

FF_PREFIX="$(brew --prefix libfreefare 2>/dev/null || true)"
NFC_PREFIX="$(brew --prefix libnfc 2>/dev/null || true)"
[ -d "$FF_PREFIX/include" ] || die "libfreefare のヘッダが見つかりません。'brew install libfreefare' を実行してください。"
[ -d "$NFC_PREFIX/include" ] || die "libnfc のヘッダが見つかりません。'brew install libnfc' を実行してください。"

mkdir -p "$OUT_BIN"
work="$(mktemp -d -t ffbuild.XXXXXX)"
trap 'rm -rf "$work"' EXIT

for t in "${TOOLS[@]}"; do
  say "取得: $t.c ($REF)"
  curl -fsSL "$BASE_URL/$t.c" -o "$work/$t.c" \
    || die "$t.c の取得に失敗しました($BASE_URL/$t.c)。"

  say "ビルド: $t"
  # HAVE_CONFIG_H は定義しない → autotools 用 config.h のインクルードは無効化される。
  # examples の .c は公開ヘッダ <freefare.h> / <nfc/nfc.h> のみに依存する。
  clang \
    -I"$FF_PREFIX/include" -I"$NFC_PREFIX/include" \
    -L"$FF_PREFIX/lib"     -L"$NFC_PREFIX/lib" \
    -Wl,-rpath,"$FF_PREFIX/lib" -Wl,-rpath,"$NFC_PREFIX/lib" \
    "$work/$t.c" -lfreefare -lnfc \
    -o "$OUT_BIN/$t" \
    || die "$t のコンパイルに失敗しました。"
  printf '    built: %s\n' "$OUT_BIN/$t"
done

say "完了。ビルドしたツール: ${TOOLS[*]}"
say "出力先: $OUT_BIN"
