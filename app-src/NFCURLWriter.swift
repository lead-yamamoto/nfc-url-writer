import SwiftUI
import Foundation
import AppKit

// MARK: - シェル実行ヘルパ

enum Shell {
    /// Finder から起動した GUI アプリは最小限の環境しか持たないため Homebrew の bin を PATH に足す。
    static func augmentedEnv(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brew = "/opt/homebrew/bin:/usr/local/bin"
        let cur = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = brew + ":" + cur
        env["TERM"] = "dumb"
        for (k, v) in extra { env[k] = v }
        return env
    }

    static func run(_ launch: String, _ args: [String], env: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, "起動に失敗しました: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, stripANSI(raw))
    }

    static func stripANSI(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m") else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

// MARK: - リーダー / カードの検出状態

/// --detect と各操作の出力から取り出したリーダー/カードの状態。
struct DetectState {
    enum Reader { case unknown, ok, none }
    enum Tag { case none, classic, type2, type4, felica, unknown }

    var reader: Reader = .unknown
    var readerName: String = ""
    var tag: Tag = .none
    var tagSAK: String = ""

    /// リーダー行の日本語表示。
    var readerText: String {
        switch reader {
        case .ok:      return "リーダー: \(readerName.isEmpty ? "対応リーダー" : readerName)"
        case .none:    return "リーダー: 未検出"
        case .unknown: return "リーダー: 未確認"
        }
    }

    /// カード行の日本語表示。
    var tagText: String {
        let sak = tagSAK.isEmpty ? "" : " (SAK=\(tagSAK))"
        switch tag {
        case .classic: return "カード: MIFARE Classic（対応）\(sak)"
        case .type2:   return "カード: NTAG/Type2（実験的・iPhone可）\(sak)"
        case .type4:   return "カード: DESFire/Type4（実験的）\(sak)"
        case .felica:  return "カード: FeliCa（非対応）"
        case .unknown: return "カード: 不明な種別\(sak)"
        case .none:    return "カード: 未検出"
        }
    }
}

// MARK: - かんたんログ（友好的ログ）の行モデル

/// 1行のかんたんログ。スクリプト出力を非開発者向けに分類・整形したもの。
struct FriendlyRow: Identifiable {
    enum Kind { case ok, error, warn, step, retry, plain }
    let id: Int             // 表示順（行インデックス）。再描画で安定させるため決定的にする。
    let kind: Kind
    let text: String        // マーカー（==> / ✓ / ✗ / ![注意]）を除いた表示テキスト
    let url: String?        // 行に URL を含む場合はその URL（強調表示用）
}

/// スクリプト出力（NFC_VERBOSE=1 でキャプチャした生ログ）を
/// 「かんたんログ」行と「詳細ログ（生出力）」に振り分けるパーサ。
enum LogParser {
    /// 行が「詳細（開発者向け）」かどうか。4スペース字下げ、または技術的パターンに一致するもの。
    static func isDetailLine(_ raw: String) -> Bool {
        // 4スペース字下げ = スクリプトの detail() が付ける詳細マーカー。
        if raw.hasPrefix("    ") || raw.hasPrefix("\t") { return true }
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        // 16進ダンプらしき行（16進とスペースのみで8文字以上）
        if t.count >= 8, t.range(of: "^[0-9a-fA-F ]{8,}$", options: .regularExpression) != nil {
            return true
        }
        // 技術用語を含む行（libnfc/libfreefare の生出力）
        let techMarkers = ["SAK", "ATQA", "UID", "SENS_RES", "SEL_RES", "NFCID",
                           "nfc-list", "libnfc", "PICC Interface opened",
                           "ISO/IEC 14443", "ISO14443", "MIFARE Ultralight card",
                           "NTAG Type", "Reading ", "Writing data to file"]
        for m in techMarkers where t.contains(m) { return true }
        return false
    }

    /// 生ログをかんたんログ行の配列へ変換する（詳細行は除外）。
    static func friendlyRows(_ output: String) -> [FriendlyRow] {
        var rows: [FriendlyRow] = []
        var idx = 0
        for rawLine in output.components(separatedBy: "\n") {
            if isDetailLine(rawLine) { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            rows.append(row(from: line, id: idx))
            idx += 1
        }
        return rows
    }

    /// 1行をマーカーから分類し、表示テキストと URL を取り出す。
    static func row(from line: String, id: Int) -> FriendlyRow {
        var kind: FriendlyRow.Kind = .plain
        var text = line

        if text.hasPrefix("✓") {
            kind = .ok; text = String(text.dropFirst())
        } else if text.hasPrefix("✗") {
            kind = .error; text = String(text.dropFirst())
        } else if text.hasPrefix("![注意]") {
            kind = .warn; text = String(text.dropFirst("![注意]".count))
        } else if text.hasPrefix("【") || text.contains("注意") {
            kind = .warn
        } else if text.hasPrefix("==>") {
            text = String(text.dropFirst("==>".count))
            // 再試行の通知は専用の見た目にする。
            kind = text.contains("再試行") ? .retry : .step
        } else if text.contains("再試行") {
            kind = .retry
        }

        text = text.trimmingCharacters(in: .whitespaces)
        let url = firstURL(in: text)
        return FriendlyRow(id: id, kind: kind, text: text, url: url)
    }

    /// 行から最初の URL らしき文字列を取り出す（http(s):// で始まる連続文字列）。
    static func firstURL(in text: String) -> String? {
        guard let r = text.range(of: "https?://[^\\s、。）]+", options: .regularExpression)
        else { return nil }
        return String(text[r])
    }
}

// MARK: - モデル

final class AppModel: ObservableObject {
    @Published var url: String { didSet { UserDefaults.standard.set(url, forKey: "targetURL") } }
    @Published var log: String
    @Published var status: String = ""
    @Published var statusKind: Int = 0   // 0=なし 1=実行中 2=成功 3=失敗
    @Published var busy: Bool = false
    @Published var depsOK: Bool = AppModel.depsInstalled()

    // ライブ検出状態（リーダー/カード）
    @Published var detect = DetectState()
    @Published var detecting: Bool = false

    // トースト（成功=緑✓ / 失敗=赤✕、約4秒で自動消滅・タップで即消し）
    @Published var toastText: String = ""
    @Published var toastKind: Int = 0    // 0=非表示 2=成功 3=失敗
    @Published var toastShown: Bool = false
    private var toastToken: Int = 0

    // アプリ自身が鳴らす効果音。NSSound は再生前に解放されると鳴らないため
    // プロパティで保持しておく（.app では script のバックグラウンド afplay が
    // 失われて無音になるため、完了時はアプリ側で確実に鳴らす）。
    private var completionSound: NSSound?

    /// 操作完了時にアプリ側で成功/失敗音を鳴らす（write/format/read のみ）。
    /// System サウンド: 成功=Glass / 失敗=Basso。
    private func playCompletionSound(success: Bool) {
        let path = success
            ? "/System/Library/Sounds/Glass.aiff"
            : "/System/Library/Sounds/Basso.aiff"
        let sound = NSSound(contentsOfFile: path, byReference: true)
        completionSound = sound   // 再生完了まで保持
        sound?.play()
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "targetURL"), !saved.isEmpty {
            url = saved
        } else {
            url = AppModel.defaultURLFromScript() ?? "https://example.com"
        }
        log = """
        カードをリーダーに置き、操作を選んでください。

        ・通常は「書き込む」だけでOK（新品カードでもそのまま書けます）
        ・「書き込む」が失敗する／カードを初期化したい時だけ「フォーマット（初期化）」
        ・確認だけ … 「読み取り検証」（カードは変更しません）
        ・認識されない … 「リーダー解放」（パスワード → 抜き差し）
        """
    }

    static func scriptPath() -> String? {
        Bundle.main.path(forResource: "write-url", ofType: "sh")
    }

    // MARK: DMG クリーンアップ（起動時に一度だけ）

    /// 起動ごとに一度だけ DMG 後始末プロンプトを出すためのガード。
    private static var didOfferDMGCleanup = false

    /// リリース DMG のボリューム名（マウント先 /Volumes/NFC URL Writer）。
    private static let dmgVolumeName = "NFC URL Writer"

    /// "NFC URL Writer" ボリュームがマウント中なら、DMG の取り出し/削除を促す。
    /// 失敗はすべて無視（非致命）。起動につき一度だけ、マウント時のみ表示する。
    func offerDMGCleanupIfMounted() {
        guard !AppModel.didOfferDMGCleanup else { return }

        let volPath = "/Volumes/\(AppModel.dmgVolumeName)"
        var mounted = FileManager.default.fileExists(atPath: volPath)
        if !mounted,
           let vols = FileManager.default.mountedVolumeURLs(
               includingResourceValuesForKeys: nil, options: []) {
            mounted = vols.contains { $0.path == volPath }
        }
        guard mounted else { return }
        AppModel.didOfferDMGCleanup = true

        let alert = NSAlert()
        alert.messageText = "インストール完了"
        alert.informativeText = "ディスクイメージ(DMG)を取り出して、ダウンロード内のDMGファイルを削除しますか？"
        alert.addButton(withTitle: "取り出して削除")   // 既定
        alert.addButton(withTitle: "取り出すだけ")
        alert.addButton(withTitle: "何もしない")

        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:      // 取り出して削除
            AppModel.ejectDMGVolume(at: volPath)
            AppModel.trashDownloadedDMGs()
        case .alertSecondButtonReturn:     // 取り出すだけ
            AppModel.ejectDMGVolume(at: volPath)
        default:                           // 何もしない
            break
        }
    }

    /// DMG ボリュームを取り出す（hdiutil detach）。失敗は無視。
    private static func ejectDMGVolume(at path: String) {
        _ = Shell.run("/usr/bin/hdiutil", ["detach", path], env: Shell.augmentedEnv())
    }

    /// ~/Downloads 内の NFC-URL-Writer*.dmg をゴミ箱へ移動する。失敗は無視。
    private static func trashDownloadedDMGs() {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? fm.contentsOfDirectory(
                  at: downloads, includingPropertiesForKeys: nil, options: []) else { return }
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("NFC-URL-Writer"),
                  name.lowercased().hasSuffix(".dmg") else { continue }
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func defaultURLFromScript() -> String? {
        guard let path = scriptPath(),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.hasPrefix("TARGET_URL=") else { continue }
            guard let q1 = line.firstIndex(of: "\""),
                  let q2 = line.lastIndex(of: "\""), q1 < q2 else { return nil }
            var v = String(line[line.index(after: q1)..<q2])
            let pfx = "${TARGET_URL:-"
            if v.hasPrefix(pfx) && v.hasSuffix("}") {
                v = String(v.dropFirst(pfx.count).dropLast())
            }
            return v
        }
        return nil
    }

    func backupDir() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NFC URL Writer", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    // MARK: トースト表示

    /// 成功/失敗のトーストを表示し、約4秒後に自動で消す。
    func showToast(_ text: String, kind: Int) {
        toastToken += 1
        let token = toastToken
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastText = text
            toastKind = kind
            toastShown = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self, self.toastToken == token else { return }
            self.dismissToast()
        }
    }

    func dismissToast() {
        withAnimation(.easeOut(duration: 0.25)) { toastShown = false }
    }

    // MARK: 主操作（書き込み/フォーマット/読み取り/リーダー解放）

    func run(_ action: String) {
        if (action == "write" || action == "format")
            && url.trimmingCharacters(in: .whitespaces).isEmpty {
            status = "URL を入力してください"; statusKind = 3
            showToast("URL を入力してください", kind: 3)
            return
        }
        busy = true
        status = "実行中…"; statusKind = 1
        log = "実行中… カードをリーダーから動かさないでください。"
        let u = url.trimmingCharacters(in: .whitespaces)
        let backup = backupDir()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppModel.execute(action: action, url: u, backupDir: backup)
            DispatchQueue.main.async {
                var text = result.1.isEmpty ? "(出力なし)" : result.1
                if result.0 != 0 {
                    text += AppModel.failureHint(for: result.1)
                }
                self.log = text
                self.busy = false
                let ok = result.0 == 0
                self.status = ok ? "成功" : "失敗"
                self.statusKind = ok ? 2 : 3
                // 各操作の出力からリーダー/カード状態を拾って更新（--detect の再実行は避ける）。
                self.mergeDetect(from: result.1)
                // アプリ側で効果音を鳴らす（write/format/read の完了時のみ。
                // fix/install/detect では鳴らさない）。script 側は NFC_SOUND=0 で
                // afplay を抑止しているが、リーダーのハードビープは別途鳴る。
                if action == "write" || action == "format" || action == "read" {
                    self.playCompletionSound(success: ok)
                }
                // トースト表示
                // 非対応リーダー×タグの組合せ（INCOMPAT: 行）が出力にあれば、
                // その日本語ガイダンスを赤トーストで最優先に表示する。
                if let incompat = AppModel.incompatMessage(from: result.1) {
                    self.showToast(incompat, kind: 3)
                } else if action == "fix" {
                    self.showToast(ok ? "リーダー解放を実行しました" : "リーダー解放に失敗しました",
                                   kind: ok ? 2 : 3)
                } else if action == "read" {
                    self.showToast(ok ? "読み取り成功" : "読み取り失敗：\(AppModel.shortReason(result.1))",
                                   kind: ok ? 2 : 3)
                } else {
                    self.showToast(ok ? "書き込み成功" : "書き込み失敗：\(AppModel.shortReason(result.1))",
                                   kind: ok ? 2 : 3)
                }
            }
        }
    }

    // MARK: 接続確認（--detect）

    /// --detect を実行してリーダー/カードのライブ状態を更新する。
    /// 連続ポーリングはしない（リーダー競合で不安定化するため）。起動直後とボタン押下時のみ。
    func detectStatus(showBusy: Bool = true) {
        guard depsOK else { return }
        guard let script = AppModel.scriptPath() else { return }
        if showBusy { detecting = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let (_, out) = Shell.run("/bin/bash", [script, "--detect"], env: Shell.augmentedEnv())
            DispatchQueue.main.async {
                self.detecting = false
                self.applyDetect(parseDetect: out)
            }
        }
    }

    /// --detect の機械可読行（READER: / TAG:）を解釈して detect を更新する。
    func applyDetect(parseDetect out: String) {
        var d = DetectState()
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("READER:") {
                let v = line.dropFirst("READER:".count).trimmingCharacters(in: .whitespaces)
                if v == "NONE" || v.isEmpty {
                    d.reader = .none
                } else {
                    d.reader = .ok
                    d.readerName = v
                }
            } else if line.hasPrefix("TAG:") {
                let v = line.dropFirst("TAG:".count).trimmingCharacters(in: .whitespaces)
                let parts = v.split(separator: " ").map(String.init)
                let kind = parts.first ?? "none"
                d.tag = AppModel.tagKind(kind)
                if parts.count >= 2 { d.tagSAK = parts[1] }
            }
        }
        detect = d
    }

    /// 各操作の通常出力からリーダー名/カード種別を拾って detect を更新する（ベストエフォート）。
    /// 例: "使用リーダー: ACS / ACR122U ..." / "カード種別を判定しました: type2 (SAK=00)"
    func mergeDetect(from out: String) {
        var d = detect
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "使用リーダー:") {
                let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { d.reader = .ok; d.readerName = name }
            }
            if let r = line.range(of: "カード種別を判定しました:") {
                let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                let kindToken = rest.split(separator: " ").first.map(String.init) ?? ""
                d.tag = AppModel.tagKind(kindToken)
                if let sr = rest.range(of: "SAK=") {
                    let sak = rest[sr.upperBound...]
                        .prefix { $0.isHexDigit }
                    d.tagSAK = String(sak)
                }
            }
        }
        detect = d
    }

    static func tagKind(_ token: String) -> DetectState.Tag {
        switch token.lowercased() {
        case "classic": return .classic
        case "type2":   return .type2
        case "type4":   return .type4
        case "felica":  return .felica
        case "none":    return .none
        default:        return .unknown
        }
    }

    /// トースト用の短い失敗理由（ログ本文から最初のエラー行らしきものを抜く）。
    static func shortReason(_ output: String) -> String {
        let markers = ["✗", "リーダー", "見つかりません", "失敗", "空です", "非対応", "対応していません"]
        for raw in output.split(separator: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if markers.contains(where: { line.contains($0) }) {
                var s = line
                for junk in ["✗ ", "==> ", " ![注意] ", "![注意] "] { s = s.replacingOccurrences(of: junk, with: "") }
                if s.count > 40 { s = String(s.prefix(40)) + "…" }
                return s
            }
        }
        return "ログを確認してください"
    }

    /// 出力から "INCOMPAT: <tagtype>|<日本語説明>" 行を探し、日本語ガイダンスを返す。
    /// 非対応リーダー×タグ組合せ（PC/SC backend が出力）を赤トーストで示すために使う。
    /// 見つからなければ nil。
    static func incompatMessage(from output: String) -> String? {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("INCOMPAT:") else { continue }
            let body = line.dropFirst("INCOMPAT:".count).trimmingCharacters(in: .whitespaces)
            // <tagtype>|<日本語説明> の '|' 以降を採用。無ければ本文全体。
            if let bar = body.firstIndex(of: "|") {
                let msg = body[body.index(after: bar)...].trimmingCharacters(in: .whitespaces)
                if !msg.isEmpty { return msg }
            }
            if !body.isEmpty { return String(body) }
        }
        return nil
    }

    /// 失敗時の出力を検査し、既知のシグネチャに一致したら日本語のヒント行を追記する。
    /// （単純な文字列包含チェックのみ。スクリプト側の案内と重複しない補足を足す。）
    static func failureHint(for output: String) -> String {
        // (c) NXP系リーダー必須のメッセージは既に十分明確なので、追加ヒントは出さない。
        if output.contains("NXP系チップのリーダー") {
            return ""
        }
        // (a) リーダーを macOS が掴んでいる / デバイスが見つからない
        if output.contains("Unable to claim USB interface")
            || output.contains("No NFC device found") {
            return "\n\n──────────\n💡 ヒント: リーダーが認識されていないようです。"
                + "「リーダー解放」ボタンを押し、ACR122U を一度抜き差ししてから、もう一度お試しください。"
        }
        // (b) カードがまだ空 / NDEF 未フォーマット
        if output.contains("まだ空です") || output.contains("No MAD detected") {
            return "\n\n──────────\n💡 ヒント: このカードにはまだ何も書かれていません。"
                + "先に「書き込む」を押してから、もう一度お試しください。"
        }
        return ""
    }

    static func execute(action: String, url: String, backupDir: String) -> (Int32, String) {
        if action == "fix" {
            let inner = "launchctl bootout system/com.apple.ifdreader; "
                + "launchctl disable system/com.apple.ifdreader; "
                + "launchctl bootout system/com.apple.usbsmartcardreaderd; "
                + "launchctl disable system/com.apple.usbsmartcardreaderd; true"
            let osa = "do shell script \"\(inner)\" with administrator privileges"
            let (rc, out) = Shell.run("/usr/bin/osascript", ["-e", osa], env: Shell.augmentedEnv())
            let extra = rc == 0
                ? "\n\nmacOS のスマートカードデーモンを無効化しました。\n→ ACR122U を一度抜き差ししてから、もう一度操作してください。"
                : ""
            return (rc, out + extra)
        }
        guard let script = scriptPath() else {
            return (-1, "アプリ内に write-url.sh が見つかりません。")
        }
        var args = [script]
        // NFC_VERBOSE=1: 生ツール出力(16進/UID/SAK 等)も含めてキャプチャする。
        // アプリは「かんたんログ」を既定表示し、この生出力は「詳細ログ」トグルで見せる。
        // NFC_SOUND=0: script のバックグラウンド afplay は .app では失われて無音に
        // なるため抑止し、完了音はアプリ側(playCompletionSound)で確実に鳴らす。
        // なお reader_beep(リーダー本体のハードビープ)は NFC_SOUND に依存せず鳴る。
        var env: [String: String] = [
            "NFC_BACKUP_DIR": backupDir, "NFC_VERBOSE": "1", "NFC_SOUND": "0"]
        switch action {
        case "write":  args += ["--yes"]; env["TARGET_URL"] = url
        case "format": args += ["--format", "--yes"]; env["TARGET_URL"] = url
        case "read":   args += ["--read", "--yes"]
        default: return (-1, "不明な操作です。")
        }
        return Shell.run("/bin/bash", args, env: Shell.augmentedEnv(env))
    }

    // MARK: 依存ツール（libnfc / libfreefare）のセットアップ

    static func toolExists(_ name: String) -> Bool {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            if FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return true }
        }
        return false
    }

    static func depsInstalled() -> Bool {
        toolExists("nfc-list") && toolExists("mifare-classic-write-ndef")
    }

    static func brewPath() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func recheckDeps() {
        depsOK = AppModel.depsInstalled()
        if depsOK {
            status = "準備完了"; statusKind = 2
            log = "必要なツールを確認しました。書き込みできます。"
            detectStatus()
        } else {
            status = "未検出"; statusKind = 3
            log = "まだ見つかりません。「必要なツールをインストール」を実行してください。"
        }
    }

    func installDeps() {
        busy = true; status = "インストール中…"; statusKind = 1
        if let brew = AppModel.brewPath() {
            let header = "Homebrew で libnfc / libfreefare をインストール中…\n（数分かかることがあります。完了までお待ちください）\n\n"
            log = header
            let env = Shell.augmentedEnv(["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1"])
            AppModel.runStreaming(brew, ["install", "libnfc", "libfreefare"], env: env,
                onLine: { text in self.log = header + text },
                done: { _ in
                    self.busy = false
                    self.depsOK = AppModel.depsInstalled()
                    if self.depsOK {
                        self.status = "準備完了"; self.statusKind = 2
                        self.log += "\n\n✅ インストール完了。書き込みできます。"
                        self.showToast("セットアップ完了", kind: 2)
                        self.detectStatus()
                    } else {
                        self.status = "失敗"; self.statusKind = 3
                        self.log += "\n\n⚠️ うまくいかなかった可能性があります。ターミナルで\n  brew install libnfc libfreefare\nをお試しください。"
                        self.showToast("セットアップに失敗しました", kind: 3)
                    }
                })
        } else {
            // Homebrew 自体が無い → ターミナルでセットアップ（管理者パスワードが必要）
            log = "Homebrew が見つかりません。ターミナルでセットアップを開始します…\n（管理者パスワードを求められます）"
            AppModel.openTerminalSetup()
            busy = false
            status = "ターミナルで続行"; statusKind = 1
            log += "\n\nターミナルでインストールが終わったら、「再確認」を押してください。"
        }
    }

    /// 出力を逐次受け取りながらコマンドを実行する（インストールの進捗表示用）。
    static func runStreaming(_ launch: String, _ args: [String], env: [String: String],
                             onLine: @escaping (String) -> Void, done: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let handle = pipe.fileHandleForReading
        let lock = NSLock()
        var buffer = Data()
        handle.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); buffer.append(d); let snap = buffer; lock.unlock()
            let text = String(data: snap, encoding: .utf8).map { Shell.stripANSI($0) } ?? ""
            DispatchQueue.main.async { onLine(text) }
        }
        p.terminationHandler = { proc in
            handle.readabilityHandler = nil
            let rest = handle.readDataToEndOfFile()
            lock.lock(); if !rest.isEmpty { buffer.append(rest) }; let snap = buffer; lock.unlock()
            let text = String(data: snap, encoding: .utf8).map { Shell.stripANSI($0) } ?? ""
            DispatchQueue.main.async { onLine(text); done(proc.terminationStatus) }
        }
        do { try p.run() } catch {
            handle.readabilityHandler = nil
            DispatchQueue.main.async { done(-1) }
        }
    }

    /// Homebrew が無い場合：ターミナルで Homebrew → libnfc/libfreefare を導入する。
    static func openTerminalSetup() {
        let script = """
        #!/bin/bash
        echo '==> NFC URL Writer セットアップ'
        if ! command -v brew >/dev/null 2>&1; then
          echo '==> Homebrew をインストールします（管理者パスワードを求められます）'
          NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
        echo '==> libnfc / libfreefare をインストールします'
        brew install libnfc libfreefare
        echo
        echo '✅ 完了しました。NFC URL Writer に戻って「再確認」を押してください。'
        """
        let tmp = NSTemporaryDirectory() + "nfc-setup.command"
        try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = Shell.run("/bin/chmod", ["+x", tmp], env: Shell.augmentedEnv())
        let osa = "tell application \"Terminal\"\nactivate\ndo script \"bash '\(tmp)'\"\nend tell"
        _ = Shell.run("/usr/bin/osascript", ["-e", osa], env: Shell.augmentedEnv())
    }
}

// MARK: - 配色

enum Palette {
    static let indigo = Color(red: 0.33, green: 0.28, blue: 0.93)
    static let teal   = Color(red: 0.02, green: 0.72, blue: 0.85)
    static let green  = Color(red: 0.13, green: 0.66, blue: 0.36)
    static let blue   = Color(red: 0.10, green: 0.45, blue: 0.90)
    static let slate  = Color(red: 0.40, green: 0.45, blue: 0.55)
    static let amber  = Color(red: 0.86, green: 0.55, blue: 0.10)
    static let red    = Color(red: 0.80, green: 0.25, blue: 0.20)
    static let console = Color(red: 0.078, green: 0.086, blue: 0.12)
}

// MARK: - ボタン

private struct PrimaryButton: View {
    let title: String; let icon: String; let tint: Color; let busy: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .disabled(busy)
    }
}

private struct SecondaryButton: View {
    let title: String; let icon: String; let tint: Color; let busy: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.large)
        .disabled(busy)
    }
}

// MARK: - トーストバナー

private struct ToastBanner: View {
    let text: String
    let kind: Int          // 2=成功 3=失敗
    let onTap: () -> Void

    private var isOK: Bool { kind == 2 }
    private var bg: Color { isOK ? Palette.green : Palette.red }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 16, weight: .bold))
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .opacity(0.7)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(bg)
                .shadow(color: bg.opacity(0.4), radius: 10, y: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - ライブ状態ピル

private struct StatusPill: View {
    let icon: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - かんたんログの1行ビュー

private struct FriendlyRowView: View {
    let row: FriendlyRow

    private var icon: String? {
        switch row.kind {
        case .ok:    return "✅"
        case .error: return "❌"
        case .warn:  return "⚠️"
        case .retry: return "🔄"
        case .step, .plain: return nil
        }
    }

    private var textColor: Color {
        switch row.kind {
        case .ok:    return Palette.green
        case .error: return Palette.red
        case .warn:  return Palette.amber
        case .retry: return .secondary
        case .step:  return .primary.opacity(0.75)
        case .plain: return .primary.opacity(0.85)
        }
    }

    private var weight: Font.Weight {
        switch row.kind {
        case .ok, .error: return .semibold
        default:          return .regular
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = icon {
                Text(icon).font(.system(size: 13))
                    .frame(width: 18, alignment: .leading)
            } else if row.kind == .step {
                // 進行中ステップは控えめなドットで示す。
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 5)
            } else {
                Color.clear.frame(width: 18, height: 1)
            }
            rowText
                .font(.system(size: 13.5, weight: weight))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// URL を含む行は URL 部分を強調表示する。
    private var rowText: Text {
        guard let url = row.url, let r = row.text.range(of: url) else {
            return Text(row.text)
        }
        let before = String(row.text[row.text.startIndex..<r.lowerBound])
        let after  = String(row.text[r.upperBound...])
        return Text(before)
            + Text(url).foregroundColor(Palette.blue).fontWeight(.semibold)
            + Text(after)
    }
}

// MARK: - 画面

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showCompat = false
    @State private var showRawLog = false
    @State private var logCopied = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    setupCard
                    liveStatus
                    urlField
                    buttons
                    statusRow
                    console
                    compatSection
                    footer
                }
                .padding(22)
            }
            .frame(minWidth: 580, minHeight: 720)
            .background(Color(NSColor.windowBackgroundColor))

            // トーストオーバーレイ（画面上端）
            if model.toastShown {
                ToastBanner(text: model.toastText, kind: model.toastKind) { model.dismissToast() }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .onAppear {
            // 起動直後に一度だけ接続確認（連続ポーリングはしない）
            model.detectStatus(showBusy: true)
            // DMG がマウント中なら取り出し/削除を促す（起動につき一度だけ）。
            model.offerDMGCleanupIfMounted()
        }
    }

    // ヘッダ（グラデーションのアイコンタイル + 一般化した副題）
    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Palette.indigo, Palette.teal],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white))
                .shadow(color: Palette.indigo.opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("NFC URL Writer")
                    .font(.system(size: 22, weight: .bold))
                Text("NFCタグにURL（NDEF）を書き込む")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var setupCard: some View {
        if !model.depsOK {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill").foregroundColor(Palette.blue)
                    Text("初回セットアップ").font(.system(size: 13, weight: .semibold))
                }
                Text("NFC の読み書きに必要なツール（libnfc / libfreefare）が見つかりません。下のボタンでインストールできます（Homebrew を使用。数分かかることがあります）。")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    PrimaryButton(title: "必要なツールをインストール", icon: "arrow.down.circle.fill",
                                  tint: Palette.blue, busy: model.busy) { model.installDeps() }
                    SecondaryButton(title: "再確認", icon: "arrow.clockwise",
                                    tint: Palette.slate, busy: model.busy) { model.recheckDeps() }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.blue.opacity(0.4), lineWidth: 1))
        }
    }

    // ライブ状態パネル：現在のリーダー/カードと「接続確認」ボタン
    private var liveStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("接続状態")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    model.detectStatus(showBusy: true)
                } label: {
                    HStack(spacing: 5) {
                        if model.detecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("接続確認")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Palette.blue)
                .disabled(model.busy || model.detecting || !model.depsOK)
            }
            HStack(spacing: 8) {
                StatusPill(icon: readerIcon, text: model.detect.readerText, tint: readerTint)
                StatusPill(icon: tagIcon, text: model.detect.tagText, tint: tagTint)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var readerIcon: String {
        switch model.detect.reader {
        case .ok:      return "cable.connector"          // macOS 12+
        case .none:    return "xmark.circle.fill"        // macOS 12+ 互換（未検出）
        case .unknown: return "questionmark.circle"
        }
    }
    private var readerTint: Color {
        switch model.detect.reader {
        case .ok:      return Palette.green
        case .none:    return Palette.red
        case .unknown: return Palette.slate
        }
    }
    private var tagIcon: String {
        switch model.detect.tag {
        case .classic:            return "checkmark.seal.fill"
        case .type2, .type4:      return "exclamationmark.triangle.fill"  // 実験的（macOS 12互換）
        case .felica:             return "xmark.seal.fill"
        case .unknown:            return "questionmark.circle"
        case .none:               return "tag"
        }
    }
    private var tagTint: Color {
        switch model.detect.tag {
        case .classic:            return Palette.green
        case .type2, .type4:      return Palette.amber
        case .felica:             return Palette.red
        case .unknown, .none:     return Palette.slate
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("書き込む URL")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundColor(.secondary)
                TextField("https://example.com", text: $model.url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .disabled(model.busy)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PrimaryButton(title: "フォーマット（初期化）", icon: "arrow.triangle.2.circlepath",
                              tint: Palette.blue, busy: model.busy || !model.depsOK) { model.run("format") }
                PrimaryButton(title: "書き込む", icon: "square.and.arrow.down.fill",
                              tint: Palette.green, busy: model.busy || !model.depsOK) { model.run("write") }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "読み取り検証", icon: "magnifyingglass",
                                tint: Palette.slate, busy: model.busy || !model.depsOK) { model.run("read") }
                SecondaryButton(title: "リーダー解放", icon: "wrench.and.screwdriver.fill",
                                tint: Palette.amber, busy: model.busy) { model.run("fix") }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        if !model.status.isEmpty {
            HStack(spacing: 7) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.statusKind == 2 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                }
                Text(model.status).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(statusColor)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Capsule().fill(statusColor.opacity(0.14)))
        }
    }

    // かんたんログ（既定表示）＋ 詳細ログ（生出力）トグル。
    private var console: some View {
        VStack(alignment: .leading, spacing: 10) {
            friendlyLog
            rawLogDisclosure
        }
    }

    // かんたんログ：非開発者向けの読みやすい行。アイコン＋システムフォント。
    private var friendlyLog: some View {
        let rows = LogParser.friendlyRows(model.log)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold))
                Text("ログ").font(.system(size: 11, weight: .semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 13).padding(.vertical, 9)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(rows) { row in
                            FriendlyRowView(row: row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: model.log) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .frame(minHeight: 210)
    }

    /// 生ログ（開発者向け詳細を含む全文）をクリップボードへコピーする。
    /// 不具合報告時に貼り付けられる、最も有用な全文を対象にする。
    private func copyRawLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.log, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { logCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) { logCopied = false }
        }
    }

    // ログ全文をコピーする小さなボタン（詳細ログのヘッダに配置）。
    private var copyLogButton: some View {
        Button(action: copyRawLog) {
            HStack(spacing: 4) {
                Image(systemName: logCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(logCopied ? "コピーしました" : "コピー")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(logCopied ? Palette.green : Palette.blue)
        }
        .buttonStyle(.borderless)
        .help("ログ全文（詳細を含む）をクリップボードにコピーします")
    }

    // 詳細ログ：開発者/デバッグ向けに、キャプチャした生出力を等幅ダークで表示（既定は閉じる）。
    private var rawLogDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showRawLog.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("詳細ログを表示")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.85))
                        Image(systemName: showRawLog ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                Spacer()
                copyLogButton
            }

            if showRawLog {
                ScrollView {
                    Text(model.log)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Color(red: 0.85, green: 0.90, blue: 1.0))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13).padding(.vertical, 11)
                }
                .frame(minHeight: 180, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.console))
                .padding(.top, 8)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // 対応状況（何が使えるか）を平易に示す開閉式パネル
    private var compatSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showCompat.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.blue)
                    Text("対応リーダー・カードについて")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.85))
                    Spacer()
                    Image(systemName: showCompat ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            if showCompat {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.vertical, 2)
                    compatBlock(
                        title: "リーダー",
                        icon: "cable.connector",
                        rows: [
                            (2, "ACR122U 等の libnfc対応（NXP系）"),
                            (3, "Sony RC-S300・PaSoRi は非対応")
                        ])
                    compatBlock(
                        title: "カード（タグ）",
                        icon: "tag",
                        rows: [
                            (2, "MIFARE Classic 1K/4K（対応）"),
                            (1, "NTAG213/215/216（実験的・iPhone可）"),
                            (1, "DESFire（実験的）"),
                            (3, "FeliCa（非対応）")
                        ])
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // 対応状況ブロック（見出し + 判定アイコン付きの行）
    private func compatBlock(title: String, icon: String, rows: [(Int, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            }
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: compatIcon(row.0))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(compatColor(row.0))
                        .frame(width: 14)
                    Text(row.1)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // 1=実験的(黄) 2=対応(緑) 3=非対応(赤)
    private func compatIcon(_ k: Int) -> String {
        switch k {
        case 2: return "checkmark.circle.fill"
        case 3: return "xmark.circle.fill"
        default: return "exclamationmark.triangle.fill"   // 実験的（macOS 12互換）
        }
    }
    private func compatColor(_ k: Int) -> Color {
        switch k {
        case 2: return Palette.green
        case 3: return Palette.red
        default: return Palette.amber
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
            Text("バックアップは ~/Library/Application Support/NFC URL Writer/backups に保存されます")
                .font(.caption2)
            Spacer()
        }
        .foregroundColor(.secondary.opacity(0.8))
    }

    private var statusColor: Color {
        switch model.statusKind {
        case 2: return Palette.green
        case 3: return Palette.red
        default: return Palette.slate
        }
    }
}

@main
struct NFCURLWriterApp: App {
    var body: some Scene {
        WindowGroup("NFC URL Writer") {
            ContentView()
        }
    }
}
