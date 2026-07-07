#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# nfc-core.py — PC/SC (PCSC.framework) 経由の NFC 書き込みエンジン。
#
#   ⚠ このファイルは「ダーク出荷(dark ship)」です。既定では使用されません。
#     shipping tool の既定パスは従来どおり libnfc/libfreefare (write-url.sh) です。
#     本エンジンは環境変数 NFC_BACKEND=pcsc を明示した場合のみ将来利用されます。
#     どのユーザにも影響しません(opt-in)。
#
# 依存: Python3 標準ライブラリのみ(ctypes)。サードパーティ依存なし。macOS 専用。
#       /System/Library/Frameworks/PCSC.framework/PCSC を ctypes で直接叩きます。
#
# 使い方:
#   python3 nfc-core.py --detect        リーダー/カードの状態判定のみ(書き込まない)
#   python3 nfc-core.py --read          NDEF URL を読み取り
#   python3 nfc-core.py --write <url>   NDEF URL を書き込み(env TARGET_URL も可)
#   python3 nfc-core.py --format [<url>] 初期化してから書き込み(env TARGET_URL も可)
#   python3 nfc-core.py --print-ndef    生成される NDEF バイト列を表示して終了(env TARGET_URL)
#   python3 nfc-core.py --self-test     ハードウェア不要の単体テストを実行し 0/非0 で終了
#
# 出力コントラクト(Swift アプリ / かんたんログ が解釈する):
#   友好行は字下げ無しでマーカー始まり:
#     "==> " (ステップ) / " ✓ " (成功) / " ✗ " (失敗) / " ![注意] " (警告)
#   生/技術出力は 4スペース字下げ(詳細。--verbose 時のみ表示想定)。
#   機械可読行: "使用リーダー: <name>" / "カード種別を判定しました: <type> (SAK=..)"
#   --detect  : "READER: <name|NONE>" / "TAG: <classic|type2|type4|felica|none|unknown> [SAK]"
#   非対応な リーダー+タグ の組合せ: "INCOMPAT: <tagtype>|<日本語説明>"
#
from __future__ import annotations

import ctypes
import ctypes.util
import os
import sys

TARGET_URL_DEFAULT = "https://example.com/"

# ═════════════════════════════════════════════════════════════════════════════
#  出力ヘルパ(出力コントラクト準拠)
# ═════════════════════════════════════════════════════════════════════════════

def step(msg):  print("==> " + msg)
def ok(msg):    print(" ✓ " + msg)
def fail(msg):  print(" ✗ " + msg)
def warn(msg):  print(" ![注意] " + msg)
def detail(msg):
    # 生/技術出力は 4スペース字下げ(詳細扱い)。
    for line in str(msg).splitlines() or [""]:
        print("    " + line)


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 5: NDEF-URI + TLV バイトビルダ(write-url.sh から移植)
# ═════════════════════════════════════════════════════════════════════════════
#
# write-url.sh の ndef_parts() / build_ndef_message() / build_type2_tlv_hex() を
# そのまま Python に移植したもの。golden vector は --self-test で検証する。

# NFC Forum URI 識別コード(RFC / URI Record Type Definition の abbreviation 表)。
# write-url.sh の ndef_parts() と 1:1 対応。長い prefix を先に判定すること。
_URI_PREFIXES = [
    ("https://www.", 0x02),
    ("http://www.",  0x01),
    ("https://",     0x04),
    ("http://",      0x03),
    ("tel:",         0x05),
    ("mailto:",      0x06),
]


def ndef_uri_parts(url):
    """URL -> (uri_code:int, rest:str)。write-url.sh の ndef_parts と等価。"""
    for prefix, code in _URI_PREFIXES:
        if url.startswith(prefix):
            return code, url[len(prefix):]
    return 0x00, url


def build_ndef_message(url):
    """URL -> NDEF メッセージ(bytes)。short-record URI record のみ対応。

    バイト列: D1 01 <PL> 55 <CODE> <rest...>
      D1 = MB|ME|SR|TNF(well-known), 01 = Type長, PL = Payload長,
      55 = 'U'(URI record type), CODE = URI 識別コード。
    golden: https://example.com/ -> d1010d55046578616d706c652e636f6d2f (16B)
    """
    code, rest = ndef_uri_parts(url)
    rest_bytes = rest.encode("utf-8")
    payload_len = len(rest_bytes) + 1  # +1 は先頭の URI 識別コード
    if payload_len > 255:
        raise ValueError("URL が長すぎます(short-record NDEF の上限255バイト超過)。")
    return bytes([0xD1, 0x01, payload_len, 0x55, code]) + rest_bytes


def build_type2_tlv(ndef):
    """NDEF メッセージ(bytes) -> Type2 用 NDEF Message TLV(bytes)。

    03 <len> <ndef...> FE を組み、4バイト(1ページ)境界へ 0x00 パディング。
    write-url.sh build_type2_tlv_hex と等価(len は 1バイト形式, <=254)。
    """
    n = len(ndef)
    if n > 254:
        raise ValueError("NDEF が長すぎます(1バイト長TLVの範囲外)。")
    tlv = bytes([0x03, n]) + ndef + bytes([0xFE])
    pad = (4 - (len(tlv) % 4)) % 4
    return tlv + bytes(pad)


def extract_type2_ndef(data):
    """Type2 データ領域(page4 以降の bytes)から NDEF TLV の生 NDEF を取り出す。

    write-url.sh extract_type2_ndef の移植。見つからなければ None。
    """
    i = 0
    n = len(data)
    while i < n:
        t = data[i]
        if t == 0x03:  # NDEF メッセージ TLV
            if i + 1 >= n:
                return None
            length = data[i + 1]
            start = i + 2
            if start + length > n:
                return None
            return data[start:start + length]
        elif t == 0x00:  # NULL TLV(1バイト)
            i += 1
        elif t == 0xFE:  # Terminator
            return None
        else:  # その他 TLV: 1バイト長を読み飛ばす
            if i + 1 >= n:
                return None
            length = data[i + 1]
            i += 2 + length
    return None


# NDEF URI レコードのデコード(--read 表示用)。
def decode_ndef_uri(ndef):
    """NDEF URI record(bytes) -> URL 文字列。解釈できなければ None。"""
    if len(ndef) < 5:
        return None
    # D1 01 PL 55 CODE ...  (short record, well-known, type 'U')
    if ndef[0] & 0x07 != 0x01:      # TNF = well-known
        return None
    sr = bool(ndef[0] & 0x10)
    if not sr:
        return None
    type_len = ndef[1]
    pl = ndef[2]
    off = 3
    rtype = ndef[off:off + type_len]
    off += type_len
    if rtype != b"U":
        return None
    payload = ndef[off:off + pl]
    if not payload:
        return None
    code = payload[0]
    rest = payload[1:].decode("utf-8", "replace")
    prefix = {c: p for p, c in _URI_PREFIXES}.get(code, "")
    return prefix + rest


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 6: MIFARE Classic 1K NDEF ブロックイメージビルダ(純関数)
# ═════════════════════════════════════════════════════════════════════════════
#
# ハードウェア無しで単体テストできるよう、1K カード全体(64ブロック x 16バイト)の
# 「ブロックイメージ」を純関数として構築する。ARCH の 1K NDEF レイアウトに厳密準拠。
#
# レイアウト(ARCH より):
#   Sector 0 blk0 = UID/manufacturer (READ-ONLY, 触らない)
#   Sector 0 blk1-2 = MAD1: NDEF セクタ 1..15 の AID は各 03 E1。
#       blk1 byte0 = MAD 全体の CRC8, byte1 = Info(0x01)。
#   Sector 0 trailer(blk3) = KeyA A0A1A2A3A4A5 / Access 78 77 88 / GPB C1 / KeyB FF..
#   NDEF セクタ 1..15: NDEF Message TLV を 3データブロックに連続配置。
#       各 trailer = KeyA D3F7D3F7D3F7 / Access 7F 07 88 / GPB 40 / KeyB FF..

MAD_AID_NDEF = bytes([0x03, 0xE1])   # NDEF アプリの AID(AN10787)
MAD_INFO_BYTE = 0x01

KEY_FFFFFF = bytes([0xFF] * 6)
KEY_MAD_A = bytes([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5])
KEY_NDEF_A = bytes([0xD3, 0xF7, 0xD3, 0xF7, 0xD3, 0xF7])

MAD_ACCESS = bytes([0x78, 0x77, 0x88])
MAD_GPB = 0xC1
NDEF_ACCESS = bytes([0x7F, 0x07, 0x88])
NDEF_GPB = 0x40


def crc8_mad(data):
    """MAD 用 CRC-8 (poly 0x1D, init 0xC7, MSB-first)。MIFARE AN10787 準拠。"""
    crc = 0xC7
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x1D) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc & 0xFF


def build_mad1(uid_block=None):
    """Sector 0 の 3ブロック(blk0..blk2)を返す(48バイト)。

    blk0 = UID/manufacturer(uid_block 未指定なら 0 埋めのプレースホルダ)。
    blk1-2 = MAD1: byte0=CRC8, byte1=Info, 続いて sector1..15 の AID(各2バイト)。
    """
    if uid_block is None:
        uid_block = bytes(16)  # 実カードでは読み取り専用。イメージ上はプレースホルダ。
    if len(uid_block) != 16:
        raise ValueError("uid_block は 16 バイト")
    # MAD 本体(32バイト): byte0=CRC(後で埋める), byte1=Info, byte2.. = AID×15
    mad = bytearray(32)
    mad[1] = MAD_INFO_BYTE
    for s in range(1, 16):  # sector 1..15
        pos = 2 * s  # sector s の AID 位置(byte2-3 が sector1 …)
        mad[pos] = MAD_AID_NDEF[0]
        mad[pos + 1] = MAD_AID_NDEF[1]
    # CRC8 は byte1..byte31(Info + 全 AID)に対して計算。
    mad[0] = crc8_mad(bytes(mad[1:]))
    return bytes(uid_block) + bytes(mad)  # 16 + 32 = 48 バイト(blk0-2)


def build_trailer(key_a, access, gpb, key_b=KEY_FFFFFF):
    """セクタ trailer(16バイト) = KeyA(6) + Access(3) + GPB(1) + KeyB(6)。"""
    if len(key_a) != 6 or len(access) != 3 or len(key_b) != 6:
        raise ValueError("trailer フィールド長不正")
    return bytes(key_a) + bytes(access) + bytes([gpb]) + bytes(key_b)


def build_classic_1k_image(ndef, uid_block=None):
    """NDEF メッセージ(bytes)から MIFARE Classic 1K 全体の 64×16 ブロックイメージを返す。

    返り値: list[bytes]、長さ 64、各 16 バイト。ハードウェア無しで検証可能。
      - block 0        : UID(触らない / プレースホルダ)
      - block 1-2      : MAD1(AID=03E1 ×15, CRC8, Info)
      - block 3        : sector0 trailer(MAD キー/アクセス/GPB)
      - block 4..      : NDEF TLV をデータブロックに連続配置(trailer はスキップ)
      - 各 NDEF trailer: D3F7 キー / 7F0788 / GPB 40
    """
    tlv = build_type2_tlv(ndef)  # Classic も NTAG と同じ NDEF Message TLV を使う

    blocks = [bytes(16) for _ in range(64)]

    # --- Sector 0: UID + MAD + MAD trailer ---
    mad_area = build_mad1(uid_block)  # 48 バイト = blk0-2
    blocks[0] = mad_area[0:16]
    blocks[1] = mad_area[16:32]
    blocks[2] = mad_area[32:48]
    blocks[3] = build_trailer(KEY_MAD_A, MAD_ACCESS, MAD_GPB)

    # NDEF 容量チェック: sector 1..15 の各3データブロック = 15*3*16 = 720 バイト。
    cap = 15 * 3 * 16
    if len(tlv) > cap:
        raise ValueError("NDEF が MIFARE Classic 1K の容量(720B)を超えています。")

    # --- Sectors 1..15: TLV を連続データブロックに配置 + 各 NDEF trailer ---
    off = 0
    for sector in range(1, 16):
        base = sector * 4
        for d in range(3):  # データブロック 3 つ
            chunk = tlv[off:off + 16]
            if chunk:
                blocks[base + d] = chunk + bytes(16 - len(chunk))
                off += len(chunk)
            else:
                blocks[base + d] = bytes(16)
        blocks[base + 3] = build_trailer(KEY_NDEF_A, NDEF_ACCESS, NDEF_GPB)

    return blocks


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 7: NTAG21x / Type2 ページイメージビルダ(純関数)
# ═════════════════════════════════════════════════════════════════════════════
#
# CC(page3)の size バイトからユーザ領域上限を導出し、page0-2(UID/静的ロック)・
# CC・末尾の dynamic-lock/CFG/PWD/PACK には一切書き込まない read-modify-write モデル。
# write-url.sh の patch_type2_dump 相当の「イメージ」を純関数で構築する。

# CC size バイト -> NTAG 種別と総ページ数(参考)。ARCH: 213=0x12, 215=0x3E, 216=0x6D。
NTAG_CC = {
    0x12: ("NTAG213", 45),
    0x3E: ("NTAG215", 135),
    0x6D: ("NTAG216", 231),
}


def build_type2_page_image(current_dump, ndef):
    """既存ダンプ(bytes, page0..)へ NDEF を書き込んだ「新イメージ」を返す(bytes)。

    read-modify-write:
      - page0-2(UID/内部/静的ロック)は温存
      - page3(CC)は温存(size バイトからユーザ容量を導出)
      - page4.. にユーザ領域を作り、先頭へ TLV を配置、残りを 0 埋め
      - 末尾 16 バイト(dynamic-lock/CFG/PWD/PACK 等)は元イメージのまま温存
    write-url.sh patch_type2_dump と等価。
    """
    if len(current_dump) < 16:
        raise ValueError("ダンプが短すぎます(最低 page0-3 の 16 バイトが必要)。")

    head = current_dump[0:16]           # page0-3 (UID/内部/ロック/CC)
    cc_size = current_dump[14]          # CC は page3 = bytes 12..15、size は byte2(=index14)
    tlv = build_type2_tlv(ndef)

    data_cap = len(current_dump) - 16   # page4 以降に使える総バイト数
    if len(tlv) > data_cap:
        raise ValueError("URL が長すぎてこのカードに収まりません(ユーザ領域不足)。")

    # CC の size バイトが判れば、その論理容量も超えないこと(安全側チェック)。
    if cc_size in NTAG_CC:
        # CC size バイト * 8 = ユーザメモリ(バイト)。TLV はここに収まるべき。
        logical_cap = cc_size * 8
        if len(tlv) > logical_cap:
            raise ValueError("URL が長すぎます(CC 記載のユーザ容量を超過)。")

    # データ領域: TLV + 0 埋め
    data = bytearray(tlv) + bytes(data_cap - len(tlv))

    # 末尾 16 バイト(dynamic-lock/CFG/PWD/PACK)は元イメージのまま温存。
    if data_cap > 16:
        data[data_cap - 16:] = current_dump[len(current_dump) - 16:]

    return head + bytes(data)


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 1: PC/SC トランスポート(ctypes -> PCSC.framework)
# ═════════════════════════════════════════════════════════════════════════════

# SCARD 定数(winscard / PCSC.framework)。
SCARD_SCOPE_SYSTEM = 2
SCARD_SHARE_SHARED = 2
SCARD_PROTOCOL_T0 = 1
SCARD_PROTOCOL_T1 = 2
SCARD_LEAVE_CARD = 0

SCARD_S_SUCCESS = 0x00000000
SCARD_E_NO_SERVICE = 0x8010001D
SCARD_E_NO_READERS_AVAILABLE = 0x8010002E
SCARD_E_SHARING_VIOLATION = 0x8010000B
SCARD_E_NO_SMARTCARD = 0x8010000C
SCARD_W_REMOVED_CARD = 0x80100069
SCARD_E_TIMEOUT = 0x8010000A
SCARD_E_UNKNOWN_READER = 0x80100009

_PCSC_ERROR_NAMES = {
    SCARD_E_NO_SERVICE: "SCARD_E_NO_SERVICE",
    SCARD_E_NO_READERS_AVAILABLE: "SCARD_E_NO_READERS_AVAILABLE",
    SCARD_E_SHARING_VIOLATION: "SCARD_E_SHARING_VIOLATION",
    SCARD_E_NO_SMARTCARD: "SCARD_E_NO_SMARTCARD",
    SCARD_W_REMOVED_CARD: "SCARD_W_REMOVED_CARD",
    SCARD_E_TIMEOUT: "SCARD_E_TIMEOUT",
    SCARD_E_UNKNOWN_READER: "SCARD_E_UNKNOWN_READER",
}

PCSC_FRAMEWORK = "/System/Library/Frameworks/PCSC.framework/PCSC"


class PCSCError(Exception):
    """PC/SC 呼び出しエラー。code に SCARD の戻り値を保持。"""
    def __init__(self, code, where=""):
        self.code = code & 0xFFFFFFFF
        self.where = where
        name = _PCSC_ERROR_NAMES.get(self.code, "SCARD_ERR")
        super().__init__("%s (0x%08X) at %s" % (name, self.code, where))


class NoReadersError(Exception):
    """リーダーが 1 台も無い(NO_SERVICE / NO_READERS を含む)。"""


class ReaderBusyError(Exception):
    """リーダーが他プロセスに掴まれている(SHARING_VIOLATION)。"""


class NoCardError(Exception):
    """リーダーはあるがカードが無い。"""


class _SCardIORequest(ctypes.Structure):
    # SCARD_IO_REQUEST { dwProtocol; cbPciLength; }
    _fields_ = [("dwProtocol", ctypes.c_uint32),
                ("cbPciLength", ctypes.c_uint32)]


def _load_pcsc():
    """PCSC.framework を ctypes でロードし、関数シグネチャを設定して返す。"""
    path = PCSC_FRAMEWORK
    if not os.path.exists(path):
        found = ctypes.util.find_library("PCSC")
        if not found:
            raise OSError("PCSC.framework が見つかりません(macOS 専用)。")
        path = found
    lib = ctypes.CDLL(path)

    DWORD = ctypes.c_uint32
    LONG = ctypes.c_int32
    LPCSTR = ctypes.c_char_p

    lib.SCardEstablishContext.argtypes = [
        DWORD, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.SCardEstablishContext.restype = LONG

    lib.SCardReleaseContext.argtypes = [ctypes.c_void_p]
    lib.SCardReleaseContext.restype = LONG

    lib.SCardListReaders.argtypes = [
        ctypes.c_void_p, LPCSTR, ctypes.c_char_p, ctypes.POINTER(DWORD)]
    lib.SCardListReaders.restype = LONG

    lib.SCardConnect.argtypes = [
        ctypes.c_void_p, LPCSTR, DWORD, DWORD,
        ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(DWORD)]
    lib.SCardConnect.restype = LONG

    lib.SCardTransmit.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(_SCardIORequest),
        ctypes.c_char_p, DWORD,
        ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(DWORD)]
    lib.SCardTransmit.restype = LONG

    lib.SCardDisconnect.argtypes = [ctypes.c_void_p, DWORD]
    lib.SCardDisconnect.restype = LONG

    return lib


class PCSCContext:
    """SCardEstablishContext / ListReaders / ReleaseContext のラッパ。"""

    def __init__(self):
        self.lib = _load_pcsc()
        self._ctx = ctypes.c_void_p()
        rv = self.lib.SCardEstablishContext(
            SCARD_SCOPE_SYSTEM, None, None, ctypes.byref(self._ctx))
        if rv != SCARD_S_SUCCESS:
            # コンテキスト確立自体が NO_SERVICE を返す環境もある -> リーダー無し扱い。
            if (rv & 0xFFFFFFFF) in (SCARD_E_NO_SERVICE, SCARD_E_NO_READERS_AVAILABLE):
                raise NoReadersError()
            raise PCSCError(rv, "SCardEstablishContext")

    def list_readers(self):
        """リーダー名の list[str] を返す。無ければ []。two-call buffer パターン。"""
        DWORD = ctypes.c_uint32
        length = DWORD(0)
        rv = self.lib.SCardListReaders(self._ctx, None, None, ctypes.byref(length))
        code = rv & 0xFFFFFFFF
        if code in (SCARD_E_NO_SERVICE, SCARD_E_NO_READERS_AVAILABLE):
            # macOS: リーダー未接続だと NO_SERVICE。クラッシュではなく「無し」。
            return []
        if rv != SCARD_S_SUCCESS:
            raise PCSCError(rv, "SCardListReaders(size)")
        if length.value == 0:
            return []
        buf = ctypes.create_string_buffer(length.value)
        rv = self.lib.SCardListReaders(self._ctx, None, buf, ctypes.byref(length))
        code = rv & 0xFFFFFFFF
        if code in (SCARD_E_NO_SERVICE, SCARD_E_NO_READERS_AVAILABLE):
            return []
        if rv != SCARD_S_SUCCESS:
            raise PCSCError(rv, "SCardListReaders(read)")
        # double-null-terminated multistring
        raw = buf.raw[:length.value]
        names = [p.decode("utf-8", "replace") for p in raw.split(b"\x00") if p]
        return names

    def connect(self, reader_name):
        """指定リーダーへ接続。カードが無ければ NoCardError。"""
        return PCSCCard(self.lib, self._ctx, reader_name)

    def release(self):
        if self._ctx:
            self.lib.SCardReleaseContext(self._ctx)
            self._ctx = ctypes.c_void_p()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.release()


class PCSCCard:
    """SCardConnect / Transmit / Disconnect のラッパ(1 枚のカードセッション)。"""

    def __init__(self, lib, ctx, reader_name):
        self.lib = lib
        self._card = ctypes.c_void_p()
        self._proto = ctypes.c_uint32(0)
        rv = lib.SCardConnect(
            ctx, reader_name.encode("utf-8"), SCARD_SHARE_SHARED,
            SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
            ctypes.byref(self._card), ctypes.byref(self._proto))
        code = rv & 0xFFFFFFFF
        if rv != SCARD_S_SUCCESS:
            if code == SCARD_E_SHARING_VIOLATION:
                raise ReaderBusyError()
            if code in (SCARD_E_NO_SMARTCARD, SCARD_W_REMOVED_CARD):
                raise NoCardError()
            raise PCSCError(rv, "SCardConnect")

    def transmit(self, apdu):
        """APDU(bytes) を送信し、応答 bytes を返す(SW 含む)。"""
        DWORD = ctypes.c_uint32
        # ARCH: SCARD_IO_REQUEST inline {dwProtocol=2, cbPciLength=8}
        pci = _SCardIORequest(SCARD_PROTOCOL_T1, 8)
        send = bytes(apdu)
        recv = ctypes.create_string_buffer(258 + 2)
        recv_len = DWORD(len(recv))
        rv = self.lib.SCardTransmit(
            self._card, ctypes.byref(pci), send, len(send),
            None, recv, ctypes.byref(recv_len))
        if rv != SCARD_S_SUCCESS:
            raise PCSCError(rv, "SCardTransmit")
        return recv.raw[:recv_len.value]

    def disconnect(self):
        if self._card:
            self.lib.SCardDisconnect(self._card, SCARD_LEAVE_CARD)
            self._card = ctypes.c_void_p()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.disconnect()


# ═════════════════════════════════════════════════════════════════════════════
#  PC/SC 擬似 APDU(class 0xFF)ビルダ — ARCH の定義に厳密準拠
# ═════════════════════════════════════════════════════════════════════════════

def apdu_get_uid():
    return bytes([0xFF, 0xCA, 0x00, 0x00, 0x00])


def apdu_load_key(slot, key6):
    if len(key6) != 6:
        raise ValueError("key は 6 バイト")
    return bytes([0xFF, 0x82, 0x00, slot, 0x06]) + bytes(key6)


def apdu_auth(block, keytype, slot):
    # FF 86 00 00 05  01 00 <block> <keytype 60=A|61=B> <slot>
    return bytes([0xFF, 0x86, 0x00, 0x00, 0x05, 0x01, 0x00, block, keytype, slot])


def apdu_read(block, length=16):
    return bytes([0xFF, 0xB0, 0x00, block, length])


def apdu_write(block, data):
    return bytes([0xFF, 0xD6, 0x00, block, len(data)]) + bytes(data)


KEYTYPE_A = 0x60
KEYTYPE_B = 0x61


def sw_ok(resp):
    """応答末尾 2 バイトが 90 00 なら成功。"""
    return len(resp) >= 2 and resp[-2] == 0x90 and resp[-1] == 0x00


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 2: リーダーの分類(family)
# ═════════════════════════════════════════════════════════════════════════════
#
# リーダー名から family を判定し、capability matrix を駆動する。
#
#   nxp     : PN53x 系(NXP PN531/532/533 チップ)を積む CCID リーダー。
#             ACR122U / ACR122 / SCL3711 / Touchatag / uTrust 3700 (PN533版) 等。
#             ★ MIFARE Classic の Crypto1 認証(FF 82 / FF 86 疑似APDU)を実装するのは
#               この family のみ。Type2/Type4 も当然扱える。
#   generic : PN53x 以外の Type-A 対応 PC/SC(CCID)リーダー。
#             ACR1252 / ACR1255 / OMNIKEY 5x22 / PC Twin / Identiv 3700 F 等。
#             ISO14443A 標準 APDU で NFC Forum Type2/Type4 は読み書きできるが、
#             Crypto1 は非実装なので MIFARE Classic は扱えない。
#   felica  : Sony FeliCa 系(RC-S300/RC-S380/PaSoRi/SONY Felica Port)。
#             Type-A の Classic/Type2/Type4 は扱えず、FeliCa は検出のみ(書込は Phase5)。
#   unknown : 上記いずれにも当てはまらない未分類リーダー。安全側に倒す。
#
# 判定は「大文字化した名前への部分一致(substring)」で、ベンダ接頭辞に強くする。

READER_NXP = "nxp"
READER_GENERIC = "generic"
READER_FELICA = "felica"
READER_UNKNOWN = "unknown"


# FeliCa 系(Sony)。Type-A の Classic/Type2/Type4 は不可、FeliCa は検出のみ。
# NOTE: これらは最優先で判定する(Sony 製品名は他の family キーワードと衝突しないが、
#       "FELICA PORT" 等を確実に felica に寄せるため先頭で弾く)。
_READER_KW_FELICA = (
    "FELICA", "PASORI", "RC-S300", "RC-S380", "RC-S", "SONY FELICA",
)

# PN53x 系(NXP)。MIFARE Classic Crypto1 を実装できる唯一の family。
# ACR122U/ACR122/ACR1222 は PN532、SCL3711/Touchatag/一部 uTrust 3700 は PN533。
_READER_KW_NXP = (
    "ACR122", "ACR1222", "ACR1281",
    "SCL3711", "SCL011",           # SCM Microsystems PN533 系
    "TOUCHATAG",                   # Touchatag(旧 Tikitag)= PN532
    "PN531", "PN532", "PN533", "PN53X", "PN53",
)

# 汎用 Type-A CCID(PN53x 以外)。Type2/Type4 可、Classic 不可。
# ACR1252/ACR1255、Identiv/SCM uTrust 3700 F、HID OMNIKEY 5x22、Gemalto/Thales PC Twin。
_READER_KW_GENERIC = (
    "ACR1252", "ACR1255", "ACR1251", "ACR1283", "ACR1311",
    "UTRUST 3700", "µTRUST 3700", "IDENTIV", "UTRUST", "µTRUST",
    "OMNIKEY", "OMNIKEY 5022", "OMNIKEY 5122", "OMNIKEY 5422",
    "PC TWIN", "GEMALTO", "THALES", "GEMPC",
    "CONTACTLESS", "CCID",         # 汎用非接触 CCID の総称
)


def classify_reader(name):
    """リーダー名(str) -> family トークン。大文字化 + 部分一致(substring)。"""
    u = (name or "").upper()
    # 1) FeliCa 系を最優先で弾く(Sony 製品名)。
    for kw in _READER_KW_FELICA:
        if kw in u:
            return READER_FELICA
    # 2) PN53x 系(Crypto1 可)。汎用より先に判定して ACR1252 等と取り違えない。
    for kw in _READER_KW_NXP:
        if kw in u:
            return READER_NXP
    # 3) 汎用 Type-A CCID(Classic 不可、Type2/Type4 可)。
    for kw in _READER_KW_GENERIC:
        if kw in u:
            return READER_GENERIC
    # 4) それ以外は未分類。
    return READER_UNKNOWN


def reader_family_label(family):
    return {
        READER_NXP: "PN53x系(ACR122U など。MIFARE Classic 対応)",
        READER_GENERIC: "汎用 Type-A リーダー(NTAG/Type2・Type4。Classic 非対応)",
        READER_FELICA: "Sony/FeliCa系(RC-S300/RC-S380/PaSoRi。検出のみ)",
        READER_UNKNOWN: "不明なリーダー",
    }.get(family, "不明なリーダー")


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 3: タグ検出 / 分類
# ═════════════════════════════════════════════════════════════════════════════
#
# 分類方法(ARCH に基づく):
#   1) ATR(SCardStatus 相当)は本エンジンでは取得しないため、PC/SC 標準の
#      「PICC 用 ATR」の historical bytes に埋め込まれた SS(標準)/名前バイトを使う。
#      ACR122U 系は接触なしカードに対し
#        3B 8F 80 01 80 4F 0C A0 00 00 03 06 <SS> <name0 name1> ... のような ATR を返し、
#      その <SS>(storage standard)と name バイトでカード種別を示す。
#   2) 実運用では SAK が最も確実なので、ATR が不定な場合に備え、UID 取得可否 +
#      MIFARE Classic 認証プローブ(sector0 を FF キーで auth 試行)で Type-A の
#      Classic/Type2/Type4 を切り分ける。
#
# ここでは「与えられた ATR historical bytes」から分類する純関数 classify_tag_from_atr
# を提供し、単体テスト可能にする。ライブ経路はこの関数 + プローブを併用する。
#
# PC/SC ATR の name バイト(PICC 用、PC/SC ワーキンググループ Part3 の登録値):
#   00 01 = MIFARE Classic 1K
#   00 02 = MIFARE Classic 4K
#   00 03 = MIFARE Ultralight (Type2)
#   00 26 = MIFARE Mini
#   00 3A = MIFARE Ultralight C
#   F0 04 = Topaz/Jewel
#   FF 40..FF88 = NTAG 各種(ベンダ依存だが Ultralight 系=Type2 として扱う)
#   00 3B / 00 XX with SS=... = DESFire/Type4 は ATR の application 種別で 20 系
# 実際にはリーダー実装差があるため、name バイトを主、SAK をライブで補助に使う。

TAG_CLASSIC = "classic"
TAG_TYPE2 = "type2"
TAG_TYPE4 = "type4"
TAG_FELICA = "felica"
TAG_UNKNOWN = "unknown"
TAG_NONE = "none"


# SAK による分類(write-url.sh parse_tag_type と同一テーブル)。
_SAK_MAP = {
    0x08: TAG_CLASSIC, 0x88: TAG_CLASSIC, 0x09: TAG_CLASSIC, 0x18: TAG_CLASSIC,
    0x28: TAG_CLASSIC, 0x98: TAG_CLASSIC, 0x38: TAG_CLASSIC,
    0x00: TAG_TYPE2,
    0x20: TAG_TYPE4, 0x24: TAG_TYPE4,
}


def classify_tag_from_sak(sak):
    """SAK バイト(int) -> tag type。write-url.sh と同一。"""
    return _SAK_MAP.get(sak, TAG_UNKNOWN)


def classify_tag_from_atr(atr):
    """PC/SC の PICC ATR(bytes) -> tag type。

    ATR: 3B 8F 80 01 <T0..> ... の中の application identifier
      "...A0 00 00 03 06 <SS> <NAME_HI> <NAME_LO> ..." を探して name バイトで判定。
    RID A0 00 00 03 06 は PC/SC の PICC 用。<SS>=storage standard。
    """
    if not atr or len(atr) < 2:
        return TAG_UNKNOWN
    # FeliCa は PC/SC でも独自 ATR(RID に F0 系, または name FeliCa)を返す実装がある。
    rid = bytes([0xA0, 0x00, 0x00, 0x03, 0x06])
    idx = atr.find(rid)
    if idx < 0 or idx + 8 > len(atr):
        # RID が無い ATR。FeliCa 判定を試みる(Sony PICC の name)。
        return TAG_UNKNOWN
    # atr[idx+5] = SS, atr[idx+6..idx+7] = name(card type)
    name_hi = atr[idx + 6]
    name_lo = atr[idx + 7]
    name = (name_hi, name_lo)
    if name == (0x00, 0x01):   # Classic 1K
        return TAG_CLASSIC
    if name == (0x00, 0x02):   # Classic 4K
        return TAG_CLASSIC
    if name == (0x00, 0x26):   # Mini
        return TAG_CLASSIC
    if name == (0x00, 0x03):   # Ultralight
        return TAG_TYPE2
    if name == (0x00, 0x3A):   # Ultralight C
        return TAG_TYPE2
    if name_hi == 0xFF:        # NTAG 系(ベンダ定義)= Type2 として扱う
        return TAG_TYPE2
    if name == (0x00, 0x3B) or name == (0x00, 0x20):  # DESFire/Type4
        return TAG_TYPE4
    return TAG_UNKNOWN


def detect_tag_live(card):
    """接続済みカードから UID を取り、SAK 相当を推定して分類する(ライブ)。

    手順:
      1) FF CA 00 00 00 で UID を取得(成否でカードの有無/Type-A 応答を確認)。
      2) MIFARE Classic 認証プローブ: FF キーを slot0 にロードし block0 を KeyA auth。
         成功すれば Classic の可能性大。ただし NTAG は auth に応じないので失敗する。
      3) UID 長 4/7 と応答から Type2/Type4 を推定(補助)。
    返り値: (tag_type, uid_hex or None)
    """
    try:
        resp = card.transmit(apdu_get_uid())
    except NoCardError:
        return TAG_NONE, None
    if not sw_ok(resp):
        return TAG_UNKNOWN, None
    uid = resp[:-2]
    uid_hex = uid.hex()

    # Classic 認証プローブ(非破壊: 読みも書きもしない、auth のみ)。
    # NDEF フォーマット済み Classic は sector0=A0A1(MAD)/data=D3F7 を使い FF では
    # auth できないため、read/write 経路と同じ鍵候補(_CLASSIC_MAD_KEYS)を試す。
    try:
        if _auth_sector(card, 0, _CLASSIC_MAD_KEYS) is not None:
            return TAG_CLASSIC, uid_hex
    except PCSCError:
        pass

    # auth 不成立 -> Type2/Type4。UID 7バイト & page 読取り可否で type2 を優先推定。
    try:
        page = card.transmit(apdu_read(0x03, 16))  # CC 読み(Type2 なら成功)
        if sw_ok(page):
            return TAG_TYPE2, uid_hex
    except PCSCError:
        pass
    return TAG_TYPE4, uid_hex


# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 4: capability matrix(reader_family × tag_type)
# ═════════════════════════════════════════════════════════════════════════════
#
# データ駆動。値: "ok"(正式対応) / "exp"(実験的対応) / "no"(非対応)。
# ルール(ARCH / Phase2):
#   MIFARE Classic  … Crypto1 認証が要るので PN53x 系(nxp)でのみ可。
#                     汎用 Type-A CCID(generic)/FeliCa/未分類では不可。
#   Type2(NTAG等)  … ISO14443A 標準 APDU で読み書き。Type-A が通る nxp/generic で可。
#   Type4(DESFire) … 同上(Type-A 標準 APDU)。nxp/generic で可(実装は Phase5 で本格化)。
#   FeliCa          … NDEF 書き込みは全リーダーで非対応(検出のみ。Phase5 まで)。
#   unknown リーダー … 素性不明。Type-A が通るとは限らないので安全側で "no"(試行させない)。
#                     ただし Classic だけは「PN53x 以外は原理的に不可」と同じ扱いで "no"。

CAPABILITY = {
    #                classic     type2       type4       felica
    READER_NXP:     {TAG_CLASSIC: "ok",  TAG_TYPE2: "exp", TAG_TYPE4: "exp", TAG_FELICA: "no"},
    READER_GENERIC: {TAG_CLASSIC: "no",  TAG_TYPE2: "exp", TAG_TYPE4: "exp", TAG_FELICA: "no"},
    READER_FELICA:  {TAG_CLASSIC: "no",  TAG_TYPE2: "no",  TAG_TYPE4: "no",  TAG_FELICA: "no"},
    READER_UNKNOWN: {TAG_CLASSIC: "no",  TAG_TYPE2: "no",  TAG_TYPE4: "no",  TAG_FELICA: "no"},
}

# 非対応時に添える説明(INCOMPAT: の日本語部分)。
# 「なぜ扱えないか」「どんなリーダーが要るか」を、失敗したタグに合わせて具体的に述べる。
# リーダー family ごとに文面を変えたいので (tag, family) の 2 段引きにする。
#   _INCOMPAT_MSG[tag][family] があればそれを、無ければ _INCOMPAT_MSG[tag][None] を使う。

# MIFARE Classic は Crypto1 認証が必須で PN53x 系リーダーだけが扱える、という核となる説明。
_CLASSIC_WHY = ("MIFARE Classic は Crypto1 認証が必要で、"
                "PN53x系リーダー(ACR122U など)でのみ扱えます。")

_INCOMPAT_MSG = {
    TAG_CLASSIC: {
        READER_GENERIC: _CLASSIC_WHY + "お使いのリーダーは Type-A の NTAG/Type4 には対応しますが Classic は扱えません。",
        READER_FELICA:  _CLASSIC_WHY + "Sony RC-S300/RC-S380/PaSoRi では扱えません。",
        None:           _CLASSIC_WHY,
    },
    TAG_TYPE2: {
        READER_FELICA: "NTAG/Type2 は ISO14443A(Type-A)対応リーダーが必要で、FeliCa専用リーダー(RC-S300 など)では扱えません。ACR122U 等をご利用ください。",
        None:          "NTAG/Type2 を扱うには ISO14443A(Type-A)対応リーダーが必要です。ACR122U 等をご利用ください。",
    },
    TAG_TYPE4: {
        READER_FELICA: "Type4(DESFire 等)は ISO14443A(Type-A)対応リーダーが必要で、FeliCa専用リーダー(RC-S300 など)では扱えません。ACR122U 等をご利用ください。",
        None:          "Type4(DESFire 等)を扱うには ISO14443A(Type-A)対応リーダーが必要です。ACR122U 等をご利用ください。",
    },
    TAG_FELICA: {
        None: "FeliCa カードへの NDEF URL 書き込みには対応していません。NTAG213/215/216 か MIFARE Classic 1K をご利用ください。",
    },
    TAG_UNKNOWN: {
        None: "カードの種類を判別できませんでした。対応カード(NTAG/MIFARE Classic 1K)を、対応リーダー(ACR122U など)でお試しください。",
    },
}


def capability(reader_family, tag_type):
    """(family, tag_type) -> "ok" | "exp" | "no"。未知は "no"。"""
    return CAPABILITY.get(reader_family, {}).get(tag_type, "no")


def incompat_message(tag_type, reader_family=None):
    """INCOMPAT: 行の日本語説明部分を返す。

    リーダー family が分かる場合は、それに合わせて「なぜ/何が要るか」を具体化する。
    family 別の文面が無ければ、その tag の汎用文面(None キー)を返す。
    """
    per_tag = _INCOMPAT_MSG.get(tag_type)
    if not per_tag:
        return "このリーダーでは扱えないカードです。"
    if reader_family in per_tag:
        return per_tag[reader_family]
    return per_tag.get(None, "このリーダーでは扱えないカードです。")


def emit_incompat(tag_type, reader_family=None):
    """出力コントラクト: INCOMPAT: <tagtype>|<日本語>。"""
    print("INCOMPAT: %s|%s" % (tag_type, incompat_message(tag_type, reader_family)))


# ═════════════════════════════════════════════════════════════════════════════
#  MIFARE Classic over PC/SC(ライブ: read / write / format)
# ═════════════════════════════════════════════════════════════════════════════
#
# ARCH の書き込み順(mid-write 失敗耐性): 各セクタで「データブロック先 -> trailer 後」。
# trailer を書くとキーが変わるため最後に書く。認証キーは既存 NDEF カードなら D3F7/A0A1、
# 工場出荷は FF。ここでは両方を順に試すヘルパを用意する。

# 認証で試すキー候補(既存 NDEF -> MAD -> 工場出荷 の順)。
# データセクタは通常 D3F7 だが、一部書き込みツールは A0A1 を流用するため両方試す。
_CLASSIC_DATA_KEYS = [KEY_NDEF_A, KEY_MAD_A, KEY_FFFFFF]
_CLASSIC_MAD_KEYS = [KEY_MAD_A, KEY_NDEF_A, KEY_FFFFFF]


def _auth_sector(card, sector, keys):
    """sector の block0 を、候補キーで KeyA 認証。成功したキーを返す / None。"""
    block = sector * 4
    for slot, key in enumerate(keys):
        try:
            if not sw_ok(card.transmit(apdu_load_key(0x00, key))):
                continue
            if sw_ok(card.transmit(apdu_auth(block, KEYTYPE_A, 0x00))):
                return key
        except PCSCError:
            continue
    return None


def classic_write_image(card, blocks):
    """64×16 ブロックイメージをカードへ書き込む(block0/UID と trailer 認証を考慮)。

    - block 0 は書かない(UID/manufacturer, read-only)。
    - 各セクタ: データブロックを先に書き、trailer を最後に書く(ARCH 準拠)。
    - 認証は D3F7/A0A1 -> FF の順で試す。
    """
    for sector in range(16):
        key = _auth_sector(card, sector,
                           _CLASSIC_MAD_KEYS if sector == 0 else _CLASSIC_DATA_KEYS)
        if key is None:
            raise PCSCError(SCARD_E_NO_SMARTCARD, "auth sector %d" % sector)
        base = sector * 4
        # データブロック(block0=UID はスキップ、sector0 の blk1-2 は MAD なので書く)
        data_blocks = range(1, 3) if sector == 0 else range(0, 3)
        for d in data_blocks:
            blk = base + d
            if not sw_ok(card.transmit(apdu_write(blk, blocks[blk]))):
                raise PCSCError(SCARD_E_NO_SMARTCARD, "write block %d" % blk)
        # trailer(最後に。書くとキーが変わる)
        tb = base + 3
        if not sw_ok(card.transmit(apdu_write(tb, blocks[tb]))):
            raise PCSCError(SCARD_E_NO_SMARTCARD, "write trailer %d" % tb)


def parse_mad_ndef_sectors(mad_bytes):
    """MAD 本体(blk1+blk2 = 32バイト)から NDEF(AID=03 E1)のセクタ番号 list を返す。

    mad_bytes: [CRC, Info, AID_s1(2), AID_s2(2), ... AID_s15(2)](32バイト)。
    NDEF AID(03 E1)が入っているセクタ番号(1..15)を昇順で返す。空なら []。
    """
    sectors = []
    if len(mad_bytes) < 32:
        return sectors
    for s in range(1, 16):
        pos = 2 * s
        if mad_bytes[pos:pos + 2] == MAD_AID_NDEF:
            sectors.append(s)
    return sectors


def classic_read_ndef(card):
    """MIFARE Classic からデータセクタを読み、NDEF を復元して返す(bytes or None)。

    手順(NFC Forum / AN10787 準拠):
      1) sector0 を MAD キー(A0A1 -> D3F7 -> FF)で認証し、MAD(blk1-2)を読む。
      2) MAD の AID(03 E1)で NDEF セクタ番号を特定する。
      3) MAD が読めない/AID が無い場合はフォールバックで sector1..15 を走査する。
      4) 各 NDEF セクタを D3F7 -> A0A1 -> FF の順で認証し、3データブロック
         (trailer=blk3 は除く)を読み、TLV に連結する。
      5) TLV(03 <len> ... FE)を復元して NDEF を取り出す。
    """
    # --- 1) MAD を読み、NDEF セクタを特定 ---
    ndef_sectors = []
    mad_key = _auth_sector(card, 0, _CLASSIC_MAD_KEYS)
    if mad_key is not None:
        mad = bytearray()
        for d in (1, 2):  # sector0 blk1, blk2 = MAD 本体
            resp = card.transmit(apdu_read(d, 16))
            if not sw_ok(resp):
                mad = bytearray()
                break
            mad += resp[:-2]
        if len(mad) >= 32:
            ndef_sectors = parse_mad_ndef_sectors(bytes(mad))

    # --- 3) フォールバック: MAD が使えなければ 1..15 を総当り ---
    if not ndef_sectors:
        ndef_sectors = list(range(1, 16))

    # --- 4) NDEF セクタからデータブロックを連結 ---
    tlv = bytearray()
    for sector in ndef_sectors:
        key = _auth_sector(card, sector, _CLASSIC_DATA_KEYS)
        if key is None:
            continue  # このセクタは読めない -> スキップ(全体は止めない)
        base = sector * 4
        for d in range(3):  # データブロックのみ(blk3=trailer は除外)
            resp = card.transmit(apdu_read(base + d, 16))
            if not sw_ok(resp):
                break
            tlv += resp[:-2]

    # --- 5) TLV -> NDEF ---
    return extract_type2_ndef(bytes(tlv))


def classic_format_and_write(card, ndef):
    """フォーマット + NDEF 書き込み(1K イメージを構築して書く)。"""
    blocks = build_classic_1k_image(ndef)
    classic_write_image(card, blocks)


# ═════════════════════════════════════════════════════════════════════════════
#  NTAG / Type2 over PC/SC(ライブ: read / write)
# ═════════════════════════════════════════════════════════════════════════════

def type2_read_all(card, max_pages=231):
    """Type2 を page0 から読み(FF B0, 16B=4page 単位)、生ダンプを返す。"""
    dump = bytearray()
    page = 0
    while page < max_pages:
        resp = card.transmit(apdu_read(page, 16))
        if not sw_ok(resp):
            break
        dump += resp[:-2]
        page += 4
    return bytes(dump)


def type2_write_ndef(card, ndef):
    """read-modify-write で NTAG に NDEF を書く(lock/OTP/CC/CFG は温存)。"""
    dump = type2_read_all(card)
    if len(dump) < 16:
        raise PCSCError(SCARD_E_NO_SMARTCARD, "type2 read")
    new_image = build_type2_page_image(dump, ndef)
    # page4 以降のみ 4バイト単位で書き込む(page0-3 は温存)。
    # 末尾 16 バイト(dynamic-lock/CFG/PWD/PACK)は new_image が元値を保持しているが、
    # 安全のため書き込み範囲を「元 TLV が収まるページ」までに限定する。
    tlv = build_type2_tlv(ndef)
    tlv_pages = (len(tlv) + 3) // 4
    for i in range(tlv_pages):
        page = 4 + i
        chunk = new_image[16 + i * 4:16 + i * 4 + 4]
        if len(chunk) < 4:
            chunk = chunk + bytes(4 - len(chunk))
        if not sw_ok(card.transmit(apdu_write(page, chunk))):
            raise PCSCError(SCARD_E_NO_SMARTCARD, "type2 write page %d" % page)


def type2_read_ndef(card):
    dump = type2_read_all(card)
    if len(dump) < 16:
        return None
    return extract_type2_ndef(dump[16:])


# ═════════════════════════════════════════════════════════════════════════════
#  ライブ経路の共通: リーダー選択 + タグ検出 + capability
# ═════════════════════════════════════════════════════════════════════════════

# リーダー選択の優先度(小さいほど優先)。
# PN53x(Classic 可)> 汎用 Type-A(Type2/Type4 可)> 未分類 > FeliCa(検出のみ)。
_READER_RANK = {
    READER_NXP: 0,
    READER_GENERIC: 1,
    READER_UNKNOWN: 2,
    READER_FELICA: 3,
}


def _pick_reader(names):
    """最も対応範囲の広いリーダーを 1 台選ぶ。返り値 (name, family) or (None, None)。

    PN53x を最優先(MIFARE Classic 可)、次いで汎用 Type-A(Type2/Type4 可)、
    未分類、最後に FeliCa(検出のみ)の順に選ぶ。同順位なら列挙順を保つ。
    """
    if not names:
        return None, None
    ranked = sorted(names, key=lambda n: _READER_RANK.get(classify_reader(n), 9))
    name = ranked[0]
    return name, classify_reader(name)


def _open_context_or_none():
    """PCSCContext を開く。リーダー無しや PCSC 不在は None を返す(クラッシュしない)。"""
    try:
        return PCSCContext()
    except NoReadersError:
        return None
    except OSError:
        return None
    except PCSCError:
        return None


# ═════════════════════════════════════════════════════════════════════════════
#  CLI: --detect
# ═════════════════════════════════════════════════════════════════════════════

def cmd_detect():
    ctx = _open_context_or_none()
    if ctx is None:
        print("READER: NONE")
        print("TAG: none")
        warn("対応リーダーが見つかりません(PC/SC)。ACR122U 等の NXP系リーダーが必要です。")
        return 0
    try:
        try:
            names = ctx.list_readers()
        except PCSCError as e:
            detail(str(e))
            names = []
        if not names:
            print("READER: NONE")
            print("TAG: none")
            warn("対応リーダーが見つかりません(PC/SC)。ACR122U 等の NXP系リーダーが必要です。")
            return 0

        name, family = _pick_reader(names)
        print("READER: %s" % name)
        detail("使用リーダー: %s" % name)

        try:
            card = ctx.connect(name)
        except NoCardError:
            print("TAG: none")
            ok("使用リーダー: %s" % name)
            step("カードは検出されていません。カードをリーダーに置いてください。")
            return 0
        except ReaderBusyError:
            print("TAG: none")
            warn("リーダーが他のプロセスに使用されています(reader busy/claimed)。")
            return 0

        try:
            tag_type, uid_hex = detect_tag_live(card)
        finally:
            card.disconnect()

        if tag_type == TAG_NONE:
            print("TAG: none")
            ok("使用リーダー: %s" % name)
            step("カードは検出されていません。")
            return 0

        print("TAG: %s" % tag_type)
        detail("カード種別を判定しました: %s" % tag_type)
        ok("使用リーダー: %s" % name)

        cap = capability(family, tag_type)
        if cap == "no":
            emit_incompat(tag_type, family)
            warn(incompat_message(tag_type, family))
        else:
            step("カードを検出: %s(%s)" % (tag_type, "正式対応" if cap == "ok" else "実験的対応"))
        return 0
    finally:
        ctx.release()


# ═════════════════════════════════════════════════════════════════════════════
#  CLI: --read / --write(ライブ。リーダー無しなら READER: NONE で綺麗に終了)
# ═════════════════════════════════════════════════════════════════════════════

def _live_setup():
    """(ctx, card, name, family, tag_type) を返す。失敗時は例外/None を上位で処理。"""
    ctx = _open_context_or_none()
    if ctx is None:
        print("READER: NONE")
        warn("対応リーダーが見つかりません(PC/SC)。")
        return None
    names = ctx.list_readers()
    if not names:
        print("READER: NONE")
        warn("対応リーダーが見つかりません(PC/SC)。")
        ctx.release()
        return None
    name, family = _pick_reader(names)
    print("READER: %s" % name)
    detail("使用リーダー: %s" % name)
    try:
        card = ctx.connect(name)
    except NoCardError:
        step("カードをリーダーに置いてください。")
        ctx.release()
        return None
    except ReaderBusyError:
        warn("リーダーが他のプロセスに使用されています(reader busy/claimed)。")
        ctx.release()
        return None
    tag_type, uid_hex = detect_tag_live(card)
    detail("カード種別を判定しました: %s" % tag_type)
    return ctx, card, name, family, tag_type


def cmd_read():
    setup = _live_setup()
    if setup is None:
        return 0
    ctx, card, name, family, tag_type = setup
    try:
        cap = capability(family, tag_type)
        if cap == "no":
            emit_incompat(tag_type, family)
            fail(incompat_message(tag_type, family))
            return 1
        step("カードを読み取っています…")
        if tag_type == TAG_CLASSIC:
            ndef = classic_read_ndef(card)
        elif tag_type == TAG_TYPE2:
            ndef = type2_read_ndef(card)
        else:
            warn("このカード種別の読み取りは未実装です: %s" % tag_type)
            return 1
        if not ndef:
            fail("NDEF が見つかりませんでした。")
            return 1
        url = decode_ndef_uri(ndef)
        if url:
            ok("URL: %s" % url)
        else:
            ok("NDEF(生): %s" % ndef.hex())
        return 0
    finally:
        card.disconnect()
        ctx.release()


def cmd_print_ndef(url):
    """--print-ndef: ハードウェア不要。生成される NDEF バイト列を表示して終了。
    write-url.sh --print-ndef と同じ stdout コントラクトを守る:
        URL : <url>
        NDEF: <hex>
    """
    ndef = build_ndef_message(url)
    print("URL : %s" % url)
    print("NDEF: %s" % ndef.hex())
    return 0


def cmd_write(url):
    ndef = build_ndef_message(url)
    setup = _live_setup()
    if setup is None:
        return 0
    ctx, card, name, family, tag_type = setup
    try:
        cap = capability(family, tag_type)
        if cap == "no":
            emit_incompat(tag_type, family)
            fail(incompat_message(tag_type, family))
            return 1
        if cap == "exp":
            warn("このカードへの書き込みは実験的機能です。")
        step("書き込み中です…(%s)" % url)
        if tag_type == TAG_CLASSIC:
            classic_format_and_write(card, ndef)
        elif tag_type == TAG_TYPE2:
            type2_write_ndef(card, ndef)
        else:
            fail("このカード種別への書き込みは未実装です: %s" % tag_type)
            return 1
        ok("書き込みが完了しました。")
        return 0
    except PCSCError as e:
        detail(str(e))
        fail("書き込みに失敗しました。")
        return 1
    finally:
        card.disconnect()
        ctx.release()


# ═════════════════════════════════════════════════════════════════════════════
#  --self-test: ハードウェア不要。全バイト/イメージ単体テストを実行し 0/非0 で終了。
# ═════════════════════════════════════════════════════════════════════════════

def run_self_test():
    fails = 0

    def check(desc, got, expect):
        nonlocal fails
        if got == expect:
            print("ok   %s" % desc)
        else:
            print("FAIL %s : 期待=%r 実際=%r" % (desc, expect, got))
            fails += 1

    # --- golden NDEF vectors ---
    v1 = build_ndef_message("https://example.com/").hex()
    check("NDEF golden example.com", v1, "d1010d55046578616d706c652e636f6d2f")
    # golden 全長は 17B(D1 01 0D 55 04 + "example.com/"=12B)。header 3 + type 1 + payload 13。
    check("NDEF golden 全長17", len(build_ndef_message("https://example.com/")), 17)
    check("NDEF golden payload長 0x0D", build_ndef_message("https://example.com/")[2], 0x0D)

    v2 = build_ndef_message("https://test.example/abc").hex()
    check("NDEF golden test.example/abc", v2,
          "d101115504746573742e6578616d706c652f616263")

    # URI code 判定(prefix 圧縮)
    code_www, rest_www = ndef_uri_parts("https://www.example.com")
    check("URI code https://www.", code_www, 0x02)
    code_http, _ = ndef_uri_parts("http://x")
    check("URI code http://", code_http, 0x03)
    code_tel, rest_tel = ndef_uri_parts("tel:123")
    check("URI code tel:", (code_tel, rest_tel), (0x05, "123"))
    code_raw, rest_raw = ndef_uri_parts("ftp://x")
    check("URI code なし(0x00)", (code_raw, rest_raw), (0x00, "ftp://x"))

    # --- Type2 TLV ---
    ndef = build_ndef_message("https://example.com/")
    tlv = build_type2_tlv(ndef)
    check("Type2 TLV 先頭 03", tlv[0], 0x03)
    check("Type2 TLV len=NDEF長", tlv[1], len(ndef))
    check("Type2 TLV NDEF 本体一致", tlv[2:2 + len(ndef)], ndef)
    check("Type2 TLV 終端 FE 位置", tlv[2 + len(ndef)], 0xFE)
    check("Type2 TLV 4byte境界", len(tlv) % 4, 0)

    # TLV 往復抽出(build -> extract)
    rt = extract_type2_ndef(tlv)
    check("Type2 TLV 往復抽出", rt, ndef)

    # NDEF デコード往復
    check("NDEF decode 往復", decode_ndef_uri(ndef), "https://example.com/")

    # --- Type2 ページイメージ ---
    # 疑似 NTAG213 ダンプ: page0-2(12B) + CC(E1 10 12 00) + 0埋め(180B まで)
    dump = bytearray()
    dump += bytes([0x04, 0x05, 0x06, 0x07,   # page0
                   0x08, 0x09, 0x0a, 0x0b,   # page1
                   0x0c, 0x0d, 0x0e, 0x0f])  # page2
    dump += bytes([0xE1, 0x10, 0x12, 0x00])  # page3 CC(NTAG213, size=0x12)
    dump += bytes(180 - len(dump))           # page4.. を 0 埋め(180B=45page)
    # 末尾 16 バイトに識別値を入れておき、温存されることを確認
    dump[len(dump) - 16:] = bytes(range(0xE0, 0xF0))
    img = build_type2_page_image(bytes(dump), ndef)
    check("Type2 img page0-3 温存", img[:16], bytes(dump[:16]))
    check("Type2 img page4=TLV先頭", img[16:16 + len(tlv)], tlv)
    check("Type2 img 末尾16温存", img[-16:], bytes(dump[-16:]))
    # 往復: page4 以降から NDEF を復元
    rt2 = extract_type2_ndef(img[16:])
    check("Type2 img 往復抽出", rt2, ndef)

    # --- MIFARE Classic 1K ブロックイメージ ---
    blocks = build_classic_1k_image(ndef)
    check("Classic ブロック数 64", len(blocks), 64)
    check("Classic 各ブロック 16B", all(len(b) == 16 for b in blocks), True)
    # block0 = UID/manufacturer は書かない(イメージ上はプレースホルダ 0)
    check("Classic block0 未変更(全0)", blocks[0], bytes(16))
    # MAD: block1 の AID(sector1)= 03 E1、Info=0x01、CRC が正しいこと
    check("Classic MAD Info(0x01)", blocks[1][1], 0x01)
    # blk1 は [CRC, Info, AID(sector1) 03 E1, AID(sector2)...]
    check("Classic MAD sector1 AID", blocks[1][2:4], MAD_AID_NDEF)
    check("Classic MAD sector7 AID", blocks[1][14:16], MAD_AID_NDEF)
    check("Classic MAD sector8 AID", blocks[2][0:2], MAD_AID_NDEF)
    check("Classic MAD sector15 AID", blocks[2][14:16], MAD_AID_NDEF)
    # MAD CRC 検算(byte1..byte31 に対する CRC8)
    mad_body = blocks[1][1:] + blocks[2]
    check("Classic MAD CRC8", blocks[1][0], crc8_mad(mad_body))
    # Sector0 trailer(block3) = A0A1.. / 78 77 88 / C1 / FF..
    t0 = blocks[3]
    check("Classic S0 trailer KeyA", t0[0:6], KEY_MAD_A)
    check("Classic S0 trailer Access", t0[6:9], MAD_ACCESS)
    check("Classic S0 trailer GPB", t0[9], MAD_GPB)
    check("Classic S0 trailer KeyB", t0[10:16], KEY_FFFFFF)
    # NDEF sector1 trailer(block7) = D3F7.. / 7F 07 88 / 40 / FF..
    t1 = blocks[7]
    check("Classic S1 trailer KeyA", t1[0:6], KEY_NDEF_A)
    check("Classic S1 trailer Access", t1[6:9], NDEF_ACCESS)
    check("Classic S1 trailer GPB", t1[9], NDEF_GPB)
    check("Classic S1 trailer KeyB", t1[10:16], KEY_FFFFFF)
    # TLV は sector1 block4 から始まる(03 <len> <ndef> fe)
    check("Classic TLV 先頭 03", blocks[4][0], 0x03)
    check("Classic TLV len", blocks[4][1], len(ndef))
    # TLV を全データブロックから復元して往復一致
    recovered = bytearray()
    for sector in range(1, 16):
        base = sector * 4
        for d in range(3):
            recovered += blocks[base + d]
    check("Classic TLV 往復抽出", extract_type2_ndef(bytes(recovered)), ndef)
    # 全 NDEF セクタ(1..15)の trailer が D3F7 キーであること
    all_ndef_trailers = all(blocks[s * 4 + 3][0:6] == KEY_NDEF_A for s in range(1, 16))
    check("Classic 全NDEF trailer KeyA=D3F7", all_ndef_trailers, True)

    # --- SAK / ATR / reader 分類 ---
    check("SAK 08 => classic", classify_tag_from_sak(0x08), TAG_CLASSIC)
    check("SAK 00 => type2", classify_tag_from_sak(0x00), TAG_TYPE2)
    check("SAK 20 => type4", classify_tag_from_sak(0x20), TAG_TYPE4)
    check("SAK 99 => unknown", classify_tag_from_sak(0x99), TAG_UNKNOWN)

    # ATR: Classic 1K(name 00 01)
    atr_classic = bytes([0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C,
                         0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
                         0x00, 0x00, 0x00, 0x00, 0x6A])
    check("ATR Classic1K => classic", classify_tag_from_atr(atr_classic), TAG_CLASSIC)
    atr_ul = bytes([0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C,
                    0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
                    0x00, 0x00, 0x00, 0x00, 0x68])
    check("ATR Ultralight => type2", classify_tag_from_atr(atr_ul), TAG_TYPE2)

    # --- reader 名 -> family(実機で現れる PC/SC 名を網羅)---
    # 実際の PCSC.framework は "<vendor> <model> [interface] NN" 形式の名前を返す。
    _READER_CASES = [
        # PN53x 系(MIFARE Classic 可)
        ("ACS ACR122U PICC Interface",           READER_NXP),
        ("ACS ACR122U",                          READER_NXP),
        ("ACR122",                               READER_NXP),
        ("ACS ACR1222L Dual Reader PICC",        READER_NXP),
        ("ACS ACR1281U-C1 PICC",                 READER_NXP),
        ("SCM Microsystems Inc. SCL3711 reader", READER_NXP),
        ("Touchatag USB reader 00 00",           READER_NXP),
        ("NXP PN532 contactless",                READER_NXP),  # PN532 が最優先で nxp
        ("Some Vendor PN533 board",              READER_NXP),
        ("Generic PN53x device",                 READER_NXP),
        # 汎用 Type-A CCID(Classic 不可 / Type2・Type4 可)
        ("ACS ACR1252U USB NFC Reader",          READER_GENERIC),
        ("ACS ACR1255U-J1 PICC",                 READER_GENERIC),
        ("Identiv uTrust 3700 F CL Reader",      READER_GENERIC),
        ("uTrust 3700 F",                        READER_GENERIC),
        ("HID Global OMNIKEY 5022 Smartcard",    READER_GENERIC),
        ("HID OMNIKEY 5422",                     READER_GENERIC),
        ("Gemalto PC Twin Reader",               READER_GENERIC),
        ("Thales PC Twin Reader 00",             READER_GENERIC),
        ("Generic USB Contactless CCID Reader",  READER_GENERIC),
        # FeliCa 系(検出のみ)
        ("Sony FeliCa Port/PaSoRi 3.0",          READER_FELICA),
        ("SONY RC-S300",                         READER_FELICA),
        ("Sony RC-S380/P",                       READER_FELICA),
        ("SONY FeliCa RC-S380",                  READER_FELICA),
        ("SONY Felica Port RC-S330",             READER_FELICA),
        ("PaSoRi RC-S380",                       READER_FELICA),
        # 未分類
        ("Foobar Widget 3000",                   READER_UNKNOWN),
        ("Unknown Smartcard Reader",             READER_UNKNOWN),
        ("",                                     READER_UNKNOWN),
    ]
    for nm, fam in _READER_CASES:
        check("reader %r => %s" % (nm, fam), classify_reader(nm), fam)
    # 大小文字を無視する(substring, case-insensitive)
    check("reader 小文字 acr122u => nxp", classify_reader("acs acr122u picc"), READER_NXP)
    check("reader 小文字 rc-s300 => felica", classify_reader("sony rc-s300"), READER_FELICA)
    # ラベルが family ごとに用意されていること(空でない)
    for fam in (READER_NXP, READER_GENERIC, READER_FELICA, READER_UNKNOWN):
        check("reader label %s 非空" % fam, bool(reader_family_label(fam)), True)

    # --- capability matrix(family × tag を全網羅)---
    # 期待表: MIFARE Classic は PN53x(nxp)のみ。Type2/Type4 は nxp/generic。FeliCa は全滅。
    _CAP_CASES = {
        (READER_NXP,     TAG_CLASSIC): "ok",  (READER_NXP,     TAG_TYPE2): "exp",
        (READER_NXP,     TAG_TYPE4):   "exp", (READER_NXP,     TAG_FELICA): "no",
        (READER_GENERIC, TAG_CLASSIC): "no",  (READER_GENERIC, TAG_TYPE2): "exp",
        (READER_GENERIC, TAG_TYPE4):   "exp", (READER_GENERIC, TAG_FELICA): "no",
        (READER_FELICA,  TAG_CLASSIC): "no",  (READER_FELICA,  TAG_TYPE2): "no",
        (READER_FELICA,  TAG_TYPE4):   "no",  (READER_FELICA,  TAG_FELICA): "no",
        (READER_UNKNOWN, TAG_CLASSIC): "no",  (READER_UNKNOWN, TAG_TYPE2): "no",
        (READER_UNKNOWN, TAG_TYPE4):   "no",  (READER_UNKNOWN, TAG_FELICA): "no",
    }
    for (fam, tag), exp in _CAP_CASES.items():
        check("cap %s×%s=%s" % (fam, tag, exp), capability(fam, tag), exp)
    # 核となるルール: MIFARE Classic は PN53x 系だけが "ok"。
    check("Classic は nxp のみ ok",
          [f for f in (READER_NXP, READER_GENERIC, READER_FELICA, READER_UNKNOWN)
           if capability(f, TAG_CLASSIC) == "ok"],
          [READER_NXP])

    # --- INCOMPAT メッセージ(family に応じて WHY/WHAT を出し分ける)---
    # Classic を汎用/FeliCa リーダーで → Crypto1/PN53x の説明が入る。
    msg_cg = incompat_message(TAG_CLASSIC, READER_GENERIC)
    check("INCOMPAT classic×generic に Crypto1", "Crypto1" in msg_cg, True)
    check("INCOMPAT classic×generic に PN53x", "PN53x" in msg_cg, True)
    msg_cf = incompat_message(TAG_CLASSIC, READER_FELICA)
    check("INCOMPAT classic×felica に PaSoRi 言及", "PaSoRi" in msg_cf, True)
    # Type2/Type4 を FeliCa リーダーで → Type-A が要る旨。
    check("INCOMPAT type2×felica に Type-A", "Type-A" in incompat_message(TAG_TYPE2, READER_FELICA), True)
    check("INCOMPAT type4×felica に Type-A", "Type-A" in incompat_message(TAG_TYPE4, READER_FELICA), True)
    # FeliCa タグは全リーダーで書込非対応の案内。
    check("INCOMPAT felica に NTAG 案内", "NTAG" in incompat_message(TAG_FELICA), True)
    # family 未指定でも汎用文面が返る(空でない)。
    for tag in (TAG_CLASSIC, TAG_TYPE2, TAG_TYPE4, TAG_FELICA, TAG_UNKNOWN):
        check("INCOMPAT %s 汎用文面 非空" % tag, bool(incompat_message(tag)), True)

    # --- リーダー選択の優先度(_pick_reader)---
    pick_name, pick_fam = _pick_reader(
        ["SONY RC-S300", "Generic USB Contactless CCID Reader", "ACS ACR122U"])
    check("_pick_reader は PN53x を最優先", pick_fam, READER_NXP)
    pick_name2, pick_fam2 = _pick_reader(["SONY RC-S300", "ACS ACR1252U"])
    check("_pick_reader 汎用 > FeliCa", pick_fam2, READER_GENERIC)
    check("_pick_reader 空は (None,None)", _pick_reader([]), (None, None))

    # --- APDU ビルダ(class 0xFF)---
    check("APDU get UID", apdu_get_uid().hex(), "ffca000000")
    check("APDU load key", apdu_load_key(0x00, KEY_FFFFFF).hex(), "ff820000" + "06" + "ffffffffffff")
    check("APDU auth block4 KeyA", apdu_auth(0x04, KEYTYPE_A, 0x00).hex(), "ff8600000501000460" + "00")
    check("APDU read block4", apdu_read(0x04, 16).hex(), "ffb0000410")
    check("APDU write block4", apdu_write(0x04, bytes(16)).hex(), "ffd6000410" + "00" * 16)
    check("SW 9000 => ok", sw_ok(bytes([0x00, 0x90, 0x00])), True)
    check("SW 6300 => not ok", sw_ok(bytes([0x63, 0x00])), False)

    # --- detect_tag_live: 鍵候補プローブ(ハードウェア不要のフェイクカード)---
    SW_OK = bytes([0x90, 0x00])
    SW_FAIL = bytes([0x63, 0x00])

    class _FakeCard(object):
        """.transmit(apdu) だけを持つ最小のフェイク。

        auth_ok(key6) が True を返す KeyA 認証だけ 9000、その他は 6300。
        page3_ok=True なら apdu_read(block=3) に 9000(Type2 相当)。
        """
        def __init__(self, uid, auth_ok, page3_ok=False):
            self.uid = bytes(uid)
            self.auth_ok = auth_ok
            self.page3_ok = page3_ok
            self.loaded_key = None

        def transmit(self, apdu):
            apdu = bytes(apdu)
            if apdu == apdu_get_uid():                       # FF CA 00 00 00
                return self.uid + SW_OK
            if apdu[:4] == bytes([0xFF, 0x82, 0x00, 0x00]):  # load key -> slot0
                self.loaded_key = apdu[5:11]
                return SW_OK
            if apdu[:2] == bytes([0xFF, 0x86]):              # general auth
                if self.loaded_key is not None and self.auth_ok(self.loaded_key):
                    return SW_OK
                return SW_FAIL
            if apdu[:2] == bytes([0xFF, 0xB0]):              # read binary
                if self.page3_ok and apdu[3] == 0x03:
                    return bytes(16) + SW_OK
                return SW_FAIL
            return SW_FAIL

    # NDEF フォーマット済み Classic: FF は失敗、A0A1(MAD)/D3F7 で成功 -> classic
    fmt_classic = _FakeCard(
        bytes([0x16, 0x96, 0x56, 0x80]),
        lambda k: k in (KEY_MAD_A, KEY_NDEF_A))
    check("detect_tag_live: NDEF済Classic => classic",
          detect_tag_live(fmt_classic)[0], TAG_CLASSIC)

    # 未フォーマット(工場出荷)Classic: FF で auth 成功 -> classic
    blank_classic = _FakeCard(
        bytes([0x04, 0x11, 0x22, 0x33]),
        lambda k: k == KEY_FFFFFF)
    check("detect_tag_live: 出荷時Classic => classic",
          detect_tag_live(blank_classic)[0], TAG_CLASSIC)

    # Type2 (NTAG): auth は全て失敗、page3 の読取りだけ成功 -> type2
    type2 = _FakeCard(
        bytes([0x04, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
        lambda k: False, page3_ok=True)
    check("detect_tag_live: NTAG => type2",
          detect_tag_live(type2)[0], TAG_TYPE2)

    print()
    if fails == 0:
        ok("セルフテスト: 全項目 PASS")
        return 0
    fail("セルフテスト: %d 件 FAIL" % fails)
    return 1


# ═════════════════════════════════════════════════════════════════════════════
#  main
# ═════════════════════════════════════════════════════════════════════════════

def usage():
    print(__doc__ or "")


def main(argv):
    if len(argv) < 2:
        usage()
        return 2
    cmd = argv[1]
    if cmd == "--self-test":
        return run_self_test()
    if cmd == "--detect":
        return cmd_detect()
    if cmd == "--read":
        return cmd_read()
    if cmd == "--print-ndef":
        url = os.environ.get("TARGET_URL", TARGET_URL_DEFAULT)
        return cmd_print_ndef(url)
    if cmd in ("--write", "--format"):
        # --format は Classic の format+write を内包する cmd_write に委ねる
        # (libnfc backend の --format と同じ「初期化してから書き込み」意味)。
        url = argv[2] if len(argv) > 2 else os.environ.get("TARGET_URL", TARGET_URL_DEFAULT)
        return cmd_write(url)
    if cmd in ("--help", "-h"):
        usage()
        return 0
    fail("不明なコマンド: %s" % cmd)
    usage()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
