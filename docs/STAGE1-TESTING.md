# Stage 1: PC/SC backend — ベンチテスト手順(実機検証ガイド)

このドキュメントは、`nfc-core.py`(PC/SC 経由の NFC 読み書きエンジン)を実機で検証するための手順書です。
Stage 1a(コード実装)は完了していますが、**実機での動作確認はまだ行われていません**。
このガイドは、ACR122U・MIFARE Classic 1K カード・NTAG・iPhone が揃ったときに実施してください。

## これは何か(現状の説明)

- `write-url.sh` は今までどおり **libnfc/libfreefare** を使って動作します。これは変わりません。
  出荷版のデフォルト動作は 100% 従来どおりです。
- `nfc-core.py` は新しい **PC/SC(PCSC.framework)経由のエンジン**です。macOS 標準の PCSC.framework を
  Python の `ctypes` から直接叩くことで、libnfc に依存せず NFC リーダーと通信します。
- この新エンジンは **既定では一切使われません(ダーク出荷)**。環境変数 `NFC_BACKEND=pcsc` を
  明示的に指定した場合のみ、`write-url.sh` の `--detect` / `--read` / `--write` / `--format` /
  `--print-ndef` が `nfc-core.py` に処理を委譲します。指定しなければ何も変わりません。
- 現時点でこのバックエンドを実機で試したユーザーはいません(このリポジトリの開発機に
  NFC リーダーが接続されていないため)。すべての検証はコード読み・バイト列レベルの
  自己テストのみで行われています。

## 前提条件(ベンチ環境)

- ACR122U(または PCSC.framework 対応の USB NFC リーダー)
- MIFARE Classic 1K カード(空、または上書き可能なテスト用)
- NTAG213/215/216 などの Type2 タグ(空、または上書き可能なテスト用)
- iPhone(NDEF タグの読み取り確認用。標準カメラ/バックグラウンドタグ読み取りで可)
- macOS 開発機(このリポジトリ)、Python3(標準ライブラリのみで動作、追加インストール不要)

## 手順

### 0. デーモンの状態確認

PC/SC backend は macOS のスマートカードデーモン(`com.apple.ifdreader` /
`com.apple.usbsmartcardreaderd`)が **有効**になっている必要があります。
libnfc backend 用に `--fix-reader` で無効化していた場合は、先に有効化してください。

```bash
./write-url.sh --enable-reader
```

(逆に libnfc backend に戻す場合は `./write-url.sh --fix-reader` で無効化)

### 1. リーダー検出

ACR122U を接続し、以下を実行:

```bash
NFC_BACKEND=pcsc ./write-url.sh --detect
```

期待される結果:
- `READER: ACR122U` のように接続したリーダー名が表示される(`READER: NONE` ではないこと)。
- カードを乗せていなければ `TAG: none`。

### 2. MIFARE Classic 1K への書き込みと読み戻し

```bash
# フォーマットしてから書き込み(初期化 + NDEF 書き込み)
NFC_BACKEND=pcsc ./write-url.sh --format

# 書き込んだ内容を読み戻す
NFC_BACKEND=pcsc ./write-url.sh --read
```

期待される結果:
- `--format` が成功し、書き込み成功のトースト/ログが出る。
- `--read` で書き込んだ URL(既定 `TARGET_URL=https://example.com/`)が正しく読み出される。

### 3. libnfc backend との byte-for-byte 比較

同じカード(または同型の別カード)に対して、libnfc backend(既定)でも同じ URL を書き込み、
両者の生成する NDEF バイト列が一致することを確認します。

```bash
# libnfc backend(既定)での参照バイト列
./write-url.sh --print-ndef

# PC/SC backend での参照バイト列(バックエンド間で一致するはず)
NFC_BACKEND=pcsc ./write-url.sh --print-ndef
```

両者の出力(16進 NDEF バイト列)が完全一致することを確認してください。
一致すれば、フォーマット/エンコードロジックの等価性が実機データでも裏付けられます。

さらに、実際にカードに書き込んだ後の生バイト(可能であれば `nfc-mfclassic` などで dump)を
`nfc-core.py --read` の出力と突き合わせ、両エンジンが同一カードから同一 URL を読み出せることを
確認してください。

### 4. NTAG (Type2) への書き込みと iPhone での確認

```bash
NFC_BACKEND=pcsc ./write-url.sh --write
```

書き込み成功後、NTAG を iPhone にかざします(バックグラウンドタグ読み取り、または
対応アプリ経由)。期待される結果:
- iPhone 側で通知が表示され、書き込んだ URL(既定 `https://example.com/`)を開ける。
- NTAG の lock/OTP/CFG ページが書き込み前後で変化していないこと(`nfc-core.py` の
  read-modify-write ロジックがテール保持することの実機確認)。

### 5. 非対応の組み合わせ(INCOMPAT)の確認

FeliCa 対応リーダー(例: RC-S300/PaSoRi)や、Crypto1 非対応の汎用リーダーで
MIFARE Classic カードを試し、`INCOMPAT: <tagtype>|<日本語説明>` が正しく出力され、
Swift アプリ側で赤いトースト(該当する日本語ガイダンス)が表示されることを確認します。

```bash
NFC_BACKEND=pcsc ./write-url.sh --detect
```

### 6. リーダー競合(SHARING_VIOLATION)の確認

macOS の `ifdreader` が既にリーダーを掴んでいる状態(例: 他のスマートカードアプリが起動中)で
`NFC_BACKEND=pcsc` を実行し、"reader busy" 相当のエラーメッセージが分かりやすく表示され、
クラッシュしないことを確認します。

## チェックリスト(ベンチゲート)

- [ ] `NFC_BACKEND=pcsc ./write-url.sh --detect` が実リーダー名を表示する
- [ ] MIFARE Classic 1K への `--format` → 書き込み成功
- [ ] 同カードの `--read` で書き込んだ URL が正しく読み出せる
- [ ] libnfc backend と PC/SC backend の `--print-ndef` バイト列が一致する
- [ ] 実カードの dump 比較でも両エンジンが同一データを読み書きできる
- [ ] NTAG への書き込み後、iPhone で URL を開ける
- [ ] NTAG の lock/OTP/CFG ページが書き込み前後で不変
- [ ] 非対応リーダー×タグの組み合わせで `INCOMPAT:` が出て、アプリに赤トーストが出る
- [ ] リーダー競合時にクラッシュせず分かりやすいエラーになる
- [ ] `--enable-reader` / `--fix-reader` の切り替えが実機で機能する

全項目がチェックできて初めて Stage 1 は「実機で証明された」と言えます。

## 既定バックエンドを pcsc に切り替える方法(まだ実施しないこと)

上記チェックリストがすべて実機で確認できたら、`write-url.sh` の

```bash
NFC_BACKEND="${NFC_BACKEND:-libnfc}"
```

の既定値を `libnfc` から `pcsc` に変更することで、PC/SC backend をデフォルトにできます。
変更後は、既存ユーザーへの影響が大きいため、バージョンを上げてリリースノートに明記し、
GitHub リリース/タグを作成してください。

**現時点ではこの切り替えを行いません。** ベンチ実機検証が完了するまで、
既定は `libnfc` のまま維持します(Stage 1a はハードウェア上で未証明のため)。
