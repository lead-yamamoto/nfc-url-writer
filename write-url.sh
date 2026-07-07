#!/usr/bin/env bash
#
# write-url.sh — libnfc/libfreefare で NFC タグに NDEF URL を書き込む macOS 用 CLI。
#
# 対応リーダー: libnfc 対応の NXP系リーダー(ACR122U が代表例)。
#               Sony PaSoRi/RC-S300 等の FeliCa系/PC-SC リーダーは使用できません。
# 対応タグ:     MIFARE Classic 1K/4K(正式) / NTAG・Type2(実験的) /
#               DESFire・Type4(実験的) / FeliCa(非対応)。
#               カード種別(SAK)を自動判定して処理を振り分けます。
#
# 使い方:
#   ./write-url.sh --format     # 初回: NDEF フォーマットしてから URL 書き込み
#   ./write-url.sh              # 2回目以降: URL の書き込みのみ
#   ./write-url.sh --detect     # リーダー/カードの状態を判定するだけ(書き込まない)
#   ./write-url.sh --fix-reader # macOS のスマートカードデーモンを無効化(リーダー認識用)
#   ./write-url.sh --help       # ヘルプ
#
# 安定性(重要): 複数の NFC リーダー(例: ACR122U + Sony PaSoRi)が同時に挿さって
#   いると、libnfc の既定デバイス選択が Sony 側になり nfc_open が失敗して操作全体が
#   こける(=「5〜6回押さないと成功しない」現象)。本スクリプトは接続中の対応
#   リーダー(NXP系)を検出し、LIBNFC_DEFAULT_DEVICE でそのドライバを既定に固定して
#   この問題を解消する。詳細は select_reader() を参照。
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
# ACR122U ブザー制御ヘルパ(任意・libusb 必要)の場所を解決する。
#   ・通常のリポジトリ実行時: ./bin/acr122-beep
#   ・.app にバンドルされた時: Contents/Resources/acr122-beep(スクリプトと同じ階層)
# build-app.sh が prebuilt バイナリを Resources 直下へコピーするため、
# bin/ が無いバンドル環境でもスクリプトの隣を探して見つけられるようにする。
if [ -x "$LOCAL_BIN/acr122-beep" ]; then
  BEEP_BIN="$LOCAL_BIN/acr122-beep"
else
  BEEP_BIN="$SCRIPT_DIR/acr122-beep"      # バンドル時(Resources 直下)
fi

# リトライ設定(他の Mac でリーダー掴み合いにより数回失敗する問題への対策)
RETRY_MAX="${NFC_RETRY_MAX:-4}"           # 最大試行回数
RETRY_SLEEP="${NFC_RETRY_SLEEP:-0.8}"     # 試行間の待機秒数

# 効果音(どのリーダーでも鳴る Mac 本体スピーカー)。NFC_SOUND=0 か --no-sound で無効化
NFC_SOUND="${NFC_SOUND:-1}"
SOUND_OK="/System/Library/Sounds/Glass.aiff"
SOUND_NG="/System/Library/Sounds/Basso.aiff"

# 詳細ログ(libnfc/libfreefare の生出力・16進ダンプ・UID/SAK 等)を表示するか。
# 既定 0 = 表示しない(CLI もクリーン)。--verbose か NFC_VERBOSE=1 で表示。
# アプリはこの詳細を「詳細ログ」トグル用に常にキャプチャするため NFC_VERBOSE=1 で起動する。
NFC_VERBOSE="${NFC_VERBOSE:-0}"

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

# detail: 開発者向けの生ツール出力(nfc-list/mifare-*/nfc-mfclassic の出力、16進ダンプ、
#   UID/SAK/ATQA 等)を「4スペース字下げ」で出す。NFC_VERBOSE=1 のときのみ表示し、
#   既定(0)では完全に抑制する。字下げによりアプリ側で「詳細行」と機械的に判別できる。
#   使い方1(引数): detail "文字列"
#   使い方2(パイプ): some-tool 2>&1 | detail
detail() {
  [ "$NFC_VERBOSE" = "1" ] || { [ "$#" -gt 0 ] || cat >/dev/null; return 0; }
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$*" | sed 's/^/    /'
  else
    sed 's/^/    /'
  fi
}

# --- 効果音ヘルパ ------------------------------------------------------------
# afplay をバックグラウンド実行。afplay が無い/NFC_SOUND=0 の時は何もしない。
play_sound() {
  [ "$NFC_SOUND" = "1" ] || return 0
  require_cmd afplay || return 0
  [ -f "$1" ] || return 0
  afplay "$1" >/dev/null 2>&1 &
}
# 成功音: Mac 本体スピーカー(保証フォールバック)に加え、選択リーダーが ACR122U の
# ときはリーダー本体のブザーも鳴らす(ベストエフォート)。reader_beep は
# LIBNFC_DEFAULT_DEVICE 設定後にのみ意味を持つが、未設定でも安全にスキップされる。
sound_ok() { play_sound "$SOUND_OK"; reader_beep beep 2>/dev/null || true; }
sound_ng() { play_sound "$SOUND_NG"; }

# die: 失敗音を鳴らしてから終了。--print-ndef/--fix-reader では鳴らさないよう
#      それらのフローは die を通らない(独立分岐)ため自然に除外される。
die()  { err "$*"; sound_ng; exit 1; }

usage() {
  cat <<EOF
${BOLD}write-url.sh${RST} — NFC タグに NDEF URL を書き込む (libnfc対応リーダー / macOS)

書き込む URL はこのスクリプト冒頭の TARGET_URL を編集して変更します。
  現在の TARGET_URL: ${BOLD}${TARGET_URL}${RST}

使い方:
  ./write-url.sh --format      初回。カードを NDEF フォーマットしてから URL を書く
  ./write-url.sh               2回目以降。URL の書き込みのみ
  ./write-url.sh --detect      リーダー/カードの状態を判定するだけ(書き込まない)
  ./write-url.sh --fix-reader  macOS がリーダーを掴んでいる場合に解放する(sudo)
  ./write-url.sh --print-ndef  TARGET_URL から生成される NDEF バイト列を表示して終了
  ./write-url.sh --read        カードに書かれている NDEF URL を読み取って表示
  ./write-url.sh --no-backup   書き込み前のバックアップを行わない
  ./write-url.sh --no-sound    成功/失敗の効果音を鳴らさない(NFC_SOUND=0 でも可)
  ./write-url.sh --verbose     開発者向け: 生ツール出力(16進/UID/SAK 等)も表示(NFC_VERBOSE=1 でも可)
  ./write-url.sh --yes         確認プロンプトを省略する
  ./write-url.sh --help        このヘルプ

対応リーダー:
  libnfc が対応する ${BOLD}NXP系${RST}リーダーが必要です(代表例: ${BOLD}ACR122U${RST})。
  ${YEL}Sony PaSoRi/RC-S300 等の FeliCa系/PC-SC リーダーは使用できません${RST}
  (libnfc の nfc_open が失敗するため)。複数リーダーが挿さっている場合は、
  接続中の対応リーダーを自動検出して既定デバイスに固定します(select_reader)。

対応タグ(SAK から自動判定):
    ・MIFARE Classic 1K/4K … ${GRN}正式対応${RST}(主対象)
    ・NTAG213/215/216・Type2 … ${YEL}実験的対応${RST}(確認が必要)
    ・MIFARE DESFire・Type4 … ${YEL}実験的対応${RST}
    ・FeliCa … ${RED}非対応${RST}

安定性: リーダー検出・各操作は自動で最大 ${RETRY_MAX} 回まで再試行します。
        失敗が続く場合は ./write-url.sh --fix-reader でリーダーを解放し抜き差ししてください。

処理の流れ: リーダー選択(NXP系を固定) → 認識確認 → (Classicのみ)バックアップ
           → (--format 時のみ)フォーマット → URL 書き込み → read-ndef で検証
EOF
}

# --- 引数パース --------------------------------------------------------------
DO_FORMAT=0; ASSUME_YES=0; DO_BACKUP=1; FIX_READER=0; PRINT_NDEF=0; DO_READ=0; SELF_TEST=0; DO_DETECT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)     DO_FORMAT=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --no-backup)  DO_BACKUP=0 ;;
    --no-sound)   NFC_SOUND=0 ;;
    --fix-reader) FIX_READER=1 ;;
    --print-ndef) PRINT_NDEF=1 ;;
    --read)       DO_READ=1 ;;
    --detect)     DO_DETECT=1 ;;   # リーダー/カードの状態判定のみ(書き込まない)
    --verbose|-v) NFC_VERBOSE=1 ;; # 開発者向け: 生ツール出力(16進/UID/SAK 等)も表示
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

# ═════════════════════════════════════════════════════════════════════════════
#  リーダー選択(安定性の要)
# ═════════════════════════════════════════════════════════════════════════════
# 問題: libfreefare/libnfc のツールは既定デバイス(nfc_open(NULL) もしくは
#   nfc_list_devices の先頭)を開く。ACR122U と Sony PaSoRi が同時に挿さっていると、
#   libnfc が Sony(pcsc:SONY FeliCa Port/PaSoRi)を既定に選び nfc_open が失敗、
#   操作全体がこける。ACR122U がたまたま選ばれた時だけ成功する=不安定。
#
# 解決: nfc-scan-device で接続デバイスの connstring を列挙し、対応する NXP系
#   リーダー(acr122_usb / acr122_pcsc[ACR122] / pn532_*)を優先順に選ぶ。
#   Sony/FeliCa/PaSoRi は除外する。選んだデバイスの「ドライバ接頭辞」
#   (例: acr122_usb)を LIBNFC_DEFAULT_DEVICE に設定して既定デバイスに固定する。
#
# なぜ「ドライバ接頭辞」なのか:
#   ・LIBNFC_DEFAULT_DEVICE=acr122_usb は nfc_open(NULL) 系ツール
#     (nfc-list / nfc-mfultralight / nfc-mfclassic)で ACR122U を直接開かせる。
#   ・同時に nfc_list_devices の先頭へ acr122_usb を差し込むため、libfreefare の
#     mifare-classic-* もそれを最初に開いて ACR122U を claim する。
#   ・bus:dev 番号(acr122_usb:001:002 等)は ACR122U が open/close の度に
#     再列挙されて変動するため、正確なアドレスの固定は不安定。ドライバ接頭辞なら
#     その場で再列挙して現在のデバイスを掴むので確実。
#
# 検証結果(ACR122U + Sony PaSoRi 同時接続、本機): nfc-list 10/10・
#   mifare-classic-read-ndef claim 12/12・nfc-mfultralight 10/10 で ACR122U を選択、
#   Sony を掴んだ回数 0/10。

READER_CONNSTRING=""   # 選択したフル connstring(例: acr122_usb:001:002)
READER_DRIVER=""       # ドライバ接頭辞(例: acr122_usb) = LIBNFC_DEFAULT_DEVICE の値
READER_NAME=""         # 人間可読名(例: ACS / ACR122U PICC Interface)
READER_FOUND_LIST=""   # 見つかった全デバイス名(エラーメッセージ用)

# nfc-scan-device -v の出力から、対応 NXP系リーダーの connstring を優先順で選ぶ。
# 成功時: READER_CONNSTRING/READER_DRIVER/READER_NAME を設定して 0。
# 失敗時(対応リーダー無し): READER_FOUND_LIST に検出名を残して 1。
discover_reader() {
  READER_CONNSTRING=""; READER_DRIVER=""; READER_NAME=""; READER_FOUND_LIST=""
  local scan=""
  # nfc-scan-device は対応/非対応を問わず接続デバイスを列挙する(nfc_open 失敗も表示)。
  scan="$(nfc-scan-device -v 2>&1)" || true

  # 検出された全 connstring を集める(選択判定用。空白を含まない接頭辞付きトークン)。
  # nfc-scan-device は connstring を字下げ行で出す/または "nfc_open failed for X" で出す。
  local conns
  conns="$(printf '%s\n' "$scan" \
    | grep -oiE '(acr122_usb|acr122_pcsc|pn532_uart|pn532_usb|pn532_spi|pn532_i2c|pcsc):[^"[:space:]]*' \
    | sed 's/[[:space:]]*$//')" || true

  # エラー表示用に「見つかったデバイスのフル名」も控える(空白を含む pcsc:SONY ... 等)。
  #   ・"nfc_open failed for <connstring>" 行の <connstring>(行末まで=空白込み)
  #   ・"- <name>:" のヘッダ行の <name>
  local names
  names="$(printf '%s\n' "$scan" \
    | sed -nE 's/^[[:space:]]*nfc_open failed for[[:space:]]*(.+)$/\1/p; s/^-[[:space:]]*(.+):[[:space:]]*$/\1/p')" || true
  READER_FOUND_LIST="$(printf '%s\n' "$names" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  # フル名が取れなければ connstring 一覧で代替。
  if [ -z "$READER_FOUND_LIST" ]; then
    READER_FOUND_LIST="$(printf '%s\n' "$conns" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  fi

  # 優先順に選ぶ。各グループ内で最初にマッチした connstring を採用。
  #   1) acr122_usb:*            (最も確実)
  #   2) acr122_pcsc:*ACR122*    (PC/SC 経由の ACR122 も可)
  #   3) pn532_*                 (PN532 系リーダー)
  # 除外: pcsc:*SONY* / *FeliCa* / *PaSoRi*(非対応)
  local c prefix
  # グループ1: acr122_usb
  c="$(printf '%s\n' "$conns" | grep -iE '^acr122_usb:' | head -1)" || true
  if [ -z "$c" ]; then
    # グループ2: acr122_pcsc(ただし ACR122 を名に含むもの)
    c="$(printf '%s\n' "$conns" | grep -iE '^acr122_pcsc:.*ACR122' | head -1)" || true
  fi
  if [ -z "$c" ]; then
    # グループ3: pn532_*
    c="$(printf '%s\n' "$conns" | grep -iE '^pn532_' | head -1)" || true
  fi

  if [ -z "$c" ]; then
    return 1
  fi

  READER_CONNSTRING="$c"
  # ドライバ接頭辞 = 最初の ':' より前(例: acr122_usb:001:002 → acr122_usb)
  prefix="${c%%:*}"
  READER_DRIVER="$prefix"
  return 0
}

# 選択した connstring を実際に開いて、libnfc が名乗る人間可読名を取得する。
# LIBNFC_DEFAULT_DEVICE を固定した状態で nfc-list を実行し "NFC device: ..." を拾う。
# 併せて、実際に対応リーダーが開けることを確認する(開けなければ 1)。
probe_reader_name() {
  local out name
  out="$(LIBNFC_DEFAULT_DEVICE="$READER_DRIVER" nfc-list 2>&1)" || true
  # "NFC device: <name> opened" のうち、汎用の "user defined default device" 以外を優先。
  name="$(printf '%s\n' "$out" \
    | grep -iE 'NFC device:.*opened' \
    | grep -viE 'user defined default device' \
    | sed -E 's/.*NFC device:[[:space:]]*(.*) opened.*/\1/' \
    | head -1)" || true
  if [ -z "$name" ]; then
    # フォールバック: 何か開けていれば connstring を名前代わりに使う。
    if printf '%s\n' "$out" | grep -qiE 'NFC device:.*opened'; then
      name="$READER_CONNSTRING"
    fi
  fi
  READER_NAME="$name"
  [ -n "$name" ] && return 0 || return 1
}

# select_reader: 対応リーダーを検出し LIBNFC_DEFAULT_DEVICE を固定する。
#   成功: 環境変数 LIBNFC_DEFAULT_DEVICE をエクスポートし、READER_NAME を設定、0 を返す。
#   失敗: 明確な日本語メッセージを出して 1 を返す(呼び出し側で die する)。
# 注: bus:dev は変動しうるため毎回この関数で再検出する。
select_reader() {
  if ! require_cmd nfc-scan-device; then
    # nfc-scan-device が無い環境では従来どおり既定デバイスに委ねる(固定はしない)。
    warn "nfc-scan-device が見つからないため、リーダーの自動固定をスキップします。"
    return 0
  fi
  if ! discover_reader; then
    err "利用可能な対応リーダーが見つかりません。接続中: ${READER_FOUND_LIST:-なし}。ACR122U 等の libnfc 対応(NXP系)リーダーが必要です。Sony PaSoRi/RC-S300(FeliCa)はこのツールでは使用できません。"
    return 1
  fi
  # 既定デバイスをドライバ接頭辞で固定(nfc_open(NULL)/nfc_list_devices 双方に効く)。
  export LIBNFC_DEFAULT_DEVICE="$READER_DRIVER"
  # 人間可読名を取得(取得できなくても致命的ではない)。
  probe_reader_name || true
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  ACR122U ブザー(ピッ音)ヘルパ — ベストエフォート(失敗しても操作は止めない)
# ═════════════════════════════════════════════════════════════════════════════
# reader_beep MODE : MODE = enable | beep
#   ・選択リーダーが ACR122U(acr122_usb ドライバ)のときのみ実行する。
#   ・./bin/acr122-beep を使う。無ければ libusb がある場合に build-tools.sh でビルドを試みる。
#   ・libnfc がデバイスを掴んでいる間は claim に失敗するため、必ず nfc 系サブプロセスの
#     合間/完了後に呼ぶこと。どんな失敗も無視する(効果音の afplay が保証フォールバック)。
reader_beep() {
  local mode="$1"
  # ACR122U(acr122_usb)を選択している時だけ。それ以外(pn532 等)は無音でスキップ。
  case "$READER_DRIVER" in
    acr122_usb) : ;;
    *) return 0 ;;
  esac
  # ヘルパが無ければ、libusb がある場合のみビルドを試みる(失敗は無視)。
  if [ ! -x "$BEEP_BIN" ]; then
    if require_cmd brew && [ -f "$(brew --prefix libusb 2>/dev/null)/include/libusb-1.0/libusb.h" ] 2>/dev/null; then
      "$SCRIPT_DIR/build-tools.sh" >/dev/null 2>&1 || true
    fi
  fi
  [ -x "$BEEP_BIN" ] || return 0
  "$BEEP_BIN" "$mode" >/dev/null 2>&1 || true
  return 0
}

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
    info "必要なツールを準備しています…"
    detail "libfreefare の mifare-classic-* が PATH 上に無いため、ソースからビルドします…"
    "$SCRIPT_DIR/build-tools.sh" || die "必要なツールの準備に失敗しました(README参照)。"
    hash -r
    for t in "${NDEF_TOOLS[@]}"; do
      require_cmd "$t" || die "準備後も必要なツールが見つかりません($t)。"
    done
    detail "ローカルビルド済みツールを使用します: $LOCAL_BIN"
  fi
}

# --- 各ステップ --------------------------------------------------------------
# check_reader: nfc-list をリトライ付きで実行し、認識確認とカード種別判定を行う。
#   NFC_LIST_OUT にツール出力を保存し、TAG_TYPE/TAG_SAK/TAG_DEVICE を設定する。
check_reader() {
  # まず対応リーダー(NXP系)を検出し、既定デバイスを固定する(安定性の要)。
  info "リーダーを確認しています…"
  select_reader || die "対応リーダーの選択に失敗しました。"
  if [ -n "$READER_NAME" ]; then
    ok "リーダーを確認しました（${READER_NAME}）"
    # アプリが拾えるよう、機械可読な1行を出力する(字下げして詳細扱い=かんたんログには出さない)。
    detail "使用リーダー: $READER_NAME"
    # 選択直後に ACR122U のブザー(カード検出時ピッ)を再有効化(失われた設定の復元)。
    reader_beep enable
  fi

  local out rc=0
  # nfc-list 自体をリトライ(他 Mac での掴み合いによる初回失敗対策)
  retry_capture out "カードの確認" nfc-list || rc=$?
  NFC_LIST_OUT="$out"
  printf '%s\n' "$out" | detail
  if [ "$rc" -ne 0 ]; then
    maybe_reader_busy_hint "$out"
    reader_help
    die "リーダーの読み取りに失敗しました。ケーブルの抜き差しや「リーダー解放」をお試しください。"
  fi

  if printf '%s' "$out" | grep -qi 'ACR122'; then
    : # リーダー名は既に上で通知済み。ここでは冗長な確認行を出さない。
  elif printf '%s' "$out" | grep -qiE 'NFC device.*opened'; then
    warn "リーダーは動作していますが、対応リーダーか確認できませんでした。続行します。"
  else
    maybe_reader_busy_hint "$out"
    reader_help
    die "リーダーが見つかりませんでした。接続を確認してください。"
  fi

  # カード種別を判定(TAG_TYPE / TAG_SAK / TAG_DEVICE をセット)
  parse_tag_type "$out"
  # 機械可読行(アプリの mergeDetect 用)は字下げして詳細扱いにし、かんたんログには出さない。
  if [ -n "$TAG_SAK" ]; then
    detail "カード種別を判定しました: ${TAG_TYPE} (SAK=${TAG_SAK})"
  else
    detail "カード種別を判定しました: ${TAG_TYPE}"
  fi
  # ユーザ向けには種別を平易な言葉で伝える(SAK/種別トークンは出さない)。
  ok "カードを確認しました（$(friendly_tag_label "$TAG_TYPE")）"
}

# カード種別トークンを、ユーザ向けの平易な日本語ラベルに変換する。
friendly_tag_label() {
  case "$1" in
    classic) printf 'MIFARE Classic' ;;
    type2)   printf 'NTAG・iPhone対応' ;;
    type4)   printf 'DESFire' ;;
    felica)  printf 'FeliCa' ;;
    *)       printf '種別不明' ;;
  esac
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

# mfclassic のバックアップ本体(リトライ対象。生出力は detail で詳細ログのみに回す)。
_run_backup() { nfc-mfclassic R a "$1" 2>&1 | detail; }

backup_card() {
  # バックアップは MIFARE Classic 専用。他種別ではスキップを通知。
  if [ "${TAG_TYPE:-classic}" != "classic" ]; then
    detail "バックアップは MIFARE Classic 専用のためスキップします(現在: ${TAG_TYPE:-不明})。"
    return 0
  fi
  if [ "$DO_BACKUP" -ne 1 ]; then
    warn "バックアップは行いません。"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  local ts file rc=0
  ts="$(date +%Y%m%d-%H%M%S)"
  file="$BACKUP_DIR/backup-$ts.mfd"
  info "念のためカードの内容をバックアップしています…"
  detail "バックアップ先: $file"
  # R = 読み取り(鍵が分からないセクターはスキップして継続) / a = Key A
  retry "バックアップ" _run_backup "$file" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ -s "$file" ]; then ok "バックアップを保存しました"
    else warn "バックアップは空でした。"; fi
  else
    warn "バックアップを完全には取得できませんでした（このまま続行できます）。"
    [ -s "$file" ] && detail "部分的なバックアップは保存されています: $file"
    confirm "バックアップ無しで続行しますか？" || die "中止しました。"
  fi
}

_run_format() { mifare-classic-format -y 2>&1 | detail; }

format_card() {
  info "カードを初期化しています…"
  local rc=0
  retry "初期化" _run_format || rc=$?
  [ "$rc" -eq 0 ] || die "初期化に失敗しました。カードを置き直してもう一度お試しください。"
  ok "初期化が完了しました"
}

_run_write_classic() { mifare-classic-write-ndef -y -i "$1" 2>&1 | detail; }

write_url() {
  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "書き込み中です…（${TARGET_URL}）"
  detail "NDEF メッセージ ($(wc -c < "$TMP_WORK/ndef.bin" | tr -d ' ') バイト): $(xxd -p "$TMP_WORK/ndef.bin" | tr -d '\n')"
  local rc=0
  retry "書き込み" _run_write_classic "$TMP_WORK/ndef.bin" || rc=$?
  [ "$rc" -eq 0 ] || die "書き込みに失敗しました。カードを置き直してもう一度お試しください。"
  ok "書き込みが完了しました"
}

# read-ndef をリトライ付きで実行。成功時 readback.bin を生成。
# 出力は READ_NDEF_OUT に保持(空カード判定などに使う)。戻り値は最終試行の終了コード。
_read_ndef_classic() {
  READ_NDEF_OUT="$(mifare-classic-read-ndef -y -o "$1" 2>&1)"
  local rc=$?
  printf '%s\n' "$READ_NDEF_OUT" | detail
  return "$rc"
}

verify_url() {
  info "書き込んだ内容を確認しています…"
  local rc=0
  retry "確認" _read_ndef_classic "$TMP_WORK/readback.bin" || rc=$?
  [ "$rc" -eq 0 ] || die "書き込み後の確認に失敗しました。"
  detail "読み戻し ($(wc -c < "$TMP_WORK/readback.bin" | tr -d ' ') バイト): $(xxd -p "$TMP_WORK/readback.bin" | tr -d '\n')"
  if cmp -s "$TMP_WORK/ndef.bin" "$TMP_WORK/readback.bin"; then
    ok "読み取って確認しました：${TARGET_URL}"
  elif grep -aq "$URI_REST" "$TMP_WORK/readback.bin"; then
    ok "読み取って確認しました：${TARGET_URL}"
  else
    die "書き込んだ内容が確認できませんでした。もう一度お試しください。"
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

_ul_read() { nfc-mfultralight r "$1" 2>&1 | detail; }
# 書き戻し: OTP/Lock/DynLock/UID の各プロンプトへ 'n' を送り、危険ページを書かない。
_ul_write() { printf 'n\nn\nn\nn\n' | nfc-mfultralight w "$1" 2>&1 | detail; }

write_url_type2() {
  warn "このカード（NTAG）への書き込みは実験的機能です。"
  detail "ロック/OTP ページには一切書き込みません(タグ保護のため)。"
  confirm "このカードに書き込みますか？" || die "中止しました。"

  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "書き込み中です…（${TARGET_URL}）"

  # 1) 現在のカードを読み出して、正しい容量/UID/CC/ロックを保持したイメージを得る
  detail "カードを読み出して安全な書き込みイメージを作成します(nfc-mfultralight r)…"
  local rc=0
  retry "カードの読み出し" _ul_read "$TMP_WORK/ul_dump.mfd" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$TMP_WORK/ul_dump.mfd" ]; then
    die "カードを読み出せませんでした。空・ロック・パスワード保護の可能性があります。安全のため書き込みは行いません。"
  fi

  # 2) TLV を組み立て、データページ(page4以降)にのみ差し込む
  local tlv_hex
  tlv_hex="$(build_type2_tlv_hex "$TMP_WORK/ndef.bin")" || die "URL が長すぎてこのカードに収まりません。"
  if ! patch_type2_dump "$TMP_WORK/ul_dump.mfd" "$tlv_hex" "$TMP_WORK/ul_write.mfd"; then
    die "このカードには容量が足りません。より大きな NTAG をご利用ください。"
  fi

  # 3) 書き戻し(危険ページはプロンプトに 'n' を返して回避)
  detail "イメージを書き戻します(nfc-mfultralight w、ロック/OTP は書きません)…"
  rc=0
  retry "書き込み" _ul_write "$TMP_WORK/ul_write.mfd" || rc=$?
  [ "$rc" -eq 0 ] || die "書き込みに失敗しました。カードを置き直してもう一度お試しください。"
  ok "書き込みが完了しました"

  # 4) 検証: 読み戻して NDEF/URL が載っているか確認
  info "書き込んだ内容を確認しています…"
  rc=0
  retry "確認" _ul_read "$TMP_WORK/ul_verify.mfd" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$TMP_WORK/ul_verify.mfd" ]; then
    if grep -aq "$URI_REST" "$TMP_WORK/ul_verify.mfd"; then
      ok "読み取って確認しました：${TARGET_URL}"
    else
      warn "書き込みは完了しましたが、確認できませんでした。iPhone 等での実機確認をおすすめします。"
    fi
  else
    warn "書き込み後の確認に失敗しました。書き込み自体は完了しています。"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  実験的: Type4 (MIFARE DESFire)
# ═════════════════════════════════════════════════════════════════════════════
_df_create() { mifare-desfire-create-ndef -y 2>&1 | detail; }
_df_write()  { mifare-desfire-write-ndef -y -i "$1" 2>&1 | detail; }
_df_read()   { mifare-desfire-read-ndef -y -o "$1" 2>&1 | detail; }

write_url_type4() {
  warn "このカード（DESFire）への書き込みは実験的機能です。"
  confirm "このカードに書き込みますか？" || die "中止しました。"

  build_ndef_message "$TARGET_URL" "$TMP_WORK/ndef.bin"
  info "書き込み中です…（${TARGET_URL}）"

  local rc=0
  # --format 指定時のみ NDEF アプリケーションを作成(既存 NDEF タグを壊さない)
  if [ "$DO_FORMAT" -eq 1 ]; then
    detail "DESFire を NFC Forum Type4 として初期化します(create-ndef)…"
    rc=0
    retry "初期化" _df_create || rc=$?
    [ "$rc" -eq 0 ] || die "カードの初期化に失敗しました。"
  fi

  detail "NDEF を書き込みます(write-ndef)…"
  rc=0
  retry "書き込み" _df_write "$TMP_WORK/ndef.bin" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # 未初期化の DESFire だと write が失敗する。--format を案内。
    die "書き込みに失敗しました。「フォーマット（初期化）」を実行してから、もう一度お試しください。"
  fi
  ok "書き込みが完了しました"

  info "書き込んだ内容を確認しています…"
  rc=0
  retry "確認" _df_read "$TMP_WORK/readback.bin" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$TMP_WORK/readback.bin" ]; then
    if cmp -s "$TMP_WORK/ndef.bin" "$TMP_WORK/readback.bin" || grep -aq "$URI_REST" "$TMP_WORK/readback.bin"; then
      ok "読み取って確認しました：${TARGET_URL}"
    else
      warn "書き込みは完了しましたが、確認できませんでした。"
    fi
  else
    warn "書き込み後の確認に失敗しました。書き込み自体は完了しています。"
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
  detail "NDEF ($(wc -c < "$1" | tr -d ' ') バイト): $(xxd -p "$1" | tr -d '\n')"
  local decoded; decoded="$(decode_ndef "$1")"
  if [ -n "$decoded" ]; then ok "読み取って確認しました：${decoded}"; sound_ok
  else warn "URL として読み取れませんでした。空のカードか、別の形式で書かれている可能性があります。"; fi
}

read_card() {
  info "カードの内容を読み取っています…"
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
      retry "読み取り" _read_ndef_classic "$TMP_WORK/readback.bin" || rc=$?
      if [ "$rc" -ne 0 ]; then
        # 空カード(未フォーマット)を優しいメッセージに置き換える
        if printf '%s' "${READ_NDEF_OUT:-}" | grep -qi 'No MAD detected'; then
          err "このカードはまだ空です。「書き込む」でURLを書き込めます。"
          sound_ng; exit 1
        fi
        maybe_reader_busy_hint "${READ_NDEF_OUT:-}"
        die "読み取りに失敗しました。カードを置き直してもう一度お試しください。"
      fi
      _report_read_result "$TMP_WORK/readback.bin"
      ;;
    type4)
      detail "【実験的機能】Type4(DESFire)から読み取ります。"
      local rc=0
      retry "読み取り" _df_read "$TMP_WORK/readback.bin" || rc=$?
      if [ "$rc" -ne 0 ] || [ ! -s "$TMP_WORK/readback.bin" ]; then
        err "このカードはまだ空です。「書き込む」（初回は「フォーマット（初期化）」）でURLを書き込めます。"
        sound_ng; exit 1
      fi
      _report_read_result "$TMP_WORK/readback.bin"
      ;;
    type2)
      detail "【実験的機能】Type2(NTAG/Ultralight)から読み取ります。"
      local rc=0
      retry "読み取り" _ul_read "$TMP_WORK/ul_dump.mfd" || rc=$?
      if [ "$rc" -ne 0 ] || [ ! -s "$TMP_WORK/ul_dump.mfd" ]; then
        err "このカードはまだ空です。「書き込む」でURLを書き込めます。"
        sound_ng; exit 1
      fi
      # ダンプ(page4以降)から NDEF TLV を取り出して URL を復元
      if extract_type2_ndef "$TMP_WORK/ul_dump.mfd" "$TMP_WORK/readback.bin" && [ -s "$TMP_WORK/readback.bin" ]; then
        _report_read_result "$TMP_WORK/readback.bin"
      else
        warn "このカードから URL を読み取れませんでした。まだ空の可能性があります。"
        xxd "$TMP_WORK/ul_dump.mfd" 2>/dev/null | head -8 | detail
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

# ═════════════════════════════════════════════════════════════════════════════
#  --detect: リーダー/カードの状態判定のみ(高速・読み取り専用・書き込まない)
# ═════════════════════════════════════════════════════════════════════════════
# アプリのステータスパネル用。機械可読な行を出力する:
#   READER: <name or NONE>
#   TAG: <classic|type2|type4|felica|none|unknown> [<SAK>]
# に続けて日本語の要約を出す。カードが無くてもハングしない(単発・短時間)。
# フル読み取り(NDEF)は行わず、nfc-list の SAK 判定のみで種別を出す。
detect_status() {
  require_cmd xxd >/dev/null 2>&1 || true
  if ! require_cmd nfc-list; then
    echo "READER: NONE"
    echo "TAG: none"
    err "libnfc(nfc-list)が見つかりません。'brew install libnfc libfreefare' を実行してください。"
    return 1
  fi

  # 対応リーダーを検出(見つからなければ NONE を出して終了)。
  if ! require_cmd nfc-scan-device || ! discover_reader; then
    echo "READER: NONE"
    echo "TAG: none"
    local found="${READER_FOUND_LIST:-なし}"
    warn "対応リーダーが見つかりません。接続中: ${found}。ACR122U 等の libnfc 対応(NXP系)リーダーが必要です(Sony PaSoRi/RC-S300 は非対応)。"
    return 1
  fi
  export LIBNFC_DEFAULT_DEVICE="$READER_DRIVER"

  # カード判定は nfc-list 単発(リトライ無し=--detect は速度優先)。
  # この nfc-list の出力からリーダー名も同時に拾う(probe 用の追加呼び出しを省く)。
  local out=""
  out="$(nfc-list 2>&1)" || true
  parse_tag_type "$out"

  # リーダー名: nfc-list の "NFC device: <name> opened" のうち汎用名以外を優先。
  local rname
  rname="$(printf '%s\n' "$out" \
    | grep -iE 'NFC device:.*opened' \
    | grep -viE 'user defined default device' \
    | sed -E 's/.*NFC device:[[:space:]]*(.*) opened.*/\1/' \
    | head -1)" || true
  # 取得できなければ connstring、それも無ければ UNKNOWN。
  [ -n "$rname" ] || rname="${READER_CONNSTRING:-UNKNOWN}"
  READER_NAME="$rname"
  echo "READER: $rname"

  # カードの有無を判定。ISO14443A/FeliCa ターゲットが無ければ none。
  local has_target=0
  if printf '%s\n' "$out" | grep -qiE 'passive target\(s\) found|ISO14443A|ISO/IEC 14443|FeliCa'; then
    if printf '%s\n' "$out" | grep -qiE '0 (ISO14443A|FeliCa).*passive target'; then
      has_target=0
    else
      has_target=1
    fi
  fi

  if [ "$has_target" -eq 0 ]; then
    echo "TAG: none"
    ok "使用リーダー: ${rname}"
    info "カードは検出されていません。カードをリーダーに置いてください。"
    return 0
  fi

  # 種別と SAK を出力(SAK が無い felica 等は SAK 省略)。
  if [ -n "$TAG_SAK" ]; then
    echo "TAG: $TAG_TYPE $TAG_SAK"
  else
    echo "TAG: $TAG_TYPE"
  fi

  ok "使用リーダー: ${rname}"
  case "$TAG_TYPE" in
    classic) info "カードを検出: MIFARE Classic(正式対応) SAK=${TAG_SAK}" ;;
    type2)   info "カードを検出: NTAG/Type2(実験的対応) SAK=${TAG_SAK}" ;;
    type4)   info "カードを検出: DESFire/Type4(実験的対応) SAK=${TAG_SAK}" ;;
    felica)  warn "カードを検出: FeliCa(非対応)。NTAG213/215/216 か MIFARE Classic をご利用ください。" ;;
    *)       warn "カードを検出しましたが種別を判別できません(SAK=${TAG_SAK:-不明})。" ;;
  esac
  return 0
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

# --detect: リーダー/カードの状態判定のみ(書き込まない・高速)
if [ "$DO_DETECT" -eq 1 ]; then
  detect_status
  exit $?
fi

# --read: カード内容を読み取って終了
if [ "$DO_READ" -eq 1 ]; then
  read_card
  exit 0
fi

main() {
  info "書き込む URL：${TARGET_URL}"
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
