# PC/SC 移行ロードマップ（v0.4 core → v1.0）

libnfc/libfreefare 依存をやめ、macOS 標準の **PC/SC（PCSC.framework）** 経由で NFC を
読み書きする新エンジン `nfc-core.py` へ段階的に移行する計画。各フェーズは
「コード実装 → 実機ベンチゲート」の2段で進め、**全ゲート通過まで既定は libnfc のまま**。

## Phase 1 — PC/SC コアエンジン（進行中）
libnfc を使わず PC/SC 疑似 APDU（FF CA/82/86/B0/D6）で ACR122U と通信する土台。
- 対象タグ: MIFARE Classic 1K、NTAG/Type2。
- 成果物: `nfc-core.py`（純標準ライブラリ・ctypes、追加インストール不要、ダーク出荷）。
- ステータス:
  - [x] コード実装（Stage 1a）: NDEF/TLV、Classic/Type2 イメージ生成、PC/SC 転送、
        リーダー分類・能力マトリクス・INCOMPAT、self-test 全項目 PASS。
  - [x] 実機: PC/SC で ACR122U 認識、`--detect` でリーダー＋タグ判定。
  - [x] 実機: Classic **読み取り**のバグ（MAD 未読・鍵候補不足・中断）を発見＆修正、
        シミュレーションで URL 復元確認。
  - [ ] 実機: Classic **書き込み→読み戻し（往復）** ← 最後のゲート（リーダー再接続待ち）。
  - [ ] `docs/STAGE1-TESTING.md` のチェックリスト残項目（byte 一致、NTAG→iPhone、INCOMPAT 実機）。

## Phase 2 — 対応リーダーの拡大（reader breadth）
「ACR122U 専用」から「PC/SC 対応リーダー全般」へ。
- リーダー名の分類を拡張（ACR122U 系 / ACR1252 等の NXP系 CCID / 汎用 Type-A CCID /
  Sony RC-S300・RC-S380・PaSoRi の FeliCa 系 / 不明）。
- 能力マトリクスを family × tag で厳密化:
  - MIFARE Classic（Crypto1）は **PN53x 系（ACR122U 等）でのみ**可。
  - Type2/Type4（ISO14443A 標準 APDU）は **Type-A 対応 CCID 全般**で可。
  - FeliCa は検出のみ（NDEF 書き込みは Phase 5 まで非対応）。
- 非対応の組合せに正確な日本語 INCOMPAT ガイダンス。
- リーダー名 → family、ATR → tag の分類を **self-test（ハードウェア不要）**で網羅。

## Phase 3 — NDEF レコード種別の拡張
URI 以外（テキスト、複数レコード、必要なら Wi‑Fi/連絡先ハンドオーバ等）に対応。

## Phase 4 — ISO15693（NFC-V）タグ対応
NFC-V 系タグの読み書き（PC/SC 経由）。

## Phase 5 — DESFire(Type4) / FeliCa の本格対応 → v1.0
DESFire の実書き込み、FeliCa NDEF 対応、既定バックエンドを pcsc へ切替。

---
※ このロードマップは会話で合意した内容を文書化したもの。優先度・範囲は随時見直す。
