#!/bin/bash
# nfc-gui.command — ダブルクリックでローカル Web GUI を起動する。
# Finder でこのファイルをダブルクリックすると Terminal が開き、サーバーが起動して
# 既定のブラウザに操作画面が開きます。終了はこのウインドウで Ctrl+C。
cd "$(dirname "$0")" || exit 1
for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
  if command -v "$py" >/dev/null 2>&1; then
    exec "$py" nfc-gui.py
  fi
done
echo "python3 が見つかりません。'brew install python' などで導入してください。"
echo "Enter キーで閉じます。"
read -r _
