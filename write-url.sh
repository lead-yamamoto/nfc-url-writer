#!/usr/bin/env bash
#
# write-url.sh — ACR122U + libnfc/libfreefare で NFC タグに NDEF URL を
#                書き込む macOS 用 CLI。
#
# 主対象は MIFARE Classic 1K。カード種別(SAK)を自動判定し、
# NTAG213/215/216(Type2) と MIFARE DESFire(Type4) にも実験的に対応。
#
# 使い方:
#   ./write-url.sh --format     # 初回: NDEF フォーマットしてから URL 書き込み
#   ./write-url.sh              # 2回目以降: URL の書き込みのみ
#   ./write-url.sh --fix-reader # macOS のスマートカードデーモンを無効化(リーダー認識用)
#   ./write-url.sh --help       # ヘルプ
#
# 注: 本スクリプトは Swift アプリから macOS 標準 /bin/bash (3.2) で実行される。
#     連想配列・${var,,}・mapfile 等 bash4+ 専用機能は使用しないこと。
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

# リトライ設定(他の Mac でリーダー掴み合いにより数回失敗する問題への対策)
RETRY_MAX="${NFC_RETRY_MAX:-4}"           # 最大試行回数
RETRY_SLEEP="${NFC_RETRY_SLEEP:-0.8}"     # 試行間の待機秒数

# 効果音(どのリーダーでも鳴る Mac 本体スピーカー)。NFC_SOUND=0 か --no-sound で無効化
NFC_SOUND="${NFC_SOUND:-1}"
SOUND_OK="/System/Library/Sounds/Glass.aiff"
SOUND_NG="/System/Library/Sounds/Basso.aiff"

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

# --- 効果音ヘルパ ------------------------------------------------------------
# afplay をバックグラウンド実行。afplay が無い/NFC_SOUND=0 の時は何もしない。
play_sound() {
  [ "$NFC_SOUND" = "1" ] || return 0
  require_cmd afplay || return 0
  [ -f "$1" ] || return 0
  afplay "$1" >/dev/null 2>&1 &
}
sound_ok() { play_sound "$SOUND_OK"; }
sound_ng() { play_sound "$SOUND_NG"; }

# die: 失敗音を鳴らしてから終了。--print-ndef/--fix-reader では鳴らさないよう
#      それらのフローは die を通らない(独立分岐)ため自然に除外される。
die()  { err "$*"; sound_ng; exit 1; }

usage() {
  cat <<EOF
${BOLD}write-url.sh${RST} — NFC タグに NDEF URL を書き込む (ACR122U / macOS)

書き込む URL はこのスクリプト冒頭の TARGET_URL を編集して変更します。
  現在の TARGET_URL: ${BOLD}${TARGET_URL}${RST}

使い方:
  ./write-url.sh --format      初回。カードを NDEF フォーマットしてから URL を書く
  ./write-url.sh               2回目以降。URL の書き込みのみ
  ./write-url.sh --fix-reader  macOS が ACR122U を掴んでいる場合に解放する(sudo)
  ./write-url.sh --print-ndef  TARGET_URL から生成される NDEF バイト列を表示して終了
  ./write-url.sh --read        カードに書かれている NDEF URL を読み取って表示
  ./write-url.sh --no-backup   書き込み前のバックアップを行わない
  ./write-url.sh --no-sound    成功/失敗の効果音を鳴らさない(NFC_SOUND=0 でも可)
  ./write-url.sh --yes         確認プロンプトを省略する
  ./write-url.sh --help        このヘルプ

カード種別の自動判定:
  nfc-list の SAK 値からカード種別を判定して処理を振り分けます。
    ・MIFARE Classic 1K/4K … 通常対応(主対象)
    ・NTAG213/215/216(Type2) … ${YEL}実験的対応${RST}(--yes もしくは確認が必要)
    ・MIFARE DESFire(Type4) … ${YEL}実験的対応${RST}
    ・FeliCa … 非対応
  ※ MIFARE Classic の読み書きには NXP系チップのリーダー(ACR122U など)が必須です。
    Sony RC-S300 等の FeliCa系/PC-SC リーダーでは MIFARE Classic を扱えません。

安定性: リーダー検出・各操作は自動で最大 ${RETRY_MAX} 回まで再試行します。
        失敗が続く場合は ./write-url.sh --fix-reader でリーダーを解放し抜き差ししてください。

処理の流れ: nfc-list で認識確認 → (Classicのみ)バックアップ → (--format 時のみ)フォーマット
           → URL 書き込み → read-ndef で検証
EOF
}

# --- 引数パース --------------------------------------------------------------
DO_FORMAT=0; ASSUME_YES=0; DO_BACKUP=1; FIX_READER=0; PRINT_NDEF=0; DO_READ=0; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)     DO_FORMAT=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --no-backup)  DO_BACKUP=0 ;;
    --no-sound)   NFC_SOUND=0 ;;
    --fix-reader) FIX_READER=1 ;;
    --print-ndef) PRINT_NDEF=1 ;;
    --read)       DO_READ=1 ;;
    --self-test)  SELF_TEST=1 ;;   # 内部用: SAK 判定などの単体テスト
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

# --- リトライ機構 ------------------------------------------------------------
# retry LABEL CMD [ARGS...] : CMD を最大 RETRY_MAX 回まで実行し、成功したら 0。
#   各失敗の後に RETRY_SLEEP 秒待ち、日本語で「再試行 N/MAX…」を表示する。
#   コマンドの stdout/stderr はそのまま流す。最後の試行の終了コードを返す。
#   set -e 下でも安全なよう、終了コードは明示的に捕捉する(|| 付きで実行)。
retry() {
  local label="$1"; shift
  local attempt=1 rc=0
  while :; do
    rc=0
    "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$attempt" -ge "$RETRY_MAX" ]; then
      return "$rc"
    fi
    attempt=$(( attempt + 1 ))
    warn "${label}: 失敗しました。再試行 ${attempt}/${RETRY_MAX}…"
    sleep "$RETRY_SLEEP" || true
  done
}

# 出力を変数に取り込みつつリトライしたい場合用。
#   retry_capture VARNAME LABEL CMD [ARGS...]
#   成功時: VARNAME に stdout+stderr を格納して 0 を返す。
#   失敗時: VARNAME に最後の試行の出力を格納して非0を返す。
retry_capture() {
  # 注意: 出力先変数名を呼び出し側と衝突させないため、内部変数はすべて
  #       __rc_ プレフィックスにする(bash3.2 は動的スコープで、同名 local が
  #       あると eval 代入が呼び出し側へ届かないため)。
  local __rc_var="$1" __rc_label="$2"; shift 2
  local __rc_attempt=1 __rc_rc=0 __rc_out=""
  while :; do
    __rc_rc=0
    __rc_out="$("$@" 2>&1)" || __rc_rc=$?
    if [ "$__rc_rc" -eq 0 ]; then
      eval "$__rc_var=\$__rc_out"
      return 0
    fi
    if [ "$__rc_attempt" -ge "$RETRY_MAX" ]; then
      eval "$__rc_var=\$__rc_out"
      return "$__rc_rc"
    fi
    __rc_attempt=$(( __rc_attempt + 1 ))
    warn "${__rc_label}: 失敗しました。再試行 ${__rc_attempt}/${RETRY_MAX}…"
    sleep "$RETRY_SLEEP" || true
  done
}

# --- 失敗シグネチャからの案内 ------------------------------------------------
# nfc 系の失敗出力に「掴み合い」系の兆候があれば、リーダー解放を案内する。
maybe_reader_busy_hint() {
  local text="$1"
  case "$text" in
    *"Unable to claim USB interface"*|*"Device or resource busy"*|*"No NFC device found"*)
      cat >&2 <<EOF

${YEL}macOS がリーダーを掴んでいる可能性があります。${RST}
  次を実行してリーダーを解放し、ACR122U を一度抜き差ししてから再度お試しください:

      ${BOLD}./write-url.sh --fix-reader${RST}   (アプリでは「リーダー解放」ボタン)
EOF
      ;;
  esac
}

# --- カード種別(SAK)判定 --------------------------------------------------
# nfc-list の出力文字列を受け取り、以下のグローバルにセットする:
#   TAG_TYPE   : classic | type2 | type4 | felica | unknown
#   TAG_SAK    : 検出した SAK バイト(2桁16進, 無ければ空)
#   TAG_DEVICE : "NFC device:" 行の内容(無ければ空)
# 判定ロジック(バックグラウンド事実に基づく):
#   SAK 08/88/09/18 = MIFARE Classic / 00 = Type2(Ultralight/NTAG) /
#   20 = Type4(ISO14443-4, DESFire 等)。
#   ISO14443A ターゲットが無く FeliCa セクションがあれば felica。
parse_tag_type() {
  local out="$1" sak_line dev sak
  # SAK (SEL_RES): XX の XX を取り出す(先頭一致の1件)。大文字小文字/前後空白を吸収。
  # 注: set -e 下では grep の非0終了で落ちるため、|| true で必ず成功させる。
  sak_line="$(printf '%s\n' "$out" | grep -iE 'SAK[[:space:]]*\(SEL_RES\)' | head -1)" || true
  sak=""
  if [ -n "$sak_line" ]; then
    sak="$(printf '%s' "$sak_line" | sed -E 's/.*:[[:space:]]*([0-9a-fA-F]{1,2}).*/\1/' | tr 'A-F' 'a-f')" || true
  fi
  # 1桁で来た場合は 0 埋めして2桁化
  if [ -n "$sak" ] && [ "${#sak}" -eq 1 ]; then sak="0$sak"; fi
  dev="$(printf '%s\n' "$out" | grep -iE 'NFC device' | head -1)" || true
  dev="$(printf '%s' "$dev" | sed -E 's/^[[:space:]]*//')" || true
  TAG_SAK="$sak"
  TAG_DEVICE="$dev"

  case "$sak" in
    08|88|09|18|28|98|38) TAG_TYPE="classic" ; return 0 ;;
    00)                   TAG_TYPE="type2"   ; return 0 ;;
    20|24)                TAG_TYPE="type4"   ; return 0 ;;
  esac

  # SAK が取れない/一致しない場合: FeliCa セクションの有無で判定。
  # ISO14443A ターゲットが無く FeliCa 情報があれば felica。
  if printf '%s\n' "$out" | grep -qiE 'FeliCa|212F2|424F2|Sony|Type3|NFC-F'; then
    if ! printf '%s\n' "$out" | grep -qiE 'ISO14443A|MIFARE|SAK'; then
      TAG_TYPE="felica"; return 0
    fi
  fi
  TAG_TYPE="unknown"
  return 0
}

# 開いた libnfc デバイスが「汎用 PC/SC リーダー(ACR122 以外)」かを判定。
# device 行に "pcsc:" を含み、かつ "ACR122" を含まなければ true(=非対応リーダー)。
is_generic_pcsc_reader() {
  case "$TAG_DEVICE" in
    *pcsc:*|*PCSC:*|*"pcsc "*)
      case "$TAG_DEVICE" in
        *ACR122*|*Acr122*|*acr122*) return 1 ;;  # ACR122 は PC/SC 経由でも可
        *) return 0 ;;
      esac
      ;;
  esac
  return 1
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
# check_reader: nfc-list をリトライ付きで実行し、認識確認とカード種別判定を行う。
#   NFC_LIST_OUT にツール出力を保存し、TAG_TYPE/TAG_SAK/TAG_DEVICE を設定する。
check_reader() {
  info "nfc-list で NFC リーダー/カードの認識を確認します…"
  local out rc=0
  # nfc-list 自体をリトライ(他 Mac での掴み合いによる初回失敗対策)
  retry_capture out "リーダー検出(nfc-list)" nfc-list || rc=$?
  NFC_LIST_OUT="$out"
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then
    maybe_reader_busy_hint "$out"
    reader_help
    die "nfc-list の実行に失敗しました。"
  fi

  if printf '%s' "$out" | grep -qi 'ACR122'; then
    ok "ACR122U を認識しました。"
  elif printf '%s' "$out" | grep -qiE 'NFC device.*opened'; then
    warn "NFC デバイスは開けましたが ACR122U と断定できません。続行します。"
  else
    maybe_reader_busy_hint "$out"
    reader_help
    die "NFC リーダーを認識できませんでした。"
  fi

  # カード種別を判定(TAG_TYPE / TAG_SAK / TAG_DEVICE をセット)
  parse_tag_type "$out"
  if [ -n "$TAG_SAK" ]; then
    info "カード種別を判定しました: ${BOLD}${TAG_TYPE}${RST} (SAK=${TAG_SAK})"
  else
    info "カード種別を判定しました: ${BOLD}${TAG_TYPE}${RST}"
  fi
}

# 判定したカード種別に応じて、書き込み処理の対応可否を決める。
# 非対応/実験的なケースはここで die するか、実験的警告を出す。
route_tag_or_die() {
  case "$TAG_TYPE" in
    classic)
      # 汎用 PC/SC リーダー(ACR122 以外)では Crypto1 認証ができない
      if is_generic_pcsc_reader; then
        die "MIFARE Classic の読み書きには NXP系チップのリーダー(ACR122U など)が必要です。Sony RC-S300 等の FeliCa系/PC-SCリーダーでは MIFARE Classic を扱えません。"
      fi
      ;;
    type2|type4)
      : # 実験的パス。各 write/read 関数側で警告と確認を行う。
      ;;
    felica)
      die "FeliCa カードには対応していません(NDEF URL 書き込み対象外)。NTAG213/215/216 か MIFARE Classic 1K をご利用ください。"
      ;;
    *)
      die "未対応または判別できないカードです(SAK=${TAG_SAK:-不明})。NTAG213/215/216・MIFARE Classic 1K・MIFARE DESFire のいずれかをご利用ください。"
      ;;
  esac
}

# mfclassic のバックアップ本体(リトライ対象。出力は sed 整形して表示)。
_run_backup() { nfc-mfclassic R a "$1" 2>&1 | sed 's/^/    /'; }

backup_card() {
  # バックアップは MIFARE Classic 専用。他種別ではスキップを通知。
  if [ "${TAG_TYPE:-classic}" != "classic" ]; then
    warn "バックアップは MIFARE Classic 専用のためスキップします(現在: ${TAG_TYPE:-不明})。"
    return 0
  fi
  if [ "$DO_BACKUP" -ne 1 ]; then
    warn "バックアップをスキップします(--no-backup)。"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  local ts file rc=0
  ts="$(date +%Y%m%d-%H%M%S)"
  file="$BACKUP_DIR/backup-$ts.mfd"
  info "カードをバックアップします → $file"
  # R = 読み取り(鍵が分からないセクターはスキップして継続) / a = Key A
  retry "バックアップ(nfc-mfclassic)" _run_backup "$file" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ -s "$file" ]; then ok "バックアップを保存しました: $file"
    else warn "バックアップファイルが空です。"; fi
  else
    warn "バックアップでエラーが発生しました(デフォルト以外の鍵が使われている可能性)。"
    [ -s "$file" ] && warn "部分的なバックアップは保存されています: $file"
    confirm "完全なバックアップ無しで続行しますか？" || die "中止しました。"
  fi
}

_run_format() { mifare-classic-format -y 2>&1 | sed 's/^/    /'; }

format_card() {
  info "カードを NDEF フォーマットします(mifare-classic-format)…"
  local rc=0
  retry "フォーマット(mifare-classic-format)" _run_format || rc=$?
  [ "$rc" -eq 0 ] || die "フォーマットに失敗しました。"
  ok "フォーマット完了。"
}

_run_write_classic() { mifare-classic-write-ndef -y -i "$1" 2>&1 | sed 's/^/    /'; }

write_url() {
  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "NDEF URL を書き込みます: ${BOLD}${TARGET_URL}${RST}"
  printf '    NDEF メッセージ (%s バイト): ' "$(wc -c < "$TMP_WORK/ndef.bin" | tr -d ' ')"
  xxd -p "$TMP_WORK/ndef.bin" | tr -d '\n'; echo
  local rc=0
  retry "書き込み(write-ndef)" _run_write_classic "$TMP_WORK/ndef.bin" || rc=$?
  [ "$rc" -eq 0 ] || die "書き込み(write-ndef)に失敗しました。"
  ok "URL を書き込みました。"
}

# read-ndef をリトライ付きで実行。成功時 readback.bin を生成。
# 出力は READ_NDEF_OUT に保持(空カード判定などに使う)。戻り値は最終試行の終了コード。
_read_ndef_classic() {
  READ_NDEF_OUT="$(mifare-classic-read-ndef -y -o "$1" 2>&1)"
  local rc=$?
  printf '%s\n' "$READ_NDEF_OUT" | sed 's/^/    /'
  return "$rc"
}

verify_url() {
  info "read-ndef で検証します…"
  local rc=0
  retry "検証(read-ndef)" _read_ndef_classic "$TMP_WORK/readback.bin" || rc=$?
  [ "$rc" -eq 0 ] || die "検証(read-ndef)に失敗しました。"
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

# ═════════════════════════════════════════════════════════════════════════════
#  実験的: Type2 (NTAG213/215/216 / MIFARE Ultralight)
# ═════════════════════════════════════════════════════════════════════════════
# 方針(安全第一): まずカードを nfc-mfultralight で読み出し、正しい容量・UID・CC・
#   ロック/OTP バイトを保持したイメージを得る。その上で「データページ(4ページ目以降)」
#   にのみ NDEF TLV を差し込み、同じイメージを書き戻す。
#   書き戻し時、OTP/Lock/DynLock/UID の各プロンプトには必ず 'n' を送り、
#   ロック/OTP/UID を絶対に書かない(タグを壊さない)。
#   カードが読めない(空・ロック等)場合はブラインド書き込みを避け、明示エラーにする。

# Type2 の生 NDEF メッセージから、page4 以降に載せる「TLVペイロード」を作る。
#   0x03 <len> <raw ndef...> 0xFE  (len は1バイト、247バイトまでを想定)
# 生成した16進文字列(4バイト境界に 0x00 でパディング)を標準出力に返す。
build_type2_tlv_hex() {
  local ndef_hex ndef_len tlv_hex total pad
  ndef_hex="$(xxd -p "$1" | tr -d '\n')"
  ndef_len=$(( ${#ndef_hex} / 2 ))
  if [ "$ndef_len" -gt 254 ]; then
    return 3   # 1バイト長TLVの範囲外(この用途では起こらない想定)
  fi
  tlv_hex="03$(printf '%02x' "$ndef_len")${ndef_hex}fe"
  # 4バイト(=1ページ)境界へ 0x00 パディング
  total=$(( ${#tlv_hex} / 2 ))
  pad=$(( (4 - (total % 4)) % 4 ))
  while [ "$pad" -gt 0 ]; do tlv_hex="${tlv_hex}00"; pad=$(( pad - 1 )); done
  printf '%s' "$tlv_hex"
}

# 読み出したダンプ($1)のデータ領域(オフセット16バイト目=page4以降)に
# TLV 16進($2)を上書きし、残りは 0x00 で埋めて $3 に書き出す。
# CC(page3)・UID/ロック(page0-2)・末尾のロック/設定ページは元のまま保持する。
patch_type2_dump() {
  local src="$1" tlv_hex="$2" dst="$3"
  local size head_hex tlv_len data_cap all_hex tail_start tail_hex new_hex
  size=$(wc -c < "$src" | tr -d ' ')
  # 少なくとも 16バイト(page0-3)は必要
  if [ "$size" -lt 16 ]; then return 4; fi
  all_hex="$(xxd -p "$src" | tr -d '\n')"
  head_hex="${all_hex:0:32}"          # page0-3 (16バイト) = UID/内部/ロック/CC
  tlv_len=$(( ${#tlv_hex} / 2 ))
  data_cap=$(( size - 16 ))           # page4 以降に使える総バイト数
  # NTAG216 では末尾にダイナミックロック/CFG があるが、
  # NDEF 用ユーザ領域に収まる限りは触れない。ここでは TLV がユーザ領域に
  # 収まることのみ確認し、超える場合はエラー(容量不足)。
  if [ "$tlv_len" -gt "$data_cap" ]; then return 5; fi
  # データ領域全体を 0x00 で初期化した文字列を作り、先頭に TLV を載せる。
  local zeros="" i=0
  # data_cap バイト分のゼロ列(16進)を生成
  while [ "$i" -lt "$data_cap" ]; do zeros="${zeros}00"; i=$(( i + 1 )); done
  # TLV をゼロ列の先頭へ上書き
  local data_hex="${tlv_hex}${zeros:$(( tlv_len * 2 ))}"
  # ただし NTAG21x の末尾数ページ(ダイナミックロック/CFG/PWD/PACK 等)は
  # 元イメージのまま温存する。安全のため末尾16バイトは保持する。
  if [ "$data_cap" -gt 16 ]; then
    tail_start=$(( (size - 16) * 2 ))      # 末尾16バイトの開始(全体16進上の位置)
    tail_hex="${all_hex:$tail_start}"
    # data_hex のうち、末尾16バイトに相当する部分を元イメージで置換
    local keep_from=$(( (data_cap - 16) * 2 ))
    data_hex="${data_hex:0:$keep_from}${tail_hex}"
  fi
  new_hex="${head_hex}${data_hex}"
  printf '%s' "$new_hex" | xxd -r -p > "$dst"
}

# Type2 ダンプ($1)のデータ領域から NDEF TLV(0x03 len ... 0xFE)を探し、
# 生 NDEF メッセージを $2 に書き出す。見つからなければ非0を返す。
extract_type2_ndef() {
  local src="$1" dst="$2" all_hex data_hex i len2 t l ndef_hex
  all_hex="$(xxd -p "$src" | tr -d '\n')"
  [ "${#all_hex}" -ge 40 ] || return 1
  data_hex="${all_hex:32}"        # page4 以降(先頭16バイト=page0-3をスキップ)
  i=0
  while [ $(( i + 2 )) -le "${#data_hex}" ]; do
    t="${data_hex:$i:2}"
    case "$t" in
      03)  # NDEF メッセージ TLV
        len2="${data_hex:$(( i + 2 )):2}"
        [ -n "$len2" ] || return 1
        l=$(( 16#$len2 ))
        ndef_hex="${data_hex:$(( i + 4 )):$(( l * 2 ))}"
        [ "${#ndef_hex}" -eq $(( l * 2 )) ] || return 1
        printf '%s' "$ndef_hex" | xxd -r -p > "$dst"
        return 0
        ;;
      00)  i=$(( i + 2 )) ;;             # NULL TLV(1バイト)
      fe)  return 1 ;;                   # Terminator
      *)   # その他 TLV: 1バイト長を読み飛ばす
        len2="${data_hex:$(( i + 2 )):2}"
        [ -n "$len2" ] || return 1
        l=$(( 16#$len2 ))
        i=$(( i + 4 + l * 2 ))
        ;;
    esac
  done
  return 1
}

_ul_read() { nfc-mfultralight r "$1" 2>&1 | sed 's/^/    /'; }
# 書き戻し: OTP/Lock/DynLock/UID の各プロンプトへ 'n' を送り、危険ページを書かない。
_ul_write() { printf 'n\nn\nn\nn\n' | nfc-mfultralight w "$1" 2>&1 | sed 's/^/    /'; }

write_url_type2() {
  warn "【実験的機能】Type2(NTAG/Ultralight)への書き込みを行います。"
  warn "ロック/OTP ページには一切書き込みません(タグ保護のため)。"
  confirm "この Type2 カードに実験的に書き込みますか？" || die "中止しました。"

  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "NDEF URL を書き込みます(Type2): ${BOLD}${TARGET_URL}${RST}"

  # 1) 現在のカードを読み出して、正しい容量/UID/CC/ロックを保持したイメージを得る
  info "カードを読み出して安全な書き込みイメージを作成します(nfc-mfultralight r)…"
  local rc=0
  retry "Type2 読み出し(nfc-mfultralight r)" _ul_read "$TMP_WORK/ul_dump.mfd" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$TMP_WORK/ul_dump.mfd" ]; then
    die "Type2 カードの読み出しに失敗しました。空/ロック/パスワード保護の可能性があります。安全のためブラインド書き込みは行いません。"
  fi

  # 2) TLV を組み立て、データページ(page4以降)にのみ差し込む
  local tlv_hex
  tlv_hex="$(build_type2_tlv_hex "$TMP_WORK/ndef.bin")" || die "NDEF が Type2 の1バイト長TLVに収まりません。"
  if ! patch_type2_dump "$TMP_WORK/ul_dump.mfd" "$tlv_hex" "$TMP_WORK/ul_write.mfd"; then
    die "書き込みイメージの生成に失敗しました(容量不足の可能性)。より大きな NTAG をご利用ください。"
  fi

  # 3) 書き戻し(危険ページはプロンプトに 'n' を返して回避)
  info "イメージを書き戻します(nfc-mfultralight w、ロック/OTP は書きません)…"
  rc=0
  retry "Type2 書き込み(nfc-mfultralight w)" _ul_write "$TMP_WORK/ul_write.mfd" || rc=$?
  [ "$rc" -eq 0 ] || die "Type2 書き込みに失敗しました。"
  ok "Type2 への書き込みを実行しました(実験的機能)。"

  # 4) 検証: 読み戻して NDEF/URL が載っているか確認
  info "読み戻して検証します(nfc-mfultralight r)…"
  rc=0
  retry "Type2 検証読み出し(nfc-mfultralight r)" _ul_read "$TMP_WORK/ul_verify.mfd" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$TMP_WORK/ul_verify.mfd" ]; then
    if grep -aq "$URI_REST" "$TMP_WORK/ul_verify.mfd"; then
      ok "検証OK — カード上に URL を確認しました(URL: $TARGET_URL)"
    else
      warn "書き込みは実行しましたが、検証で URL を確認できませんでした。iPhone 等で実機確認をおすすめします。"
    fi
  else
    warn "検証用の読み出しに失敗しました。書き込み自体は実行済みです。"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  実験的: Type4 (MIFARE DESFire)
# ═════════════════════════════════════════════════════════════════════════════
_df_create() { mifare-desfire-create-ndef -y 2>&1 | sed 's/^/    /'; }
_df_write()  { mifare-desfire-write-ndef -y -i "$1" 2>&1 | sed 's/^/    /'; }
_df_read()   { mifare-desfire-read-ndef -y -o "$1" 2>&1 | sed 's/^/    /'; }

write_url_type4() {
  warn "【実験的機能】Type4(MIFARE DESFire)への書き込みを行います。"
  confirm "この Type4(DESFire)カードに実験的に書き込みますか？" || die "中止しました。"

  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "NDEF URL を書き込みます(Type4/DESFire): ${BOLD}${TARGET_URL}${RST}"

  local rc=0
  # --format 指定時のみ NDEF アプリケーションを作成(既存 NDEF タグを壊さない)
  if [ "$DO_FORMAT" -eq 1 ]; then
    info "DESFire を NFC Forum Type4 として初期化します(create-ndef)…"
    rc=0
    retry "DESFire 初期化(create-ndef)" _df_create || rc=$?
    [ "$rc" -eq 0 ] || die "DESFire の NDEF アプリケーション作成に失敗しました。"
  fi

  info "NDEF を書き込みます(write-ndef)…"
  rc=0
  retry "DESFire 書き込み(write-ndef)" _df_write "$TMP_WORK/ndef.bin" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # 未初期化の DESFire だと write が失敗する。--format を案内。
    die "DESFire への書き込みに失敗しました。未初期化の可能性があります。--format を付けて再実行してください。"
  fi
  ok "Type4(DESFire)への書き込みを実行しました(実験的機能)。"

  info "read-ndef で検証します…"
  rc=0
  retry "DESFire 検証(read-ndef)" _df_read "$TMP_WORK/readback.bin" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$TMP_WORK/readback.bin" ]; then
    if cmp -s "$TMP_WORK/ndef.bin" "$TMP_WORK/readback.bin" || grep -aq "$URI_REST" "$TMP_WORK/readback.bin"; then
      ok "検証OK — カード上に URL を確認しました(URL: $TARGET_URL)"
    else
      warn "書き込みは実行しましたが、読み戻しが一致しませんでした。"
    fi
  else
    warn "検証用の読み出しに失敗しました。書き込み自体は実行済みです。"
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

# 読み取ったバイナリを表示し、URL を復元して報告する共通処理。
_report_read_result() {
  printf '    NDEF (%s バイト): ' "$(wc -c < "$1" | tr -d ' ')"
  xxd -p "$1" | tr -d '\n'; echo
  local decoded; decoded="$(decode_ndef "$1")"
  if [ -n "$decoded" ]; then ok "URL: ${BOLD}${decoded}${RST}"; sound_ok
  else warn "URI レコードとして解釈できませんでした(上の生バイトを参照)。"; fi
}

read_card() {
  info "カードに書かれている NDEF を読み取ります…"
  require_cmd xxd || die "xxd が見つかりません。"
  ensure_libnfc
  check_reader

  case "$TAG_TYPE" in
    classic)
      if is_generic_pcsc_reader; then
        die "MIFARE Classic の読み書きには NXP系チップのリーダー(ACR122U など)が必要です。Sony RC-S300 等の FeliCa系/PC-SCリーダーでは MIFARE Classic を扱えません。"
      fi
      ensure_ndef_tools
      local rc=0
      retry "読み取り(read-ndef)" _read_ndef_classic "$TMP_WORK/readback.bin" || rc=$?
      if [ "$rc" -ne 0 ]; then
        # 空カード(未フォーマット)を優しいメッセージに置き換える
        if printf '%s' "${READ_NDEF_OUT:-}" | grep -qi 'No MAD detected'; then
          err "このカードはまだ空です(NDEF 未フォーマット)。先に『書き込む』を実行してください。"
          sound_ng; exit 1
        fi
        maybe_reader_busy_hint "${READ_NDEF_OUT:-}"
        die "読み取りに失敗しました。"
      fi
      _report_read_result "$TMP_WORK/readback.bin"
      ;;
    type4)
      warn "【実験的機能】Type4(DESFire)から読み取ります。"
      local rc=0
      retry "読み取り(DESFire read-ndef)" _df_read "$TMP_WORK/readback.bin" || rc=$?
      if [ "$rc" -ne 0 ] || [ ! -s "$TMP_WORK/readback.bin" ]; then
        err "このカードはまだ空か、NDEF 未対応です。先に『書き込む』(--format 併用)を実行してください。"
        sound_ng; exit 1
      fi
      _report_read_result "$TMP_WORK/readback.bin"
      ;;
    type2)
      warn "【実験的機能】Type2(NTAG/Ultralight)から読み取ります。"
      local rc=0
      retry "読み取り(nfc-mfultralight r)" _ul_read "$TMP_WORK/ul_dump.mfd" || rc=$?
      if [ "$rc" -ne 0 ] || [ ! -s "$TMP_WORK/ul_dump.mfd" ]; then
        err "このカードはまだ空か、読み取りに失敗しました。先に『書き込む』を実行してください。"
        sound_ng; exit 1
      fi
      # ダンプ(page4以降)から NDEF TLV を取り出して URL を復元
      if extract_type2_ndef "$TMP_WORK/ul_dump.mfd" "$TMP_WORK/readback.bin" && [ -s "$TMP_WORK/readback.bin" ]; then
        _report_read_result "$TMP_WORK/readback.bin"
      else
        warn "ダンプから NDEF を取り出せませんでした。生ダンプの先頭を参照してください:"
        xxd "$TMP_WORK/ul_dump.mfd" 2>/dev/null | head -8 | sed 's/^/    /'
      fi
      ;;
    felica)
      die "FeliCa カードには対応していません(NDEF URL 書き込み対象外)。NTAG213/215/216 か MIFARE Classic 1K をご利用ください。"
      ;;
    *)
      die "未対応または判別できないカードです(SAK=${TAG_SAK:-不明})。"
      ;;
  esac
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

# --- 内部セルフテスト --------------------------------------------------------
# ハードウェア不要。parse_tag_type / is_generic_pcsc_reader / TLV 生成を検証する。
run_self_test() {
  local fails=0
  _expect() { # _expect 説明 期待 実際
    if [ "$2" = "$3" ]; then
      printf 'ok   %s (=%s)\n' "$1" "$3"
    else
      printf 'FAIL %s : 期待=%s 実際=%s\n' "$1" "$2" "$3"; fails=$(( fails + 1 ))
    fi
  }

  local fixture
  fixture="$(cat <<'FX'
nfc-list uses libnfc 1.8.0
NFC device: ACR122U PICC Interface opened
1 ISO14443A passive target(s) found:
ISO/IEC 14443A (106 kbps) target:
    ATQA (SENS_RES): 00  04
       UID (NFCID1): d5  3e  1a  8b
      SAK (SEL_RES): 08
FX
)"
  parse_tag_type "$fixture"; _expect "SAK08=>classic" classic "$TAG_TYPE"; _expect "SAK08 byte" 08 "$TAG_SAK"

  fixture="$(cat <<'FX'
NFC device: ACR122U PICC Interface opened
1 ISO14443A passive target(s) found:
ISO/IEC 14443A (106 kbps) target:
    ATQA (SENS_RES): 00  44
      SAK (SEL_RES): 00
FX
)"
  parse_tag_type "$fixture"; _expect "SAK00=>type2" type2 "$TAG_TYPE"

  fixture="$(cat <<'FX'
NFC device: ACR122U PICC Interface opened
1 ISO14443A passive target(s) found:
ISO/IEC 14443A (106 kbps) target:
    ATQA (SENS_RES): 03  44
      SAK (SEL_RES): 20
FX
)"
  parse_tag_type "$fixture"; _expect "SAK20=>type4" type4 "$TAG_TYPE"

  fixture="$(cat <<'FX'
NFC device: pn53x_uart:/dev/tty.usbserial opened
1 FeliCa (212 kbps) passive target(s) found:
ID (NFCID2): 01 27 00 12 34 56 78 9a
    PAD: 01 20 22 04 27 8b
FX
)"
  parse_tag_type "$fixture"; _expect "FeliCa=>felica" felica "$TAG_TYPE"

  # PC/SC 汎用リーダー判定
  TAG_DEVICE="NFC device: pcsc:Sony FeliCa Port/PaSoRi 3.0 opened"
  if is_generic_pcsc_reader; then _expect "pcsc(sony)=>generic" yes yes; else _expect "pcsc(sony)=>generic" yes no; fi
  TAG_DEVICE="NFC device: pcsc:ACS ACR122U PICC Interface opened"
  if is_generic_pcsc_reader; then _expect "pcsc(ACR122)=>notgeneric" no yes; else _expect "pcsc(ACR122)=>notgeneric" no no; fi
  TAG_DEVICE="NFC device: ACR122U PICC Interface opened"
  if is_generic_pcsc_reader; then _expect "usb(ACR122)=>notgeneric" no yes; else _expect "usb(ACR122)=>notgeneric" no no; fi

  # Type2 TLV 生成: 実際に生成した NDEF から期待 TLV を組み立てて突合する。
  build_ndef_message "https://example.com/" "$TMP_WORK/st_ndef.bin"
  local ndef_hex tlv exp_prefix
  ndef_hex="$(xxd -p "$TMP_WORK/st_ndef.bin" | tr -d '\n')"
  tlv="$(build_type2_tlv_hex "$TMP_WORK/st_ndef.bin")"
  # 期待: 03 <len> <ndef...> fe (len = NDEF バイト長)
  exp_prefix="03$(printf '%02x' $(( ${#ndef_hex} / 2 )))${ndef_hex}fe"
  case "$tlv" in
    "$exp_prefix"*) _expect "type2 TLV 先頭" ok ok ;;
    *) _expect "type2 TLV 先頭" "$exp_prefix" "$tlv" ;;
  esac
  # 4バイト境界(16進長が8の倍数)であること
  local mod=$(( ${#tlv} % 8 ))
  _expect "type2 TLV 4byte境界" 0 "$mod"

  # extract_type2_ndef は build_type2_tlv_hex の逆変換になっていること(往復)
  local dump="$TMP_WORK/st_dump.mfd"
  # 疑似 NTAG213 ダンプ: page0-3(16B) + データ領域(TLVを含む) を生成
  printf '%s' "0405060708090a0b0c0d0e0fe1100600${tlv}" | xxd -r -p > "$dump"
  # 残りを 0 埋めして最低 45ページ(180B)確保(NTAG213相当)
  while [ "$(wc -c <"$dump" | tr -d ' ')" -lt 180 ]; do printf '\000\000\000\000' >> "$dump"; done
  if extract_type2_ndef "$dump" "$TMP_WORK/st_rt.bin" && cmp -s "$TMP_WORK/st_ndef.bin" "$TMP_WORK/st_rt.bin"; then
    _expect "type2 TLV 往復抽出" ok ok
  else
    _expect "type2 TLV 往復抽出" ok "NG"
  fi

  echo
  if [ "$fails" -eq 0 ]; then ok "セルフテスト: 全項目 PASS"; return 0
  else err "セルフテスト: ${fails} 件 FAIL"; return 1; fi
}

# --- メイン ------------------------------------------------------------------
# --self-test: 内部ロジックの単体テスト(ハードウェア不要)
if [ "$SELF_TEST" -eq 1 ]; then
  run_self_test
  exit $?
fi

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
  check_reader
  route_tag_or_die   # 非対応(FeliCa/不明)や非対応リーダーはここで停止

  if [ "$DO_FORMAT" -eq 1 ]; then
    confirm "カードをリーダーに置き、フォーマット＋書き込みを実行しますか？" || die "中止しました。"
  else
    confirm "カードをリーダーに置き、'$TARGET_URL' を書き込みますか？" || die "中止しました。"
  fi

  case "$TAG_TYPE" in
    classic)
      ensure_ndef_tools
      backup_card
      [ "$DO_FORMAT" -eq 1 ] && format_card
      write_url
      verify_url
      ;;
    type2)
      backup_card         # 非 classic のためスキップ通知が出る
      write_url_type2
      ;;
    type4)
      backup_card
      write_url_type4
      ;;
    *)
      die "内部エラー: 未処理のカード種別 (${TAG_TYPE})。"
      ;;
  esac

  echo
  ok "完了しました。"
  sound_ok
  [ "$TAG_TYPE" = "classic" ] && print_iphone_note
  return 0
}

main
