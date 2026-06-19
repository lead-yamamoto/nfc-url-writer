#!/usr/bin/env bash
#
# write-url.sh — ACR122U + libnfc/libfreefare で MIFARE Classic 1K に
#                NDEF URL を書き込む macOS 用 CLI。
#
# 使い方:
#   ./write-url.sh --format     # 初回: NDEF フォーマットしてから URL 書き込み
#   ./write-url.sh              # 2回目以降: URL の書き込みのみ
#   ./write-url.sh --fix-reader # macOS のスマートカードデーモンを無効化(リーダー認識用)
#   ./write-url.sh --help       # ヘルプ
#
set -euo pipefail

# ═════════════════════════════════════════════════════════════════════════════
#  設定 — ここを書き換える
# ═════════════════════════════════════════════════════════════════════════════
TARGET_URL="${TARGET_URL:-https://example.com/}"
# ═════════════════════════════════════════════════════════════════════════════

# --- 定数 --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$SCRIPT_DIR/bin"               # 自前ビルドしたツールの置き場
BACKUP_DIR="${NFC_BACKUP_DIR:-$SCRIPT_DIR/backups}"  # バックアップ(.mfd)の保存先(NFC_BACKUP_DIR で上書き可)
LIBFREEFARE_REF="libfreefare-0.4.0"       # フォールバックビルド時の参照タグ(brew版に合わせる)
NDEF_TOOLS=(mifare-classic-format mifare-classic-write-ndef mifare-classic-read-ndef)

# 自前ビルドしたツールを優先的に探せるよう PATH の先頭に追加
export PATH="$LOCAL_BIN:$PATH"

# --- 表示ヘルパ --------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  BOLD=; RED=; GRN=; YEL=; DIM=; RST=
fi
info() { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s ![注意]%s %s\n' "$YEL" "$RST" "$*" >&2; }
err()  { printf '%s ✗%s %s\n' "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
${BOLD}write-url.sh${RST} — MIFARE Classic 1K に NDEF URL を書き込む (ACR122U / macOS)

書き込む URL はこのスクリプト冒頭の TARGET_URL を編集して変更します。
  現在の TARGET_URL: ${BOLD}${TARGET_URL}${RST}

使い方:
  ./write-url.sh --format      初回。カードを NDEF フォーマットしてから URL を書く
  ./write-url.sh               2回目以降。URL の書き込みのみ
  ./write-url.sh --fix-reader  macOS が ACR122U を掴んでいる場合に解放する(sudo)
  ./write-url.sh --print-ndef  TARGET_URL から生成される NDEF バイト列を表示して終了
  ./write-url.sh --read        カードに書かれている NDEF URL を読み取って表示
  ./write-url.sh --no-backup   書き込み前のバックアップを行わない
  ./write-url.sh --yes         確認プロンプトを省略する
  ./write-url.sh --help        このヘルプ

処理の流れ: nfc-list で認識確認 → バックアップ → (--format 時のみ)フォーマット
           → URL 書き込み → read-ndef で検証
EOF
}

# --- 引数パース --------------------------------------------------------------
DO_FORMAT=0; ASSUME_YES=0; DO_BACKUP=1; FIX_READER=0; PRINT_NDEF=0; DO_READ=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)     DO_FORMAT=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --no-backup)  DO_BACKUP=0 ;;
    --fix-reader) FIX_READER=1 ;;
    --print-ndef) PRINT_NDEF=1 ;;
    --read)       DO_READ=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) err "不明なオプション: $1"; echo; usage; exit 2 ;;
  esac
  shift
done

# --- 作業用一時ディレクトリ --------------------------------------------------
TMP_WORK="$(mktemp -d -t writeurl.XXXXXX)"
cleanup() { rm -rf "$TMP_WORK"; }
trap cleanup EXIT

# --- 共通ユーティリティ ------------------------------------------------------
require_cmd() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ans
  read -r -p "$(printf '%s%s%s [y/N] ' "$BOLD" "$1" "$RST")" ans || return 1
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# URL から NDEF URI 識別コードと残り文字列を決める (URI_CODE / URI_REST にセット)
ndef_parts() {
  local url="$1"
  case "$url" in
    https://www.*) URI_CODE=02; URI_REST="${url#https://www.}" ;;
    http://www.*)  URI_CODE=01; URI_REST="${url#http://www.}" ;;
    https://*)     URI_CODE=04; URI_REST="${url#https://}" ;;
    http://*)      URI_CODE=03; URI_REST="${url#http://}" ;;
    tel:*)         URI_CODE=05; URI_REST="${url#tel:}" ;;
    mailto:*)      URI_CODE=06; URI_REST="${url#mailto:}" ;;
    *)             URI_CODE=00; URI_REST="$url" ;;
  esac
}

# 単一の NDEF URI レコード(生の NDEF メッセージ)を生成して $2 に書き出す。
# libfreefare の write-ndef は「生の NDEF メッセージ」を受け取り、
# TLV(0x03..0xFE)と MAD/セクタートレーラーは内部で付与する。
build_ndef_message() {
  local url="$1" out="$2"
  ndef_parts "$url"
  local rest_hex rest_len payload_len pl_hex hex
  rest_hex="$(printf '%s' "$URI_REST" | xxd -p | tr -d '\n')"
  rest_len=$(( ${#rest_hex} / 2 ))
  payload_len=$(( rest_len + 1 ))   # +1 は先頭の URI 識別コード
  [ "$payload_len" -le 255 ] || die "URL が長すぎます(short-record NDEF の上限255バイト超過)。"
  pl_hex="$(printf '%02X' "$payload_len")"
  # D1 = MB|ME|SR|TNF(well-known), 01 = Type長, PL = Payload長, 55 = 'U', CODE, 残り
  hex="D101${pl_hex}55${URI_CODE}${rest_hex}"
  printf '%s' "$hex" | xxd -r -p > "$out"
}

# --- macOS リーダー解放 ------------------------------------------------------
fix_reader() {
  info "macOS のスマートカードデーモンを無効化して ACR122U を解放します(sudo が必要)…"
  local svc
  for svc in com.apple.ifdreader com.apple.usbsmartcardreaderd; do
    sudo launchctl bootout  "system/$svc" 2>/dev/null || true   # 起動していなければ無視
    sudo launchctl disable  "system/$svc" 2>/dev/null || true   # 再接続/再起動後も持続
  done
  ok "完了。ACR122U を一度抜き差ししてから 'nfc-list' を実行してください。"
  cat <<EOF
${DIM}元に戻すには:
  sudo launchctl enable system/com.apple.ifdreader
  sudo launchctl enable system/com.apple.usbsmartcardreaderd
  (その後、再接続または再起動)${RST}
EOF
}

reader_help() {
  cat >&2 <<EOF

${YEL}ACR122U が認識されていません。${RST}考えられる原因と対処:

1) macOS のスマートカードスタック(com.apple.ifdreader)がリーダーを占有している。
   これが macOS で最も多い原因です。次を実行して解放してください:

       ${BOLD}./write-url.sh --fix-reader${RST}
       # 実行後、ACR122U を抜き差ししてから再度お試しください

2) ケーブル/ポートの問題。直挿し or 電源付きハブを使ってください。
3) ACR122U の互換品(クローン)。nfc-list は開けても書き込みで失敗する場合があります。
EOF
}

# --- 依存チェック ------------------------------------------------------------
ensure_libnfc() {
  if ! require_cmd nfc-list || ! require_cmd nfc-mfclassic; then
    die "libnfc のツールが見つかりません。'brew install libnfc libfreefare' を実行してください(README参照)。"
  fi
}

ensure_ndef_tools() {
  local missing=0 t
  for t in "${NDEF_TOOLS[@]}"; do require_cmd "$t" || missing=1; done
  if [ "$missing" -eq 1 ]; then
    warn "libfreefare の mifare-classic-* が PATH 上に無いため、ソースからビルドします…"
    "$SCRIPT_DIR/build-tools.sh" || die "libfreefare ツールのビルドに失敗しました(README参照)。"
    hash -r
    for t in "${NDEF_TOOLS[@]}"; do
      require_cmd "$t" || die "ビルド後も $t が見つかりません。"
    done
    ok "ローカルビルド済みツールを使用します: $LOCAL_BIN"
  fi
}

# --- 各ステップ --------------------------------------------------------------
check_reader() {
  info "nfc-list で ACR122U の認識を確認します…"
  local out
  if ! out="$(nfc-list 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    reader_help
    die "nfc-list の実行に失敗しました。"
  fi
  printf '%s\n' "$out" | sed 's/^/    /'
  if printf '%s' "$out" | grep -qi 'ACR122'; then
    ok "ACR122U を認識しました。"
  elif printf '%s' "$out" | grep -qiE 'NFC device.*opened'; then
    warn "NFC デバイスは開けましたが ACR122U と断定できません。続行します。"
  else
    reader_help
    die "ACR122U を認識できませんでした。"
  fi
}

backup_card() {
  if [ "$DO_BACKUP" -ne 1 ]; then
    warn "バックアップをスキップします(--no-backup)。"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  local ts file
  ts="$(date +%Y%m%d-%H%M%S)"
  file="$BACKUP_DIR/backup-$ts.mfd"
  info "カードをバックアップします → $file"
  # R = 読み取り(鍵が分からないセクターはスキップして継続) / a = Key A
  if nfc-mfclassic R a "$file" 2>&1 | sed 's/^/    /'; then
    if [ -s "$file" ]; then ok "バックアップを保存しました: $file"
    else warn "バックアップファイルが空です。"; fi
  else
    warn "バックアップでエラーが発生しました(デフォルト以外の鍵が使われている可能性)。"
    [ -s "$file" ] && warn "部分的なバックアップは保存されています: $file"
    confirm "完全なバックアップ無しで続行しますか？" || die "中止しました。"
  fi
}

format_card() {
  info "カードを NDEF フォーマットします(mifare-classic-format)…"
  if ! mifare-classic-format -y 2>&1 | sed 's/^/    /'; then
    die "フォーマットに失敗しました。"
  fi
  ok "フォーマット完了。"
}

write_url() {
  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "NDEF URL を書き込みます: ${BOLD}${TARGET_URL}${RST}"
  printf '    NDEF メッセージ (%s バイト): ' "$(wc -c < "$TMP_WORK/ndef.bin" | tr -d ' ')"
  xxd -p "$TMP_WORK/ndef.bin" | tr -d '\n'; echo
  if ! mifare-classic-write-ndef -y -i "$TMP_WORK/ndef.bin" 2>&1 | sed 's/^/    /'; then
    die "書き込み(write-ndef)に失敗しました。"
  fi
  ok "URL を書き込みました。"
}

verify_url() {
  info "read-ndef で検証します…"
  if ! mifare-classic-read-ndef -y -o "$TMP_WORK/readback.bin" 2>&1 | sed 's/^/    /'; then
    die "検証(read-ndef)に失敗しました。"
  fi
  printf '    読み戻し (%s バイト): ' "$(wc -c < "$TMP_WORK/readback.bin" | tr -d ' ')"
  xxd -p "$TMP_WORK/readback.bin" | tr -d '\n'; echo
  if cmp -s "$TMP_WORK/ndef.bin" "$TMP_WORK/readback.bin"; then
    ok "検証OK — 読み戻しが書き込み内容と一致しました(URL: $TARGET_URL)"
  elif grep -aq "$URI_REST" "$TMP_WORK/readback.bin"; then
    warn "バイト列は完全一致しませんでしたが URL は含まれています。概ね問題ありません。"
  else
    die "検証に失敗しました — 読み戻しが一致しません。"
  fi
}

decode_ndef() {
  # 生の NDEF URI レコード(short record)から URL を復元して返す。URI でなければ空文字。
  local hex type code rest_hex prefix
  hex="$(xxd -p "$1" | tr -d '\n')"
  [ "${#hex}" -ge 10 ] || { echo ""; return; }
  type="${hex:6:2}"
  code="$(printf '%s' "${hex:8:2}" | tr 'A-F' 'a-f')"
  rest_hex="${hex:10}"
  [ "$type" = "55" ] || { echo ""; return; }   # 0x55 = 'U' (URI レコード)
  case "$code" in
    01) prefix="http://www." ;;
    02) prefix="https://www." ;;
    03) prefix="http://" ;;
    04) prefix="https://" ;;
    05) prefix="tel:" ;;
    06) prefix="mailto:" ;;
    *)  prefix="" ;;
  esac
  printf '%s%s' "$prefix" "$(printf '%s' "$rest_hex" | xxd -r -p)"
}

read_card() {
  info "カードに書かれている NDEF を読み取ります…"
  require_cmd xxd || die "xxd が見つかりません。"
  ensure_libnfc
  ensure_ndef_tools
  check_reader
  if ! mifare-classic-read-ndef -y -o "$TMP_WORK/readback.bin" 2>&1 | sed 's/^/    /'; then
    die "読み取りに失敗しました(NDEF 未フォーマットのカードの可能性)。"
  fi
  printf '    NDEF (%s バイト): ' "$(wc -c < "$TMP_WORK/readback.bin" | tr -d ' ')"
  xxd -p "$TMP_WORK/readback.bin" | tr -d '\n'; echo
  local decoded; decoded="$(decode_ndef "$TMP_WORK/readback.bin")"
  if [ -n "$decoded" ]; then ok "URL: ${BOLD}${decoded}${RST}"
  else warn "URI レコードとして解釈できませんでした(上の生バイトを参照)。"; fi
}

print_iphone_note() {
  cat <<EOF

${YEL}【重要】iPhone での読み取りについて${RST}
  MIFARE Classic は NFC Forum の標準タグ種別(Type 1〜5)ではないため、
  iOS の Core NFC は基本的に NDEF を読み取れません(書き込み自体は成功しても
  iPhone では反応しないことがほとんどです)。
  ${BOLD}iPhone で確実に読み取りたい場合は NTAG213/215/216(NFC Forum Type 2)を推奨します。${RST}
EOF
}

# --- メイン ------------------------------------------------------------------
# --print-ndef: ハードウェア不要。生成される NDEF バイト列だけ表示して終了
if [ "$PRINT_NDEF" -eq 1 ]; then
  require_cmd xxd || die "xxd が見つかりません。"
  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  printf 'URL : %s\n' "$TARGET_URL"
  printf 'NDEF: '; xxd -p "$TMP_WORK/ndef.bin" | tr -d '\n'; echo
  exit 0
fi

# --fix-reader: リーダー解放だけ行って終了
if [ "$FIX_READER" -eq 1 ]; then
  fix_reader
  exit 0
fi

# --read: カード内容を読み取って終了
if [ "$DO_READ" -eq 1 ]; then
  read_card
  exit 0
fi

main() {
  info "対象 URL: ${BOLD}${TARGET_URL}${RST}"
  require_cmd xxd || die "xxd が見つかりません(macOS には通常同梱されています)。"
  ensure_libnfc
  ensure_ndef_tools
  check_reader

  if [ "$DO_FORMAT" -eq 1 ]; then
    confirm "カードをリーダーに置き、フォーマット＋書き込みを実行しますか？" || die "中止しました。"
  else
    confirm "カードをリーダーに置き、'$TARGET_URL' を書き込みますか？" || die "中止しました。"
  fi

  backup_card
  [ "$DO_FORMAT" -eq 1 ] && format_card
  write_url
  verify_url

  echo
  ok "完了しました。"
  print_iphone_note
}

main
