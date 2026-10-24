import Foundation

struct TranscriptionResult {
    var text: String
    /// "it", "en" or another ISO code returned by whisper.
    var language: String
}

/// Runs a local whisper.cpp server (Metal accelerated) and sends it audio for transcription.
final class Transcriber {
    private var process: Process?
    private(set) var isReady = false
    private(set) var isStarting = false
    private var restartTimes: [Date] = []
    private var settings: AppSettings { SettingsStore.shared.s }
    var onStatusChange: ((String) -> Void)?

    static func findServerBinary() -> String? {
        let custom = SettingsStore.shared.s.whisperServerPath
        // Prefer the universal binary shipped inside the app bundle.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-server").path ?? ""
        let candidates = [custom, bundled, "/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func findModel() -> String? {
        let custom = SettingsStore.shared.s.whisperModelPath
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) { return custom }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        let models = files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.contains("silero") }
        let preferred = ["large-v3-turbo", "large-v3", "medium", "small", "base"]
        for p in preferred {
            if let m = models.first(where: { $0.contains(p) }) { return Paths.models.appendingPathComponent(m).path }
        }
        return models.first.map { Paths.models.appendingPathComponent($0).path }
    }

    static func findVADModel() -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        return files.first { $0.contains("silero") && $0.hasSuffix(".bin") }.map { Paths.models.appendingPathComponent($0).path }
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.whisperPort)")! }

    func start() {
        stop()
        isStarting = true
        defer { if process == nil { isStarting = false } }
        guard let bin = Transcriber.findServerBinary() else {
            onStatusChange?(L("whisper-server non trovato (brew install whisper-cpp)", "whisper-server not found (brew install whisper-cpp)"))
            return
        }
        guard let model = Transcriber.findModel() else {
            onStatusChange?(L("Modello whisper mancante in \(Paths.models.path)", "Whisper model missing in \(Paths.models.path)"))
            return
        }
        // Kill a server left behind by a previous crash on the same port.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "whisper-server.*--port \(settings.whisperPort)"]
        try? pkill.run(); pkill.waitUntilExit()

        let threads = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        var args = ["-m", model, "--host", "127.0.0.1", "--port", "\(settings.whisperPort)",
                    "-l", "auto", "-nt", "-t", "\(threads)"]
        if let vad = Transcriber.findVADModel() { args += ["--vad", "-vm", vad] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReady = false
                self.isStarting = false
                self.onStatusChange?(L("Server whisper terminato", "Whisper server stopped"))
                self.restartAfterCrash()
            }
        }
        do {
            try p.run()
            process = p
            onStatusChange?(L("Caricamento modello vocale…", "Loading speech model…"))
            waitUntilReady(attempts: 120)
        } catch {
            onStatusChange?("whisper-server: \(error.localizedDescription)")
        }
    }

    private func waitUntilReady(attempts: Int) {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.isReady = true
                    self.isStarting = false
                    self.onStatusChange?(L("Pronto", "Ready"))
                } else if attempts > 0, self.process?.isRunning == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitUntilReady(attempts: attempts - 1) }
                } else {
                    self.isStarting = false
                    self.onStatusChange?(L("Il server whisper non risponde", "Whisper server not responding"))
                }
            }
        }.resume()
    }

    /// Restarts a crashed server, at most 3 times in 5 minutes to avoid a crash loop.
    private func restartAfterCrash() {
        restartTimes = restartTimes.filter { Date().timeIntervalSince($0) < 300 }
        guard restartTimes.count < 3 else { return }
        restartTimes.append(Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process == nil || self.process?.isRunning == false else { return }
            self.start()
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isReady = false
        isStarting = false
    }

    /// Transcribes 16 kHz mono samples. `language` is "auto", "it" or "en".
    func transcribe(_ samples: [Float], language: String, prompt: String,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
        let wav = AudioUtils.wavData(samples)
        let boundary = "LocalFlow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "verbose_json")
        field("temperature", "0.0")
        field("language", language)
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, _, error in
            let result: Result<TranscriptionResult, Error>
            if let error {
                result = .failure(error)
            } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let text = (json["text"] as? String) ?? ""
                let lang = Transcriber.normalizeLanguage((json["detected_language"] as? String) ?? (json["language"] as? String) ?? language)
                result = .success(TranscriptionResult(text: Transcriber.cleanHallucinations(text), language: lang))
            } else {
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(NSError(domain: "LocalFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "whisper: \(raw.prefix(200))"]))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func normalizeLanguage(_ value: String) -> String {
        let v = value.lowercased()
        if v == "it" || v.hasPrefix("ital") { return "it" }
        if v == "en" || v.hasPrefix("engl") { return "en" }
        return v
    }

    /// Strips whisper's typical silence hallucinations and annotations.
    static func cleanHallucinations(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*(musica|music|applausi|applause|risate|laughter|silenzio|silence)[^)]*\)"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        let junk = [
            "sottotitoli creati dalla comunità amara.org", "sottotitoli a cura di qtss", "sottotitoli e revisione a cura di qtss",
            "grazie per la visione", "grazie a tutti per la visione", "thanks for watching", "thank you for watching",
            "please subscribe", "iscriviti al canale",
        ]
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        if junk.contains(lowered) { return "" }
        t = trimmed
        // Hallucinated outros only appear as a trailing sentence.
        for j in junk {
            if let r = t.range(of: j, options: [.caseInsensitive, .backwards]),
               t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")).isEmpty {
                t = String(t[..<r.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
