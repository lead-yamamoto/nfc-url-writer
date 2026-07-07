# v0.3.6 — PC/SC バックエンド改善（Stage 1b + Phase 2、いずれも opt-in/dark）

**既定の動作は一切変わりません。** これまでどおり libnfc/libfreefare で MIFARE Classic /
NTAG に書き込みます。この版の変更はすべて、環境変数 `NFC_BACKEND=pcsc` を明示したときだけ
使われる**実験的な PC/SC バックエンド（`nfc-core.py`）**の中身です。

## 変更点

### MIFARE Classic 読み取り（PC/SC）の修正 — Stage 1b
- NDEF フォーマット済みカードを正しく読めるように修正：
  - MAD（セクタ0）を読んで NDEF セクタを特定するように変更（以前は無視していた）。
  - 認証キーを **D3F7（NDEF）/ A0A1（MAD）/ FF（工場出荷）** の順で試すように拡張。
  - 認証できないセクタで**中断せずスキップ**するように修正（以前は最初の失敗で読み取り全体が打ち切られていた）。
- 実機（ACR122U）で、本物の NDEF フォーマット済み Classic 1K から URL を PC/SC 経由で
  正しく読み出せることを確認済み。

### 対応リーダーの拡大 — Phase 2
- リーダー名の分類を大幅に拡張（case-insensitive 部分一致）：
  - **PN53x 系**（ACR122U/ACR1281/SCL3711 等、MIFARE Classic の Crypto1 可）
  - **汎用 Type-A CCID**（ACR1252/OMNIKEY/uTrust 等、NTAG/Type4 可・Classic 不可）
  - **Sony FeliCa 系**（RC-S300/RC-S380/PaSoRi、検出のみ）
- リーダー × タグの能力マトリクスと、非対応時の日本語ガイダンス（`INCOMPAT:`）を整備。
  例：FeliCa 専用リーダーに Classic を載せた場合、「Crypto1 認証が必要で PN53x 系が要る」
  と具体的に案内。

### タグ判定の修正
- `detect_tag_live` が **NDEF フォーマット済み Classic を type4 と誤判定**していた不具合を修正
  （FF キーでしか認証を試していなかった → NDEF キーも試すように変更）。

### その他
- ロードマップを `docs/ROADMAP.md` として追加（Phase 1 コア → Phase 5 DESFire/FeliCa）。
- `nfc-core.py --self-test`（ハードウェア非依存の自己テスト）は全項目 PASS。

## 既知の問題 / なぜ opt-in のままか
- **ACR122U が macOS の PC/SC から時々ドロップする**（`READER: NONE` になり、USB の
  抜き差しが必要）現象を確認。既定の libnfc バックエンドは libusb を直接使うため影響を
  受けません。この安定性の問題が解決するまで、PC/SC は既定にせず opt-in のままにします。
- PC/SC 経由の **書き込み**往復は、上記のドロップにより実機での連続実行がまだ取れていません
  （書き込み経路のコード自体は静的監査済みで、セクタトレーラのアクセスビットは NFC Forum
  標準値のためカードをブリックしません）。
