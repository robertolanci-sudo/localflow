import AppKit
import AVFoundation
import SwiftUI

struct WhisperModelOption: Identifiable, Hashable {
    var id: String { file }
    var file: String
    var title: String
    var detail: String
    var sizeMB: Int

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    static let all: [WhisperModelOption] = [
        WhisperModelOption(file: "ggml-large-v3-turbo-q5_0.bin", title: L("Massima qualità", "Best quality"),
                           detail: L("large-v3-turbo · consigliato su Apple Silicon", "large-v3-turbo · recommended on Apple Silicon"), sizeMB: 574),
        WhisperModelOption(file: "ggml-small-q5_1.bin", title: L("Veloce", "Fast"),
                           detail: L("small · consigliato su Mac Intel", "small · recommended on Intel Macs"), sizeMB: 190),
        WhisperModelOption(file: "ggml-base-q5_1.bin", title: L("Leggero", "Light"),
                           detail: L("base · Mac vecchi, qualità inferiore", "base · older Macs, lower quality"), sizeMB: 60),
    ]
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    static var recommended: WhisperModelOption { SystemInfo.isAppleSilicon ? all[0] : all[1] }
}

enum SystemInfo {
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Also true when an Intel build runs under Rosetta on Apple Silicon.
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { return value == 1 }
        return false
    }
    static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    /// Local LLM sized for this Mac.
    static var recommendedLLM: String { isAppleSilicon && memoryGB >= 16 ? "qwen2.5:7b" : "qwen2.5:3b" }
}

/// Downloads a file with progress and automatic resume on flaky connections.
final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress = 0.0
    @Published var running = false
    @Published var error = ""
    private var session: URLSession!
    private var destination: URL?
    private var source: URL?
    private var attempts = 0
    private var completion: ((Bool) -> Void)?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func download(_ url: URL, to destination: URL, completion: @escaping (Bool) -> Void) {
        self.source = url
        self.destination = destination
        self.completion = completion
        attempts = 0
        error = ""
        progress = 0
        running = true
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            error = "HTTP \(http.statusCode)"
            return
        }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if attempts < 20 {
                attempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let source = self.source else { return }
                    let next = resumeData.map { self.session.downloadTask(withResumeData: $0) } ?? self.session.downloadTask(with: source)
                    next.resume()
                }
                return
            }
            self.error = error.localizedDescription
        }
        running = false
        let ok = self.error.isEmpty && destination.map { FileManager.default.fileExists(atPath: $0.path) } == true
        completion?(ok)
        completion = nil
    }
}

/// Pulls an Ollama model through its HTTP API, streaming progress.
final class OllamaPuller: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var progress = 0.0
    @Published var status = ""
    @Published var running = false
    private var buffer = Data()
    private var completion: ((Bool) -> Void)?
    private var failed = false

    func pull(_ model: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: SettingsStore.shared.s.ollamaURL)?.appendingPathComponent("api/pull") else { return }
        self.completion = completion
        failed = false
        running = true
        status = L("Avvio download…", "Starting download…")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session.dataTask(with: req).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let error = json["error"] as? String { status = error; failed = true }
            if let s = json["status"] as? String { status = s }
            if let total = json["total"] as? Double, let done = json["completed"] as? Double, total > 0 { progress = done / total }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        running = false
        if let error { status = error.localizedDescription; failed = true }
        let ok = !failed && status == "success"
        completion?(ok)
        completion = nil
        session.finishTasksAndInvalidate()
    }
}

struct OnboardingView: View {
    @ObservedObject var store = SettingsStore.shared
    var onModelReady: () -> Void
    var onDone: () -> Void

    @StateObject private var downloader = Downloader()
    @StateObject private var puller = OllamaPuller()
    @State private var selectedModel = WhisperModelOption.recommended
    @State private var installedModel = Transcriber.findModel()
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var ollamaModels: [String]?
    @State private var llmChoice = SystemInfo.recommendedLLM
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Benvenuto in LocalFlow", "Welcome to LocalFlow")).font(.largeTitle.bold())
                Text(L("Dettatura vocale in italiano e inglese che funziona interamente sul tuo Mac.",
                       "Italian and English voice dictation that runs entirely on your Mac."))
                    .foregroundColor(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, L("Modello vocale", "Speech model"), done: installedModel != nil) { modelStep }
                    step(2, L("Permessi", "Permissions"), done: axTrusted && micStatus == .authorized) { permissionsStep }
                    step(3, L("Pulizia intelligente (facoltativa)", "Smart cleanup (optional)"), done: llmInstalled) { llmStep }
                    step(4, L("Prova", "Try it"), done: false) { tryStep }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text(L("Puoi riaprire questa guida dal menu di LocalFlow.", "You can reopen this guide from the LocalFlow menu."))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L("Fine", "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(installedModel == nil)
            }
            .padding(16)
        }
        .frame(width: 640, height: 720)
        .onReceive(refresh) { _ in refreshState() }
        .onAppear { refreshState() }
    }

    private var llmInstalled: Bool {
        guard let models = ollamaModels else { return false }
        let m = store.s.ollamaModel
        return models.contains { $0 == m || $0 == m + ":latest" }
    }

    private func refreshState() {
        axTrusted = AXIsProcessTrusted()
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        installedModel = Transcriber.findModel()
        if !puller.running { LLMClient().availableModels { ollamaModels = $0 } }
    }

    @ViewBuilder private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 28, height: 28)
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white) }
                else { Text("\(n)").font(.headline).foregroundColor(.accentColor) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold())
                content()
            }
        }
    }

    @ViewBuilder private var modelStep: some View {
        if let installedModel {
            Text(L("Installato: ", "Installed: ") + URL(fileURLWithPath: installedModel).lastPathComponent).foregroundColor(.secondary)
        } else {
            Text(L("Scarica il modello di riconoscimento vocale (una volta sola).", "Download the speech recognition model (one time)."))
                .foregroundColor(.secondary)
            Picker("", selection: $selectedModel) {
                ForEach(WhisperModelOption.all) { m in
                    Text("\(m.title) — \(m.detail) — \(m.sizeMB) MB").tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(downloader.running)
            if downloader.running {
                ProgressView(value: downloader.progress) {
                    Text(L("Download… \(Int(downloader.progress * 100))%", "Downloading… \(Int(downloader.progress * 100))%")).font(.caption)
                }
            } else {
                Button(L("Scarica \(selectedModel.sizeMB) MB", "Download \(selectedModel.sizeMB) MB"), action: downloadModel)
                    .buttonStyle(.borderedProminent)
            }
            if !downloader.error.isEmpty { Text(downloader.error).font(.caption).foregroundColor(.red) }
        }
    }

    private func downloadModel() {
        let model = selectedModel
        downloader.download(model.url, to: Paths.models.appendingPathComponent(model.file)) { ok in
            guard ok else { return }
            installedModel = Transcriber.findModel()
            // Small VAD model: reduces hallucinations on silence. Best effort.
            let vad = Paths.models.appendingPathComponent("ggml-silero-v5.1.2.bin")
            if !FileManager.default.fileExists(atPath: vad.path) {
                URLSession.shared.downloadTask(with: WhisperModelOption.vadURL) { tmp, response, _ in
                    guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                    try? FileManager.default.moveItem(at: tmp, to: vad)
                    DispatchQueue.main.async(execute: onModelReady)
                }.resume()
            }
            onModelReady()
        }
    }

    @ViewBuilder private var permissionsStep: some View {
        HStack {
            Image(systemName: micStatus == .authorized ? "checkmark.circle.fill" : "mic.circle")
                .foregroundColor(micStatus == .authorized ? .green : .orange)
            Text(L("Microfono", "Microphone"))
            Spacer()
            if micStatus == .notDetermined {
                Button(L("Consenti", "Allow")) { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            } else if micStatus != .authorized {
                Button(L("Apri impostazioni", "Open settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        }
        HStack {
            Image(systemName: axTrusted ? "checkmark.circle.fill" : "keyboard")
                .foregroundColor(axTrusted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(L("Accessibilità", "Accessibility"))
                Text(L("Serve per il tasto dettatura e per incollare il testo nelle altre app.", "Needed for the dictation key and to paste text into other apps."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !axTrusted {
                Button(L("Consenti", "Allow")) {
                    Paster.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
    }

    @ViewBuilder private var llmStep: some View {
        Text(L("Con un LLM locale (Ollama) LocalFlow rimuove intercalari, applica le autocorrezioni (\"anzi…\"), formatta elenchi, adatta il tono e abilita modalità comando, azioni rapide e riassunti. Senza, usa una pulizia di base.",
               "With a local LLM (Ollama) LocalFlow removes fillers, applies self-corrections, formats lists, adapts tone and enables command mode, quick actions and summaries. Without it, basic cleanup is used."))
            .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        if ollamaModels == nil {
            HStack {
                Button(L("Scarica Ollama", "Download Ollama")) { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
                    .buttonStyle(.borderedProminent)
                Button(L("Ho già Ollama: avvialo", "I have Ollama: start it")) { HealthMonitor.startOllama() }
            }
            Text(L("Dopo l'installazione apri Ollama: questo passaggio si aggiorna da solo.", "After installing, open Ollama: this step updates by itself."))
                .font(.caption).foregroundColor(.secondary)
        } else if llmInstalled {
            Text(L("Modello pronto: ", "Model ready: ") + store.s.ollamaModel).foregroundColor(.secondary)
            Toggle(L("Usa la pulizia intelligente", "Use smart cleanup"), isOn: $store.s.llmEnabled)
        } else {
            Picker(L("Modello", "Model"), selection: $llmChoice) {
                Text(L("qwen2.5:7b — migliore (4,7 GB, ≥16 GB RAM)", "qwen2.5:7b — best (4.7 GB, ≥16 GB RAM)")).tag("qwen2.5:7b")
                Text(L("qwen2.5:3b — più veloce (1,9 GB)", "qwen2.5:3b — faster (1.9 GB)")).tag("qwen2.5:3b")
            }
            .disabled(puller.running)
            if puller.running {
                ProgressView(value: puller.progress) { Text(puller.status).font(.caption) }
            } else {
                Button(L("Installa modello", "Install model")) {
                    let model = llmChoice
                    puller.pull(model) { ok in
                        if ok {
                            store.s.ollamaModel = model
                            store.s.llmEnabled = true
                            LLMClient().warmup()
                        }
                        refreshState()
                    }
                }
                .buttonStyle(.borderedProminent)
                if !puller.status.isEmpty { Text(puller.status).font(.caption).foregroundColor(.secondary) }
            }
        }
    }

    @ViewBuilder private var tryStep: some View {
        Text(L("Clicca in un campo di testo, tieni premuto \(store.s.hotkey.label), parla, rilascia. Doppio tocco per mani libere.",
               "Click a text field, hold \(store.s.hotkey.label), speak, release. Double-tap for hands-free."))
            .foregroundColor(.secondary)
        if store.s.hotkey == .fn {
            Text(L("Consiglio: Impostazioni di Sistema › Tastiera › \"Premi il tasto 🌐 per\" → \"Non fare nulla\".",
                   "Tip: System Settings › Keyboard › \"Press 🌐 key to\" → \"Do Nothing\"."))
                .font(.caption).foregroundColor(.orange)
        }
        Picker(L("Tasto dettatura", "Dictation key"), selection: $store.s.hotkey) {
            ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
        }
        .frame(maxWidth: 320)
        Picker(L("Lingua interfaccia", "Interface language"), selection: $store.s.uiLanguage) {
            Text("Italiano").tag("it")
            Text("English").tag("en")
        }
        .frame(maxWidth: 320)
    }
}
