import AppKit
import ApplicationServices

/// What surrounds the cursor in the focused text field, read through Accessibility.
struct FocusContext {
    var before = ""
    var after = ""
    var windowTitle = ""
    var isSecure = false
    var element: AXUIElement?
    /// UTF-16 offset of the cursor/selection start in the field's value.
    var insertionOffset: Int?

    static let empty = FocusContext()

    /// True when the cursor sits in the middle of a sentence (next word should not be capitalized).
    var continuesSentence: Bool {
        guard let last = before.trimmingCharacters(in: .whitespaces).last else { return false }
        return last.isLetter || last.isNumber || ",;:".contains(last)
    }
}

enum FocusReader {
    private static let electronHints = ["slack", "discord", "notion", "vscode", "microsoft.vscode", "electron", "figma",
                                        "linear", "obsidian", "whatsapp", "teams", "cursor", "spotify", "claude"]
    private static var enabledApps = Set<pid_t>()

    /// Reads the focused field. Safe to call off the main thread; every AX call has a short timeout.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    static func read(app: NSRunningApplication?) -> FocusContext {
        guard AXIsProcessTrusted(), let app else { return .empty }
        // Terminal buffers (TUI boxes, prompts, logs) are not prose: they confuse whisper and the LLM.
        if let id = app.bundleIdentifier, terminalBundleIDs.contains(id) { return .empty }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        enableElectronAccessibility(app: app, element: appElement)

        var ctx = FocusContext()
        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute),
           let title: String = attribute(window, kAXTitleAttribute) {
            ctx.windowTitle = String(title.prefix(120))
        }
        guard let element: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else { return ctx }
        AXUIElementSetMessagingTimeout(element, 0.25)
        ctx.element = element
        if let subrole: String = attribute(element, kAXSubroleAttribute), subrole == (kAXSecureTextFieldSubrole as String) {
            ctx.isSecure = true
            return ctx
        }
        guard let value: String = attribute(element, kAXValueAttribute) else { return ctx }
        var location = (value as NSString).length
        if let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) { location = max(0, min(range.location, location)) }
            let ns = value as NSString
            let start = max(0, location - 600)
            ctx.before = ns.substring(with: NSRange(location: start, length: location - start))
            let afterStart = min(ns.length, location + max(0, range.length))
            ctx.after = ns.substring(with: NSRange(location: afterStart, length: min(200, ns.length - afterStart)))
        } else {
            ctx.before = String(value.suffix(600))
        }
        ctx.insertionOffset = location
        return ctx
    }

    /// Current full value of a previously focused field (for learning from user edits).
    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute)
    }

    /// Electron/Chromium apps only expose their text tree when asked explicitly.
    private static func enableElectronAccessibility(app: NSRunningApplication, element: AXUIElement) {
        guard !enabledApps.contains(app.processIdentifier) else { return }
        let id = (app.bundleIdentifier ?? "").lowercased()
        let isElectron = electronHints.contains { id.contains($0) }
            || FileManager.default.fileExists(atPath: (app.bundleURL?.path ?? "") + "/Contents/Frameworks/Electron Framework.framework")
        if isElectron {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        enabledApps.insert(app.processIdentifier)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }
}

/// Watches a field after a dictation is inserted; when the user fixes a word, proposes it for the dictionary.
final class CorrectionLearner {
    struct Suggestion: Equatable {
        var wrong: String
        var right: String
    }

    private struct Watch {
        var element: AXUIElement
        var inserted: String
        var offset: Int
        var token = UUID()
    }

    private var watch: Watch?
    private var dismissed = Set<String>()
    var onSuggestion: ((Suggestion) -> Void)?

    func track(element: AXUIElement?, inserted: String, offset: Int?) {
        guard let element, let offset, inserted.count >= 3 else { watch = nil; return }
        let w = Watch(element: element, inserted: inserted, offset: offset)
        watch = w
        for delay in [5.0, 15.0, 40.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.watch?.token == w.token else { return }
                self.check()
            }
        }
    }

    /// Final check, e.g. right before the next dictation replaces the field content.
    func flush() {
        if watch != nil { check() }
        watch = nil
    }

    func dismiss(_ s: Suggestion) { dismissed.insert(s.wrong.lowercased() + "→" + s.right) }

    private func check() {
        guard let w = watch else { return }
        let element = w.element
        DispatchQueue.global(qos: .utility).async {
            guard let value = FocusReader.value(of: element) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.watch?.token == w.token else { return }
                if let s = self.findCorrection(in: value, watch: w) {
                    self.watch = nil
                    self.onSuggestion?(s)
                }
            }
        }
    }

    private func findCorrection(in value: String, watch w: Watch) -> Suggestion? {
        let ns = value as NSString
        let start = max(0, w.offset - 30)
        let length = min(ns.length - start, (w.inserted as NSString).length + 90)
        guard length > 0 else { return nil }
        let region = ns.substring(with: NSRange(location: start, length: length))
        let old = CorrectionLearner.words(w.inserted)
        let new = CorrectionLearner.words(region)
        let diff = new.difference(from: old)
        var removals: [String] = []
        var insertions: [String] = []
        for change in diff {
            switch change {
            case .remove(_, let word, _): removals.append(word)
            case .insert(_, let word, _): insertions.append(word)
            }
        }
        let known = Set(SettingsStore.shared.s.dictionary.map { $0.word.lowercased() })
        for wrong in removals {
            for right in insertions where right != wrong && right.count >= 3 && !known.contains(right.lowercased()) {
                guard !dismissed.contains(wrong.lowercased() + "→" + right) else { continue }
                let a = wrong.lowercased(), b = right.lowercased()
                if a == b {
                    // Case-only fix: learn it only for names/brands with inner or leading capitals.
                    if right.first?.isUppercase == true, wrong.first?.isLowercase == true { return Suggestion(wrong: wrong, right: right) }
                    continue
                }
                let distance = CorrectionLearner.levenshtein(Array(a), Array(b))
                if distance <= max(2, b.count / 3) { return Suggestion(wrong: wrong, right: right) }
            }
        }
        return nil
    }

    static func words(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-.")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'")) }
            .filter { !$0.isEmpty }
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
