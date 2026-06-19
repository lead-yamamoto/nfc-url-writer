<div align="center">

<img src="assets/icon.png" alt="NFC URL Writer app icon" width="120" />

# NFC URL Writer

**Write an NDEF URL to a MIFARE Classic 1K card on macOS — in one click.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-black.svg?logo=apple)](#requirements)
[![Built with Swift](https://img.shields.io/badge/built%20with-Swift-fa7343.svg?logo=swift&logoColor=white)](#building-from-source)
[![Powered by libnfc](https://img.shields.io/badge/powered%20by-libnfc%20%2B%20libfreefare-0a7ea4.svg)](#how-it-works)
[![Reader: ACR122U](https://img.shields.io/badge/reader-ACR122U-555.svg)](#requirements)

Getting an ACR122U talking to `libnfc` on a modern Mac is famously fiddly. This tool makes it boring: plug in the reader, type a URL, click **Write**.

</div>

---

## What it does

NFC URL Writer programs a **URL into a MIFARE Classic 1K card** as a standard **NDEF URI record**, using an **ACR122U** USB reader on **macOS**. Tap the card with a phone afterward and it opens the URL.

It ships in three forms, all driving the **same core script** (`write-url.sh`):

1. A native, universal **SwiftUI `.app`** with one-click buttons and a built-in dependency installer.
2. A **CLI** (`write-url.sh`) for scripting and automation.
3. A **stdlib-only local web GUI** (`nfc-gui.py`) that runs in your browser.

## Why this exists

If you have ever tried to use an ACR122U with `libnfc` on macOS, you know the pain: the reader plugs in, but nothing can open it. The culprit is macOS's own smart-card stack — the `com.apple.ifdreader` CryptoTokenKit daemon — which **claims the USB device** before `libnfc` ever gets a chance.

The usual fix is a cryptic dance with `launchctl bootout` / `disable` followed by a physical re-plug. This tool **automates that fix** behind a single **Fix reader** button (or `--fix-reader`), so you can stop reading Stack Overflow threads and start writing cards.

## Features

- **Three interfaces, one engine** — native app, CLI, and a local web GUI, all calling the same audited `write-url.sh`.
- **One-click setup** — the app detects whether `libnfc` / `libfreefare` are present and **installs them via Homebrew on first run** (with live progress), so non-technical users can get going without touching a terminal.
- **One-click reader fix** — automates the `com.apple.ifdreader` `launchctl` workaround that trips up nearly everyone on macOS.
- **Safe by design** — never edits sector trailers, keys, or access bits directly. It hands the NDEF message to `libfreefare`, which manages the MAD, TLV, and NFC-Forum keys correctly.
- **Backup before write** — dumps the card to a timestamped `.mfd` file before making any changes.
- **Verify after write** — reads the card back and compares it against what was written, so a "success" actually means success.
- **Universal binary** — builds for both Apple Silicon (`arm64`) and Intel (`x86_64`).

## Screenshots

> **Tip:** a screenshot or short GIF here is the single biggest thing you can do for stars.
> Capture the app window (`⌘⇧4` → `Space` → click the window), save it as `assets/screenshot.png`,
> then add `![NFC URL Writer](assets/screenshot.png)` to this section.

## Requirements

- **macOS** (Apple Silicon or Intel).
- **[Homebrew](https://brew.sh)** — the app can install it for you if it is missing.
- **`libnfc` + `libfreefare`** — installed via Homebrew (the app installs them on first run).
- **Hardware:** an **ACR122U** USB NFC reader and one or more **MIFARE Classic 1K** cards.

> `libnfc` and `libfreefare` are **not bundled** — they are installed through Homebrew. See [License](#license).

## Install & Quickstart

### Easiest: the app

1. **[Download `NFC URL Writer.app`](https://github.com/lead-yamamoto/nfc-url-writer/releases/latest)** (or [build from source](#building-from-source)).
2. Open it. On first run, if the NFC tools are missing, click **Install required tools** — the app runs `brew install libnfc libfreefare` for you.
3. Plug in the ACR122U, place a card on it, type your URL, and click **Write**.

### Or install the dependencies yourself

```bash
brew install libnfc libfreefare
```

Then use the CLI or web GUI below.

## Usage

### Native app

| Button | What it does |
| --- | --- |
| **Write** | Writes the URL to the card. New, unformatted cards usually work directly. |
| **Format (initialize)** | NDEF-formats the card first — use this if **Write** fails or you want a clean card. |
| **Read & verify** | Reads the card and shows the URL on it. Does **not** modify the card. |
| **Fix reader** | Releases the reader from macOS's smart-card daemon (asks for your password, then re-plug the ACR122U). |

Backups are saved to `~/Library/Application Support/NFC URL Writer/backups`.

### CLI — `write-url.sh`

The URL is supplied via the `TARGET_URL` environment variable (or by editing the default at the top of the script):

```bash
# First write to a brand-new card: format, then write
TARGET_URL="https://example.com/" ./write-url.sh --format

# Subsequent writes: just write the URL
TARGET_URL="https://example.com/" ./write-url.sh

# Read back the URL currently on the card (read-only)
./write-url.sh --read

# Release the reader from macOS's smart-card daemon
./write-url.sh --fix-reader
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--format` | NDEF-format the card before writing (required for a fresh card). |
| `--read` | Read and decode the NDEF URL on the card. |
| `--fix-reader` | Disable `com.apple.ifdreader` so `libnfc` can open the ACR122U. |
| `--print-ndef` | Print the generated NDEF bytes and exit (no hardware needed). |
| `--no-backup` | Skip the pre-write backup. |
| `--yes` / `-y` | Skip confirmation prompts. |
| `--help` | Full help. |

`NFC_BACKUP_DIR` overrides where backups are written.

### Local web GUI — `nfc-gui.py`

A zero-dependency, standard-library web UI that binds to `127.0.0.1` only:

```bash
python3 nfc-gui.py
```

(Or just double-click **`nfc-gui.command`** in Finder.) It opens in your browser and shells out to the same `write-url.sh`.

## How it works

A URL is encoded as a single **NDEF URI record** (NFC Forum "well-known" type `U`, `0x55`), using the standard URI-prefix abbreviations (`https://www.`, `https://`, `tel:`, `mailto:`, …) to save bytes.

That raw NDEF message is handed to `libfreefare`'s `mifare-classic-write-ndef`, which takes care of the **MIFARE-specific plumbing** — the MAD (MIFARE Application Directory), the TLV wrapping, and the NFC-Forum sector keys / access bits. The tool itself never pokes at sector trailers, which keeps your card recoverable.

The pipeline for a write is:

```
nfc-list (detect reader)  →  backup (.mfd)  →  [--format]  →
write-ndef (URL)          →  read-ndef (verify against what was written)
```

## iPhone compatibility — please read

> [!IMPORTANT]
> **iPhones generally cannot read NDEF from MIFARE Classic cards.**
>
> MIFARE Classic is **not** one of the NFC Forum tag types (Type 1–5). iOS Core NFC reads NDEF from NFC-Forum tags, so even though the write succeeds, **an iPhone usually will not react to a MIFARE Classic card** written by this tool.
>
> - **For iPhone**, use **NTAG213 / NTAG215 / NTAG216** (NFC Forum Type 2) tags instead. (Those need different tooling than the MIFARE Classic tools here.)
> - **Most Android phones can read MIFARE Classic** NDEF just fine.

If your audience is iPhone users, choose NTAG hardware. If you control the readers or target Android, MIFARE Classic 1K works great.

## Distributing the app

The app is **ad-hoc signed** (not notarized), so Gatekeeper will warn on first launch on another Mac. Recipients should either:

- **Right-click → Open** the app once, then confirm in the dialog, **or**
- clear the quarantine attribute:

  ```bash
  xattr -dr com.apple.quarantine "NFC URL Writer.app"
  ```

The scripts are bundled inside the `.app`, so you can distribute the app on its own. Recipients still need an ACR122U and the Homebrew dependencies (which the app can install for them).

## Troubleshooting

### Reader not detected / `nfc-list` can't open the device

This is the **most common issue on macOS**: the system smart-card daemon `com.apple.ifdreader` has claimed the ACR122U. Release it:

- **App:** click **Fix reader** (enter your password when asked).
- **CLI:** `./write-url.sh --fix-reader`

Either way, **unplug and re-plug the ACR122U** afterward, then try again.

Under the hood this runs:

```bash
sudo launchctl bootout system/com.apple.ifdreader
sudo launchctl disable system/com.apple.ifdreader
sudo launchctl bootout system/com.apple.usbsmartcardreaderd
sudo launchctl disable system/com.apple.usbsmartcardreaderd
```

To undo it later:

```bash
sudo launchctl enable system/com.apple.ifdreader
sudo launchctl enable system/com.apple.usbsmartcardreaderd
# then re-plug the reader or reboot
```

### Other checks

- Use a **direct USB port** or a **powered hub** — flaky cables and unpowered hubs cause intermittent failures.
- Some **ACR122U clones** open in `nfc-list` but fail on write.
- A brand-new card may need `--format` (or the **Format** button) before its first write.

## Safety

- **Never writes sector trailers, keys, or access bits directly.** All MIFARE-specific structure is delegated to `libfreefare`.
- **Backs up the card** to a timestamped `.mfd` before writing (skip with `--no-backup`).
- **Verifies after writing** by reading the card back and comparing.

## Building from source

You need Xcode or the Command Line Tools (for `swiftc`):

```bash
xcode-select --install   # if you don't already have swiftc
./build-app.sh           # produces "NFC URL Writer.app"
```

`build-app.sh` compiles a **universal binary** (`arm64` + `x86_64` when available), bundles `write-url.sh` into the app's `Resources`, generates the icon, and ad-hoc signs the result. The URL is always passed in at runtime via the `TARGET_URL` environment variable — the bundled script is never rewritten.

## License

This project's code is released under the **MIT License** — see [`LICENSE`](LICENSE).

It depends on, but does **not bundle**, the following LGPL libraries, which you install separately via Homebrew:

- **[libnfc](https://github.com/nfc-tools/libnfc)** — low-level NFC device access (LGPL).
- **[libfreefare](https://github.com/nfc-tools/libfreefare)** — MIFARE Classic NDEF / MAD handling (LGPL).

Because they are installed through Homebrew rather than redistributed here, there is no LGPL redistribution burden on this repository. Huge thanks to the `nfc-tools` community for making any of this possible.

---

<div align="center">
<sub>Built for the corner of the world where ACR122U meets macOS and refuses to cooperate. Now it does.</sub>
</div>
