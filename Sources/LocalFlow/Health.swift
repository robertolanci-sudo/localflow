import AppKit
import AVFoundation
import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

struct HealthIssue: Identifiable, Hashable {
    enum Kind: String { case accessibility, hotkey, microphone, whisper, ollama, ollamaModel, preferredMic }
    var kind: Kind
    var message: String
    var fixTitle: String?
    var id: String { kind.rawValue }
    /// Blocking issues stop dictation; others only degrade it.
    var isBlocking: Bool { [.accessibility, .hotkey, .microphone, .whisper].contains(kind) }
}

/// Periodically checks permissions and local engines so failures are visible instead of silent.
final class HealthMonitor: ObservableObject {
    static let shared = HealthMonitor()
    @Published private(set) var issues: [HealthIssue] = []

    /// Called with issues that just appeared.
    var onNewIssues: (([HealthIssue]) -> Void)?
    var onChange: (() -> Void)?

    var isHotkeyActive: () -> Bool = { true }
    var isWhisperReady: () -> Bool = { true }
    var isWhisperStarting: () -> Bool = { false }

    private var timer: Timer?
    private var ollamaIssues: [HealthIssue] = []
    private var lastOllamaCheck = Date.distantPast
    private let llm = LLMClient()

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check(forceOllama: true) }
    }

    func check(forceOllama: Bool = false) {
        let settings = SettingsStore.shared.s
        var found: [HealthIssue] = []
        if !AXIsProcessTrusted() {
            found.append(HealthIssue(kind: .accessibility,
                                     message: L("Permesso Accessibilità mancante: il tasto dettatura non funziona", "Accessibility permission missing: the dictation key won't work"),
                                     fixTitle: L("Concedi…", "Grant…")))
        } else if !isHotkeyActive() {
            found.append(HealthIssue(kind: .hotkey, message: L("Tasto dettatura non attivo", "Dictation key not active"),
                                     fixTitle: L("Riattiva", "Re-enable")))
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            found.append(HealthIssue(kind: .microphone, message: L("Accesso al microfono negato", "Microphone access denied"),
                                     fixTitle: L("Apri impostazioni…", "Open settings…")))
        default: break
        }
        if !isWhisperReady() && !isWhisperStarting() {
            found.append(HealthIssue(kind: .whisper, message: L("Motore vocale whisper fermo", "Whisper speech engine stopped"),
                                     fixTitle: L("Riavvia", "Restart")))
        }
        if !settings.microphoneUID.isEmpty, AudioDevices.deviceID(forUID: settings.microphoneUID) == nil {
            found.append(HealthIssue(kind: .preferredMic,
                                     message: L("Microfono preferito non collegato: uso quello predefinito", "Preferred microphone not connected: using the default one")))
        }

        if settings.llmEnabled, forceOllama || Date().timeIntervalSince(lastOllamaCheck) > 30 {
            lastOllamaCheck = Date()
            let model = settings.ollamaModel
            llm.availableModels { [weak self] models in
                guard let self else { return }
                if let models {
                    let installed = models.contains { $0 == model || $0 == model + ":latest" || $0.hasPrefix(model + ":") && !model.contains(":") }
                    self.ollamaIssues = installed ? [] : [HealthIssue(kind: .ollamaModel,
                        message: L("Modello \(model) non installato in Ollama: uso la pulizia di base", "Model \(model) not installed in Ollama: using basic cleanup"))]
                } else {
                    self.ollamaIssues = [HealthIssue(kind: .ollama,
                        message: L("Ollama non raggiungibile: uso la pulizia di base", "Ollama not reachable: using basic cleanup"),
                        fixTitle: L("Avvia Ollama", "Start Ollama"))]
                }
                self.publish(found + self.ollamaIssues)
            }
        } else {
            if !settings.llmEnabled { ollamaIssues = [] }
            publish(found + ollamaIssues)
        }
    }

    private func publish(_ new: [HealthIssue]) {
        let old = Set(issues.map(\.kind))
        let appeared = new.filter { !old.contains($0.kind) }
        guard new != issues else { return }
        issues = new
        onChange?()
        if !appeared.isEmpty { onNewIssues?(appeared) }
    }

    static func startOllama() {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
            return
        }
        for path in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            return
        }
    }
}
