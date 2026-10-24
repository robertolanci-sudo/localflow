import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// One audio/video file being transcribed.
final class FileJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var progress = 0.0
    @Published var status = L("In coda", "Queued")
    @Published var text = ""
    @Published var summary = ""
    @Published var language = ""
    @Published var duration = 0.0
    @Published var done = false
    @Published var failed = false
    @Published var summarizing = false
    var cancelled = false

    init(url: URL) { self.url = url }
    var name: String { url.lastPathComponent }
}

enum AudioFileDecoder {
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Decodes any audio/video file to 16 kHz mono Float32 (AVFoundation first, ffmpeg for Opus/OGG/WebM…).
    static func decode(_ url: URL) async throws -> [Float] {
        if let samples = try? await decodeWithAVFoundation(url), !samples.isEmpty { return samples }
        guard let ffmpeg = ffmpegPath else {
            throw NSError(domain: "LocalFlow", code: 10, userInfo: [NSLocalizedDescriptionKey:
                L("Formato non supportato (installa ffmpeg: brew install ffmpeg)", "Unsupported format (install ffmpeg: brew install ffmpeg)")])
        }
        return try decodeWithFFmpeg(url, ffmpeg: ffmpeg)
    }

    private static func decodeWithAVFoundation(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "LocalFlow", code: 11) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "LocalFlow", code: 12) }
        return samples
    }

    private static func decodeWithFFmpeg(_ url: URL, ffmpeg: String) throws -> [Float] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-loglevel", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else {
            throw NSError(domain: "LocalFlow", code: 13, userInfo: [NSLocalizedDescriptionKey: L("Impossibile leggere l'audio del file", "Could not read audio from file")])
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Splits audio into ≤30 s windows (whisper's context), cutting at the quietest point near each boundary.
    static func chunkRanges(_ samples: [Float], rate: Double = AudioRecorder.sampleRate) -> [Range<Int>] {
        let target = Int(rate * 28), searchFrom = Int(rate * 22), window = Int(rate * 0.02)
        var ranges: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            if samples.count - start <= target {
                ranges.append(start..<samples.count)
                break
            }
            var bestCut = start + target
            var bestEnergy = Float.greatestFiniteMagnitude
            var i = start + searchFrom
            while i + window <= start + target {
                var e: Float = 0
                for j in i..<(i + window) { e += samples[j] * samples[j] }
                if e < bestEnergy { bestEnergy = e; bestCut = i + window / 2 }
                i += window
            }
            ranges.append(start..<bestCut)
            start = bestCut
        }
        return ranges
    }
}

/// Queues files and transcribes them chunk by chunk through the local whisper server.
final class FileTranscriber: ObservableObject {
    static var shared: FileTranscriber?

    @Published var jobs: [FileJob] = []
    private let transcriber: Transcriber
    private let llm: LLMClient
    private let processor: TextProcessor
    private var running = false

    init(transcriber: Transcriber, llm: LLMClient, processor: TextProcessor) {
        self.transcriber = transcriber
        self.llm = llm
        self.processor = processor
    }

    static let supportedTypes: [UTType] = [.audio, .movie, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        + ["opus", "ogg", "oga", "webm", "mkv", "flac", "m4a", "amr"].compactMap { UTType(filenameExtension: $0) }

    func enqueue(_ urls: [URL]) {
        for url in urls { jobs.insert(FileJob(url: url), at: 0) }
        runNext()
    }

    func cancel(_ job: FileJob) {
        job.cancelled = true
        if !job.done { job.status = L("Annullato", "Cancelled"); job.failed = true }
    }

    func remove(_ job: FileJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
    }

    private func runNext() {
        guard !running, let job = jobs.last(where: { !$0.done && !$0.failed && !$0.cancelled }) else { return }
        guard transcriber.isReady else {
            job.status = L("In attesa del motore vocale…", "Waiting for speech engine…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runNext() }
            return
        }
        running = true
        job.status = L("Decodifica audio…", "Decoding audio…")
        Task {
            do {
                let samples = try await AudioFileDecoder.decode(job.url)
                await MainActor.run {
                    job.duration = Double(samples.count) / AudioRecorder.sampleRate
                    self.transcribe(job, samples: samples, ranges: AudioFileDecoder.chunkRanges(samples), index: 0,
                                    language: self.fileLanguage, previous: "")
                }
            } catch {
                await MainActor.run { self.fail(job, error.localizedDescription) }
            }
        }
    }

    private var fileLanguage: String { SettingsStore.shared.s.dictationLanguage }

    private func transcribe(_ job: FileJob, samples: [Float], ranges: [Range<Int>], index: Int, language: String, previous: String) {
        if job.cancelled { return finishJob() }
        guard index < ranges.count else {
            job.done = true
            job.progress = 1
            job.status = L("Completato", "Done")
            job.text = job.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if job.text.isEmpty { job.text = L("(nessuna voce rilevata)", "(no speech detected)") }
            return finishJob()
        }
        job.status = L("Trascrivo \(index + 1)/\(ranges.count)…", "Transcribing \(index + 1)/\(ranges.count)…")
        let range = ranges[index]
        guard let chunk = AudioUtils.trimSilence(Array(samples[range])) else {
            job.progress = Double(index + 1) / Double(ranges.count)
            return transcribe(job, samples: samples, ranges: ranges, index: index + 1, language: language, previous: previous)
        }
        let prompt = [processor.whisperPrompt(), String(previous.suffix(150))].filter { !$0.isEmpty }.joined(separator: " ")
        transcriber.transcribe(chunk, language: language, prompt: prompt) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(job, error.localizedDescription)
            case .success(let r):
                // Lock the language detected on the first chunk so the rest of the file stays consistent.
                let lang = language == "auto" ? r.language : language
                if job.language.isEmpty { job.language = lang }
                if !r.text.isEmpty {
                    if SettingsStore.shared.s.fileTimestamps {
                        job.text += "[\(FileTranscriber.timestamp(Double(range.lowerBound) / AudioRecorder.sampleRate))] \(r.text)\n\n"
                    } else {
                        job.text += r.text + " "
                    }
                }
                job.progress = Double(index + 1) / Double(ranges.count)
                self.transcribe(job, samples: samples, ranges: ranges, index: index + 1, language: lang,
                                previous: r.text.isEmpty ? previous : r.text)
            }
        }
    }

    private func fail(_ job: FileJob, _ message: String) {
        job.failed = true
        job.status = L("Errore: ", "Error: ") + message
        finishJob()
    }

    private func finishJob() {
        running = false
        runNext()
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Summary

    /// Summary, key points and to-dos; long transcripts are summarized in parts first (map-reduce).
    func summarize(_ job: FileJob) {
        guard SettingsStore.shared.s.llmEnabled else {
            job.summary = L("Attiva l'LLM locale nelle impostazioni per i riassunti.", "Enable the local LLM in settings for summaries.")
            return
        }
        job.summarizing = true
        job.summary = ""
        let text = job.text.replacingOccurrences(of: #"\[\d{1,2}:\d{2}(:\d{2})?\] "#, with: "", options: .regularExpression)
        let parts = FileTranscriber.split(text, maxChars: 6000)
        let language = job.language == "en" ? "English" : job.language == "it" ? "Italian" : "the language of the transcript"
        summarizeParts(parts, index: 0, notes: [], language: language, job: job)
    }

    private func summarizeParts(_ parts: [String], index: Int, notes: [String], language: String, job: FileJob) {
        if parts.count == 1 || index == parts.count {
            let input = parts.count == 1 ? parts[0] : notes.joined(separator: "\n\n")
            let system = """
            You summarize transcripts of recordings (voice notes, meetings, calls). Write in \(language), in Markdown, with these sections:
            a 2-4 sentence summary; "Punti chiave"/"Key points" as bullets; "Da fare"/"Action items" as bullets with owner and deadline when mentioned (omit the section if there are none).
            Be faithful: never invent facts. Output only the Markdown.
            """
            llm.chat([.init(role: "system", content: system), .init(role: "user", content: input)], timeout: 300) { result in
                job.summarizing = false
                switch result {
                case .success(let s): job.summary = s
                case .failure(let e): job.summary = "Ollama: \(e.localizedDescription)"
                }
            }
            return
        }
        job.summary = L("Riassumo parte \(index + 1)/\(parts.count)…", "Summarizing part \(index + 1)/\(parts.count)…")
        let system = "Write dense notes in \(language) of this part of a transcript: facts, decisions, names, numbers, tasks. Output only the notes."
        llm.chat([.init(role: "system", content: system), .init(role: "user", content: parts[index])], timeout: 300) { [weak self] result in
            var notes = notes
            if case .success(let n) = result { notes.append(n) }
            self?.summarizeParts(parts, index: index + 1, notes: notes, language: language, job: job)
        }
    }

    static func split(_ text: String, maxChars: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            let s = sentence.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if current.count + s.count > maxChars, !current.isEmpty { parts.append(current); current = "" }
            current += s + ". "
        }
        if !current.isEmpty { parts.append(current) }
        return parts.isEmpty ? [text] : parts
    }
}

// MARK: - UI

struct FilesView: View {
    @ObservedObject var model: FileTranscriber
    @State private var selection: UUID?
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.jobs) { job in
                    JobRow(job: job).tag(job.id)
                        .contextMenu {
                            Button(L("Rimuovi", "Remove")) { model.remove(job) }
                        }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(L("Scegli file…", "Choose files…"), action: choose).padding(8)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let job = model.jobs.first(where: { $0.id == selection }) {
                JobDetail(job: job, model: model)
            } else {
                dropZone
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FilesView.loadURLs(providers) { urls in
                model.enqueue(urls)
                selection = model.jobs.first?.id
            }
            return true
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: model.jobs.count) { _ in if selection == nil { selection = model.jobs.first?.id } }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 42)).foregroundColor(.secondary)
            Text(L("Trascina qui file audio o video", "Drop audio or video files here")).font(.title3)
            Text(L("Vocali WhatsApp, registrazioni, riunioni, podcast, video (mp3, m4a, wav, opus, mp4, mov…). Tutto in locale.",
                   "Voice notes, recordings, meetings, podcasts, videos (mp3, m4a, wav, opus, mp4, mov…). All local."))
                .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(L("Scegli file…", "Choose files…"), action: choose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundColor(dropTargeted ? .accentColor : .secondary.opacity(0.4)).padding(20))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FileTranscriber.supportedTypes
        if panel.runModal() == .OK {
            model.enqueue(panel.urls)
            selection = model.jobs.first?.id
        }
    }

    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { completion(urls) } }
    }
}

private struct JobRow: View {
    @ObservedObject var job: FileJob
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.name).lineLimit(1)
            if !job.done && !job.failed {
                ProgressView(value: job.progress)
            }
            Text(job.status).font(.caption).foregroundColor(job.failed ? .red : .secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct JobDetail: View {
    @ObservedObject var job: FileJob
    let model: FileTranscriber

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(job.name).font(.headline)
                    Text("\(FileTranscriber.timestamp(job.duration)) · \(job.language.uppercased()) · \(job.status)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !job.done && !job.failed {
                    Button(L("Annulla", "Cancel")) { model.cancel(job) }
                }
                Button(L("Copia", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.summary.isEmpty ? job.text : job.summary + "\n\n---\n\n" + job.text, forType: .string)
                }.disabled(job.text.isEmpty)
                Button(L("Salva…", "Save…"), action: save).disabled(job.text.isEmpty)
                Button(job.summarizing ? L("Riassumo…", "Summarizing…") : L("Riassumi", "Summarize")) { model.summarize(job) }
                    .disabled(!job.done || job.summarizing)
            }
            if !job.done && !job.failed { ProgressView(value: job.progress) }
            if !job.summary.isEmpty {
                ScrollView {
                    Text((try? AttributedString(markdown: job.summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(job.summary))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            ScrollView {
                Text(job.text.isEmpty ? L("La trascrizione apparirà qui…", "Transcript will appear here…") : job.text)
                    .textSelection(.enabled)
                    .foregroundColor(job.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.url.deletingPathExtension().lastPathComponent + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var out = "# \(job.name)\n\n"
        if !job.summary.isEmpty { out += job.summary + "\n\n---\n\n" }
        out += job.text
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}
