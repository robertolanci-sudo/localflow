import Carbon
import CoreGraphics
import Foundation

/// Resolves key codes to the character printed on the user's current keyboard layout.
enum KeyboardLayout {
    static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum Paths {
    static let appSupport: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let models = appSupport.appendingPathComponent("models", isDirectory: true)
    static let settings = appSupport.appendingPathComponent("settings.json")
    static let history = appSupport.appendingPathComponent("history.sqlite")
    static let notes = appSupport.appendingPathComponent("scratchpad.json")
}

enum HotkeyChoice: String, Codable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
    var label: String {
        switch self {
        case .fn: return "fn / 🌐"
        case .rightOption: return L("⌥ Option destro", "Right ⌥ Option")
        case .rightCommand: return L("⌘ Command destro", "Right ⌘ Command")
        case .rightControl: return L("⌃ Control destro", "Right ⌃ Control")
        }
    }
}

enum Tone: String, Codable, CaseIterable, Identifiable {
    case formal, casual, veryCasual, excited
    var id: String { rawValue }
    var label: String {
        switch self {
        case .formal: return L("Formale", "Formal")
        case .casual: return L("Informale", "Casual")
        case .veryCasual: return L("Molto informale", "Very casual")
        case .excited: return L("Entusiasta", "Excited")
        }
    }
    var example: String {
        switch self {
        case .formal: return L("Ciao, ci vediamo domani alle 10. Grazie.", "Hi, see you tomorrow at 10. Thanks.")
        case .casual: return L("Ciao, ci vediamo domani alle 10", "Hey, see you tomorrow at 10")
        case .veryCasual: return L("ciao ci vediamo domani alle 10", "hey see you tomorrow at 10")
        case .excited: return L("Ciao! Ci vediamo domani alle 10!", "Hey! See you tomorrow at 10!")
        }
    }
    var promptDescription: String {
        switch self {
        case .formal: return "Formal: complete sentences, proper capitalization and full punctuation."
        case .casual: return "Casual: proper capitalization, light punctuation, conversational; omit the final period of a short message."
        case .veryCasual: return "Very casual: everything lowercase, minimal punctuation, no final period."
        case .excited: return "Excited: energetic and warm, use exclamation marks where natural."
        }
    }
}

enum AppCategory: String, Codable, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .personal: return L("Messaggi personali", "Personal messages")
        case .work: return L("Messaggi di lavoro", "Work messages")
        case .email: return L("Email", "Email")
        case .other: return L("Altre app", "Other apps")
        }
    }
    var appsHint: String {
        switch self {
        case .personal: return "WhatsApp, Telegram, Messaggi, Signal"
        case .work: return "Slack, Teams, Discord"
        case .email: return "Mail, Outlook, Spark, Superhuman"
        case .other: return L("Tutto il resto", "Everything else")
        }
    }

    static func forBundleID(_ id: String?) -> AppCategory {
        guard let id = id?.lowercased() else { return .other }
        let personal = ["whatsapp", "telegram", "com.apple.mobilesms", "signal", "messenger", "viber"]
        let work = ["slack", "teams", "discord", "mattermost", "zoom", "webex", "lark"]
        let email = ["com.apple.mail", "outlook", "spark", "superhuman", "airmail", "mimestream", "thunderbird", "canary"]
        if personal.contains(where: { id.contains($0) }) { return .personal }
        if work.contains(where: { id.contains($0) }) { return .work }
        if email.contains(where: { id.contains($0) }) { return .email }
        return .other
    }
}

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var word: String
    /// Comma-separated wrong spellings that get replaced with `word`.
    var misspellings: String = ""
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var text: String
}

/// A user-configurable global keyboard shortcut. `keyCode < 0` means "no shortcut".
struct KeyShortcut: Codable, Hashable {
    var keyCode: Int
    /// CGEventFlags bits for ⌘ ⇧ ⌃ ⌥ (same bits as NSEvent.ModifierFlags).
    var modifiers: UInt64

    static let none = KeyShortcut(keyCode: -1, modifiers: 0)
    static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
    static let ctrlOpt: UInt64 = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue

    var isEmpty: Bool { keyCode < 0 }

    private static let digitKeyCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// ⌃⌥ + digit, used by the default Transforms.
    static func ctrlOptDigit(_ digit: Int) -> KeyShortcut {
        guard (1...9).contains(digit) else { return .none }
        return KeyShortcut(keyCode: digitKeyCodes[digit - 1], modifiers: ctrlOpt)
    }

    static func isFunctionKey(_ code: Int) -> Bool { functionKeyNames[code] != nil }

    private static let functionKeyNames: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
    private static let specialKeyNames: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    var display: String {
        guard !isEmpty else { return L("Nessuna", "None") }
        var s = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s + KeyShortcut.keyName(keyCode)
    }

    static func keyName(_ code: Int) -> String {
        if let f = functionKeyNames[code] { return f }
        if let s = specialKeyNames[code] { return s }
        return KeyboardLayout.character(for: code) ?? "#\(code)"
    }
}

struct TransformItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
    /// Legacy ⌃⌥ + digit slot from older settings files; `shortcut` is authoritative.
    var slot: Int = 0
    var shortcut: KeyShortcut = .none
}

extension TransformItem {
    init(name: String, prompt: String, slot: Int) {
        self.init(name: name, prompt: prompt, slot: slot, shortcut: .ctrlOptDigit(slot))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        shortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .shortcut) ?? .ctrlOptDigit(slot)
    }
}

enum AutoLearn: String, Codable, CaseIterable, Identifiable {
    case off, suggest, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return L("Disattivato", "Off")
        case .suggest: return L("Chiedi conferma", "Ask first")
        case .auto: return L("Aggiungi automaticamente", "Add automatically")
        }
    }
}

/// How much of the cleanup goes through the local LLM.
enum CleanupSpeed: String, Codable, CaseIterable, Identifiable {
    case quality, balanced, fast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quality: return L("Massima qualità (LLM sempre)", "Best quality (always LLM)")
        case .balanced: return L("Bilanciata (LLM solo quando serve)", "Balanced (LLM only when needed)")
        case .fast: return L("Massima velocità (niente LLM)", "Fastest (no LLM)")
        }
    }
}

struct AppSettings: Codable {
    var uiLanguage = Locale.current.language.languageCode?.identifier == "it" ? "it" : "en"
    /// "auto" (Italian/English auto-detect), "it", "en"
    var dictationLanguage = "auto"
    /// "same", "it", "en"
    var outputLanguage = "same"
    var hotkey = HotkeyChoice.fn
    var llmEnabled = true
    var cleanupSpeed = CleanupSpeed.balanced
    /// Transcribe long dictations in pieces while the user is still speaking.
    var streamingTranscription = true
    /// Daily check of GitHub Releases for a newer version (the only network request besides model downloads).
    var checkUpdates = true
    var ollamaURL = "http://127.0.0.1:11434"
    var ollamaModel = SystemInfo.recommendedLLM
    var whisperServerPath = ""
    var whisperModelPath = ""
    var whisperPort = 8178
    var removeFillers = true
    var backtrack = true
    var smartFormatting = true
    var muteWhileDictating = false
    var playSounds = true
    var flowBarAlways = true
    var hideFromScreenShare = false
    var keepHistory = true
    var restoreClipboard = true
    var customInstructions = ""
    /// CoreAudio UID of the preferred microphone; empty = system default.
    var microphoneUID = ""
    var useAppContext = true
    var autoLearn = AutoLearn.suggest
    var fileTimestamps = true
    var pasteLastShortcut = KeyShortcut(keyCode: 9, modifiers: KeyShortcut.ctrlOpt)       // ⌃⌥V
    var scratchpadShortcut = KeyShortcut(keyCode: 1, modifiers: KeyShortcut.ctrlOpt)      // ⌃⌥S
    var transcribeFileShortcut = KeyShortcut(keyCode: 3, modifiers: KeyShortcut.ctrlOpt)  // ⌃⌥F
    var tones: [String: Tone] = [
        AppCategory.personal.rawValue: .casual,
        AppCategory.work.rawValue: .casual,
        AppCategory.email.rawValue: .formal,
        AppCategory.other.rawValue: .formal,
    ]
    var dictionary: [DictionaryEntry] = []
    var snippets: [Snippet] = []
    var transforms: [TransformItem] = AppSettings.defaultTransforms

    static let defaultTransforms: [TransformItem] = [
        TransformItem(name: "Rifinisci / Refine", prompt: "Rewrite the text so it reads clearer and more fluent, keeping the author's voice, meaning and language. Fix grammar and punctuation.", slot: 1),
        TransformItem(name: "Formale / Formal", prompt: "Rewrite the text in a professional, formal tone. Keep the meaning and the language.", slot: 2),
        TransformItem(name: "Elenco puntato / Bullet points", prompt: "Restructure the text as a concise bullet-point list. Keep the language.", slot: 3),
        TransformItem(name: "Traduci IT⇄EN / Translate IT⇄EN", prompt: "If the text is Italian translate it to English; if it is English translate it to Italian. Natural, fluent translation.", slot: 4),
        TransformItem(name: "Accorcia / Shorten", prompt: "Make the text shorter and more direct without losing important information. Keep the language.", slot: 5),
        TransformItem(name: "Email", prompt: "Turn the text into a well structured email with greeting and sign-off placeholders. Keep the language.", slot: 6),
    ]

    func tone(for category: AppCategory) -> Tone { tones[category.rawValue] ?? .formal }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var s: AppSettings {
        didSet { save() }
    }

    private init() {
        var loaded = SettingsStore.load()
        // 1.2: transform "Polish" renamed.
        for i in loaded.transforms.indices where loaded.transforms[i].name == "Polish" { loaded.transforms[i].name = "Rifinisci / Refine" }
        s = loaded
    }

    /// Loads settings, filling keys missing from older files with defaults.
    private static func load() -> AppSettings {
        let defaults = AppSettings()
        guard let data = try? Data(contentsOf: Paths.settings),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return defaults }
        for (k, v) in stored { merged[k] = v }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let result = try? JSONDecoder().decode(AppSettings.self, from: mergedData)
        else { return defaults }
        return result
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: Paths.settings, options: .atomic) }
    }
}

/// Bilingual UI string: picks Italian or English according to settings.
func L(_ it: String, _ en: String) -> String {
    SettingsStore.shared.s.uiLanguage == "en" ? en : it
}
