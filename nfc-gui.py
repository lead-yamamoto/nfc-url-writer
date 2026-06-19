#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nfc-gui.py — write-url.sh をブラウザから操作するローカル Web GUI。

標準ライブラリのみで動作(追加インストール不要)。127.0.0.1 のみで待ち受けます。
中身の処理はすべて同じフォルダの write-url.sh を呼び出します。

起動:
    python3 nfc-gui.py
    (通常は nfc-gui.command をダブルクリック)
"""
import http.server
import socketserver
import json
import os
import re
import subprocess
import threading
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "write-url.sh")
HOST = "127.0.0.1"
PORT_RANGE = range(8765, 8786)

# write-url.sh / 各ツールが見つかるよう Homebrew の bin を PATH に足す
EXTRA_PATH = "/opt/homebrew/bin:/usr/local/bin"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
URL_BAD = set('"\\`$\n\r\t')


def current_url():
    """write-url.sh の TARGET_URL の現在値を読む。"""
    try:
        with open(SCRIPT, encoding="utf-8") as f:
            for line in f:
                m = re.match(r'^TARGET_URL="(.*)"\s*$', line)
                if m:
                    v = m.group(1)
                    m2 = re.match(r'^\$\{TARGET_URL:-(.*)\}$', v)
                    return m2.group(1) if m2 else v
    except OSError:
        pass
    return "https://example.com"


# URL はファイルを書き換えず、実行時に TARGET_URL 環境変数で write-url.sh に渡します。


def run_script(args, env_extra=None):
    env = dict(os.environ)
    env["PATH"] = EXTRA_PATH + ":" + env.get("PATH", "")
    env["TERM"] = "dumb"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        ["/bin/bash", SCRIPT, *args],
        cwd=HERE, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True,
    )
    return proc.returncode, ANSI_RE.sub("", proc.stdout or "")


def run_fix_reader():
    """macOS のスマートカードデーモンを無効化(GUI のパスワードダイアログで認証)。"""
    inner = (
        "launchctl bootout system/com.apple.ifdreader; "
        "launchctl disable system/com.apple.ifdreader; "
        "launchctl bootout system/com.apple.usbsmartcardreaderd; "
        "launchctl disable system/com.apple.usbsmartcardreaderd; true"
    )
    proc = subprocess.run(
        ["osascript", "-e",
         'do shell script "%s" with administrator privileges' % inner],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    msg = ANSI_RE.sub("", proc.stdout or "")
    if proc.returncode == 0:
        msg += ("macOS のスマートカードデーモンを無効化しました。\n"
                "→ ACR122U を一度抜き差ししてから、もう一度操作してください。")
    return proc.returncode, msg


def handle_run(action, url):
    url = (url or "").strip()
    if action in ("write", "format"):
        if not url:
            raise ValueError("URL が空です。")
        if len(url) > 600:
            raise ValueError("URL が長すぎます。")
        flags = ["--format", "--yes"] if action == "format" else ["--yes"]
        return run_script(flags, {"TARGET_URL": url})
    if action == "read":
        return run_script(["--read", "--yes"])
    if action == "fix":
        return run_fix_reader()
    raise ValueError("不明な操作: %s" % action)


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html") or self.path.startswith("/?"):
            self._send(200, "text/html; charset=utf-8",
                       PAGE.replace("__URL__", html_escape(current_url())))
        elif self.path == "/api/config":
            self._send(200, "application/json",
                       json.dumps({"url": current_url()}))
        else:
            self._send(404, "text/plain; charset=utf-8", "not found")

    def do_POST(self):
        if self.path != "/api/run":
            self._send(404, "text/plain; charset=utf-8", "not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(length) or b"{}")
            rc, out = handle_run(data.get("action", ""), data.get("url", ""))
            self._send(200, "application/json",
                       json.dumps({"ok": rc == 0, "rc": rc, "output": out}))
        except Exception as e:  # noqa: BLE001 — どんな失敗もログに出して返す
            self._send(200, "application/json",
                       json.dumps({"ok": False, "rc": -1, "output": "エラー: %s" % e}))

    def log_message(self, *args):
        pass  # アクセスログは抑制


def html_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


PAGE = """<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NFC URL Writer</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif;
         margin: 0; padding: 24px; background: Canvas; color: CanvasText;
         display: flex; justify-content: center; }
  .card { width: 100%; max-width: 640px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { opacity: .6; font-size: 13px; margin: 0 0 16px; }
  .warn { background: #fff7e0; color: #6b4e00; border: 1px solid #e9cf7a;
          border-radius: 10px; padding: 10px 14px; font-size: 13px; line-height: 1.5;
          margin-bottom: 18px; }
  @media (prefers-color-scheme: dark) {
    .warn { background: #332b12; color: #f4d77a; border-color: #6b551f; }
  }
  label { font-size: 13px; font-weight: 600; display: block; margin-bottom: 6px; }
  input[type=text] { width: 100%; font-size: 16px; padding: 12px 14px;
        border: 1px solid GrayText; border-radius: 10px; background: Field; color: FieldText; }
  .row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 16px; }
  button { font-size: 15px; font-weight: 600; padding: 13px 12px; border: 0;
        border-radius: 10px; cursor: pointer; color: #fff; }
  button:disabled { opacity: .45; cursor: progress; }
  .b-write  { background: #0a7d33; }
  .b-format { background: #1769d6; }
  .b-read   { background: #555; }
  .b-fix    { background: #9a5b00; }
  .status { margin: 16px 0 8px; min-height: 22px; }
  .pill { display: inline-block; padding: 3px 12px; border-radius: 999px;
          font-size: 13px; font-weight: 600; }
  .pill.busy { background: #ddd; color: #333; }
  .pill.ok  { background: #0a7d33; color: #fff; }
  .pill.err { background: #c0392b; color: #fff; }
  pre#log { background: #11131a; color: #d6e2ff; border-radius: 10px;
        padding: 14px; font-size: 12.5px; line-height: 1.5; overflow: auto;
        max-height: 360px; white-space: pre-wrap; word-break: break-word; }
  .foot { opacity: .55; font-size: 12px; margin-top: 14px; }
</style>
</head>
<body>
  <div class="card">
    <h1>NFC URL Writer</h1>
    <p class="sub">ACR122U + MIFARE Classic 1K に NDEF URL を書き込みます。</p>

    <div class="warn">
      <b>iPhone での読み取りについて:</b> MIFARE Classic は NFC Forum 標準タグではないため、
      iPhone（iOS Core NFC）は基本的に読み取れません。iPhone で確実に読ませるには
      <b>NTAG213/215/216</b> を使ってください。Android の多くは読み取り可能です。
    </div>

    <label for="url">書き込む URL</label>
    <input type="text" id="url" value="__URL__" placeholder="https://example.com"
           autocomplete="off" spellcheck="false">

    <div class="row">
      <button class="b-write"  onclick="run('write')">書き込む</button>
      <button class="b-format" onclick="run('format')">初回（フォーマット込み）</button>
      <button class="b-read"   onclick="run('read')">読み取り検証</button>
      <button class="b-fix"    onclick="run('fix')">リーダー解放</button>
    </div>

    <div class="status"><span id="status" class="pill"></span></div>
    <pre id="log">カードをリーダーに置き、操作を選んでください。

・初めてのカード … 「初回（フォーマット込み）」
・2回目以降       … 「書き込む」
・確認だけ        … 「読み取り検証」（カードは変更しません）
・リーダーが認識されない … 「リーダー解放」（パスワードを求められます→抜き差し）</pre>

    <p class="foot">サーバーは http://127.0.0.1 で動作中。終了するにはこのページを起動した
       ターミナルで Ctrl+C を押してください（ブラウザを閉じても止まりません）。</p>
  </div>

<script>
const $ = (id) => document.getElementById(id);
const buttons = () => Array.from(document.querySelectorAll('button'));

async function run(action) {
  const url = $('url').value.trim();
  if ((action === 'write' || action === 'format') && !url) {
    alert('URL を入力してください。');
    return;
  }
  buttons().forEach(b => b.disabled = true);
  $('status').className = 'pill busy';
  $('status').textContent = '実行中…';
  $('log').textContent = '実行中… カードをリーダーから動かさないでください。';
  try {
    const res = await fetch('/api/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, url }),
    });
    const j = await res.json();
    $('log').textContent = j.output || '(出力なし)';
    $('status').className = 'pill ' + (j.ok ? 'ok' : 'err');
    $('status').textContent = j.ok ? '成功 ✓' : '失敗 ✗';
  } catch (e) {
    $('log').textContent = '通信エラー: ' + e;
    $('status').className = 'pill err';
    $('status').textContent = '失敗 ✗';
  } finally {
    buttons().forEach(b => b.disabled = false);
  }
}
</script>
</body>
</html>"""


def main():
    os.chdir(HERE)
    httpd = port = None
    last = None
    for p in PORT_RANGE:
        try:
            httpd = Server((HOST, p), Handler)
            port = p
            break
        except OSError as e:
            last = e
    if httpd is None:
        raise SystemExit("ポートを確保できませんでした: %s" % last)

    url = "http://%s:%d/" % (HOST, port)
    print("=" * 56)
    print(" NFC URL Writer GUI")
    print(" %s" % url)
    print(" ブラウザが自動で開きます。終了は Ctrl+C。")
    print("=" * 56)
    if not os.environ.get("NFC_GUI_NO_BROWSER"):
        threading.Timer(0.7, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n終了しました。")


if __name__ == "__main__":
    main()
