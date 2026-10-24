import AppKit
import AVFoundation
import SwiftUI

final class AppController: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let llm = LLMClient()
    private lazy var processor = TextProcessor(llm: llm)
    private let hotkeys = HotkeyMonitor()
    private let flowBar = FlowBarController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var scratchpadWindow: NSWindow?
    private var filesWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private lazy var fileTranscriber = FileTranscriber(transcriber: transcriber, llm: llm, processor: processor)
    private let learner = CorrectionLearner()
    private let health = HealthMonitor.shared
    private var pendingSuggestion: CorrectionLearner.Suggestion?
    /// Field context captured when recording starts (read off the main thread).
    private var focus = FocusContext.empty
    private var engineStatus = ""

    private enum Mode { case idle, holding, pendingTap, handsFree, processing }
    private var mode: Mode = .idle
    private var commandMode = false
    private var pressTime = Date()
    private var recordStart = Date()
    private var tapTimer: Timer?
    private var targetApp: NSRunningApplication?
    private var lastText: String?
    private var hotkeyRetryTimer: Timer?

    /// Streaming: pieces of a long dictation sent to whisper while the user is still speaking.
    private var session = UUID()
    private var streamTimer: Timer?
    private var committedSamples = 0
    private var segments: [Int: (text: String, language: String)] = [:]
    private var segmentsSent = 0
    private var onSegmentsDone: (() -> Void)?

    /// A press shorter than this is a tap (double-tap = hands-free).
    private let tapThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.4

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        flowBar.onClick = { [weak self] in self?.flowBarClicked() }
        flowBar.onCancel = { [weak self] in self?.cancelRecording() }
        flowBar.onStop = { [weak self] in self?.finishRecording() }
        recorder.onLevel = { [weak self] level in self?.flowBar.state.push(level: level) }
        flowBar.onAcceptSuggestion = { [weak self] in self?.answerSuggestion(accept: true) }
        flowBar.onRejectSuggestion = { [weak self] in self?.answerSuggestion(accept: false) }
        flowBar.onDropFiles = { [weak self] urls in self?.transcribeFiles(urls) }
        learner.onSuggestion = { [weak self] s in self?.handleSuggestion(s) }
        setupHealth()

        transcriber.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.engineStatus = status
            self.flowBar.state.engineReady = self.transcriber.isReady
            self.updateMenu()
        }
        transcriber.start()
        if settings.s.llmEnabled { llm.warmup() }
        Updater.shared.startAutomaticChecks()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        hotkeys.handler = { [weak self] event in self?.handle(event) ?? false }
        startHotkeys()

        if Transcriber.findModel() == nil || !UserDefaults.standard.bool(forKey: "setupDone") {
            openOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.stop()
        SystemAudio.restore()
    }

    /// The event tap needs Accessibility permission; keep retrying until it is granted.
    private func startHotkeys() {
        if hotkeys.start() { return }
        Paster.requestAccessibility()
        hotkeyRetryTimer?.invalidate()
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.hotkeys.start() == true {
                timer.invalidate()
                self?.updateMenu()
            }
        }
    }

    // MARK: - Status menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "LocalFlow")
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: "LocalFlow — \(engineStatus.isEmpty ? L("Avvio…", "Starting…") : engineStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for issue in health.issues {
            let i = item("⚠︎ " + issue.message + (issue.fixTitle.map { " — " + $0 } ?? ""), #selector(fixIssueFromMenu(_:)))
            i.representedObject = issue.kind.rawValue
            menu.addItem(i)
        }
        let s = settings.s
        func withShortcut(_ title: String, _ k: KeyShortcut) -> String { k.isEmpty ? title : "\(title)  \(k.display)" }
        menu.addItem(.separator())
        menu.addItem(item(withShortcut(L("Incolla ultima trascrizione", "Paste last transcript"), s.pasteLastShortcut), #selector(pasteLastAction)))
        menu.addItem(item(withShortcut(L("Note rapide", "Quick notes"), s.scratchpadShortcut), #selector(openScratchpad)))
        menu.addItem(item(withShortcut(L("Trascrivi file audio/video…", "Transcribe audio/video files…"), s.transcribeFileShortcut), #selector(openFilesWindow)))
        menu.addItem(item(L("Aggiungi selezione al dizionario", "Add selection to dictionary"), #selector(addSelectionToDictionary)))
        menu.addItem(.separator())
        let lang = NSMenuItem(title: L("Lingua parlata", "Spoken language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, title) in [("auto", L("Automatica IT/EN", "Automatic IT/EN")), ("it", "Italiano"), ("en", "English")] {
            let i = item(title, #selector(setLanguage(_:)))
            i.representedObject = code
            i.state = settings.s.dictationLanguage == code ? .on : .off
            langMenu.addItem(i)
        }
        lang.submenu = langMenu
        menu.addItem(lang)
        menu.addItem(item(L("Impostazioni…", "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(item(L("Configurazione guidata…", "Setup guide…"), #selector(openOnboarding)))
        menu.addItem(item(L("Controlla aggiornamenti…", "Check for updates…"), #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item(L("Esci", "Quit"), #selector(quit), key: "q"))
        statusItem.menu = menu
        let symbol = health.issues.contains(where: \.isBlocking) ? "exclamationmark.triangle" : "waveform"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LocalFlow")
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: - Health

    private func setupHealth() {
        health.isHotkeyActive = { [weak self] in self?.hotkeys.isActive ?? false }
        health.isWhisperReady = { [weak self] in self?.transcriber.isReady ?? false }
        health.isWhisperStarting = { [weak self] in self?.transcriber.isStarting ?? false }
        health.onChange = { [weak self] in self?.updateMenu() }
        health.onNewIssues = { [weak self] issues in
            guard let self, !self.flowBar.isBusy, let first = issues.first(where: \.isBlocking) ?? issues.first else { return }
            self.flowBar.show(message: "⚠︎ " + first.message, seconds: 5)
        }
        health.start()
    }

    func fix(_ issue: HealthIssue) {
        switch issue.kind {
        case .accessibility:
            grantAccessibility()
        case .hotkey:
            startHotkeys()
        case .microphone:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .whisper:
            transcriber.start()
        case .ollama:
            HealthMonitor.startOllama()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.health.check(forceOllama: true) }
        case .ollamaModel, .preferredMic:
            openSettings()
        }
    }

    @objc private func fixIssueFromMenu(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String,
              let issue = health.issues.first(where: { $0.kind.rawValue == kind }) else { return }
        fix(issue)
    }

    // MARK: - Dictionary learning

    private func handleSuggestion(_ s: CorrectionLearner.Suggestion) {
        switch settings.s.autoLearn {
        case .off:
            return
        case .auto:
            addToDictionary(s)
            if !flowBar.isBusy { flowBar.show(message: L("Aggiunto al dizionario: \(s.right)", "Added to dictionary: \(s.right)")) }
        case .suggest:
            guard !flowBar.isBusy else { return }
            pendingSuggestion = s
            flowBar.ask(L("Aggiungo \"\(s.right)\" al dizionario?", "Add \"\(s.right)\" to dictionary?"))
        }
    }

    private func answerSuggestion(accept: Bool) {
        guard let s = pendingSuggestion else { return flowBar.set(.idle) }
        pendingSuggestion = nil
        if accept {
            addToDictionary(s)
            flowBar.show(message: L("Aggiunto: \(s.right)", "Added: \(s.right)"), seconds: 1.5)
        } else {
            learner.dismiss(s)
            flowBar.set(.idle)
        }
    }

    private func addToDictionary(_ s: CorrectionLearner.Suggestion) {
        if let i = settings.s.dictionary.firstIndex(where: { $0.word == s.right }) {
            let variants = settings.s.dictionary[i].misspellings
            if !variants.localizedCaseInsensitiveContains(s.wrong) {
                settings.s.dictionary[i].misspellings = variants.isEmpty ? s.wrong : variants + ", " + s.wrong
            }
        } else {
            let variant = s.wrong.lowercased() == s.right.lowercased() ? "" : s.wrong
            settings.s.dictionary.insert(DictionaryEntry(word: s.right, misspellings: variant), at: 0)
        }
    }

    // MARK: - Onboarding

    @objc func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onModelReady: { [weak self] in self?.transcriber.start() },
                onDone: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "setupDone")
                    self?.onboardingWindow?.close()
                    if self?.transcriber.isReady == false { self?.transcriber.start() }
                    self?.startHotkeys()
                })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "LocalFlow"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - File transcription

    @objc private func openFilesWindow() {
        FileTranscriber.shared = fileTranscriber
        if filesWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: FilesView(model: fileTranscriber)))
            window.title = L("LocalFlow — Trascrivi file", "LocalFlow — Transcribe files")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            filesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        filesWindow?.makeKeyAndOrderFront(nil)
    }

    private func transcribeFiles(_ urls: [URL]) {
        fileTranscriber.enqueue(urls)
        openFilesWindow()
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        settings.s.dictationLanguage = sender.representedObject as? String ?? "auto"
        updateMenu()
    }

    @objc private func grantAccessibility() {
        Paster.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func checkForUpdates() { Updater.shared.check(userInitiated: true) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(flow: flowBar.state,
                                    onRestartEngine: { [weak self] in self?.transcriber.start() },
                                    onHotkeyChange: {},
                                    onFixIssue: { [weak self] issue in self?.fix(issue) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L("LocalFlow — Impostazioni", "LocalFlow — Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        flowBar.refresh()
        updateMenu()
    }

    @objc func openScratchpad() {
        if scratchpadWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ScratchpadView()))
            window.title = L("Note rapide", "Quick notes")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            scratchpadWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        scratchpadWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func pasteLastAction() {
        // Give focus back to the previous app before pasting from the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pasteLast() }
    }

    private func pasteLast() {
        guard let text = lastText ?? HistoryStore.shared.items(limit: 1).first?.text else {
            flowBar.show(message: L("Nessuna trascrizione recente", "No recent transcript"))
            return
        }
        Paster.paste(text, restoreClipboard: settings.s.restoreClipboard)
    }

    @objc private func addSelectionToDictionary() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Paster.selectedText { [weak self] text in
                guard let self, let word = text?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty, word.count < 60 else {
                    self?.flowBar.show(message: L("Seleziona prima una parola", "Select a word first"))
                    return
                }
                if !self.settings.s.dictionary.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
                    self.settings.s.dictionary.insert(DictionaryEntry(word: word), at: 0)
                }
                self.flowBar.show(message: L("Aggiunto al dizionario: \(word)", "Added to dictionary: \(word)"))
            }
        }
    }

    // MARK: - Hotkey state machine

    private func handle(_ event: HotkeyMonitor.Event) -> Bool {
        switch event {
        case .triggerDown(let command):
            switch mode {
            case .idle:
                startRecording(command: command)
                mode = .holding
                pressTime = Date()
            case .pendingTap:
                // Second tap: switch to hands-free.
                tapTimer?.invalidate()
                mode = .handsFree
                flowBar.set(.handsFree, command: commandMode)
            case .handsFree:
                finishRecording()
            case .holding, .processing:
                break
            }
            return false
        case .triggerUp:
            guard mode == .holding else { return false }
            if Date().timeIntervalSince(pressTime) >= tapThreshold {
                finishRecording()
            } else {
                mode = .pendingTap
                tapTimer?.invalidate()
                tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self, self.mode == .pendingTap else { return }
                    self.cancelRecording(silent: true)
                    self.flowBar.show(message: L("Tieni premuto \(self.settings.s.hotkey.label) mentre parli, o doppio tocco per mani libere",
                                                 "Hold \(self.settings.s.hotkey.label) while speaking, or double-tap for hands-free"), seconds: 2)
                }
            }
            return false
        case .commandModifier:
            if mode == .holding || mode == .handsFree {
                commandMode = true
                flowBar.set(mode == .handsFree ? .handsFree : .recording, command: true)
            }
            return false
        case .escape:
            guard mode == .holding || mode == .handsFree || mode == .pendingTap else { return false }
            cancelRecording()
            return true
        case .otherKey:
            // fn+arrow, ⌥+letter etc.: the key was used as a modifier, not for dictation.
            if mode == .holding, Date().timeIntervalSince(pressTime) < 0.6 { cancelRecording(silent: true) }
            return false
        case .transform(let id):
            guard let transform = settings.s.transforms.first(where: { $0.id == id && !$0.prompt.isEmpty }) else { return false }
            DispatchQueue.main.async { self.runTransform(transform) }
            return true
        case .pasteLast:
            DispatchQueue.main.async { self.pasteLast() }
            return true
        case .openScratchpad:
            DispatchQueue.main.async { self.openScratchpad() }
            return true
        case .transcribeFile:
            DispatchQueue.main.async { self.openFilesWindow() }
            return true
        }
    }

    private func flowBarClicked() {
        switch mode {
        case .idle:
            startRecording(command: false)
            mode = .handsFree
            flowBar.set(.handsFree)
        case .handsFree:
            finishRecording()
        default:
            break
        }
    }

    // MARK: - Recording

    private func startRecording(command: Bool) {
        guard transcriber.isReady else {
            flowBar.show(message: engineStatus.isEmpty ? L("Motore vocale in avvio…", "Speech engine starting…") : engineStatus)
            mode = .processing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.mode = .idle }
            return
        }
        commandMode = command
        targetApp = NSWorkspace.shared.frontmostApplication
        learner.flush()
        focus = .empty
        if settings.s.useAppContext || settings.s.autoLearn != .off {
            let app = targetApp
            DispatchQueue.global(qos: .userInitiated).async {
                let ctx = FocusReader.read(app: app)
                DispatchQueue.main.async { self.focus = ctx }
            }
        }
        do {
            try recorder.start(deviceUID: settings.s.microphoneUID)
        } catch {
            flowBar.show(message: L("Microfono non disponibile: ", "Microphone unavailable: ") + error.localizedDescription, seconds: 4)
            mode = .processing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.mode = .idle }
            return
        }
        recordStart = Date()
        session = UUID()
        committedSamples = 0
        segments = [:]
        segmentsSent = 0
        onSegmentsDone = nil
        streamTimer?.invalidate()
        if settings.s.streamingTranscription {
            streamTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.streamTick() }
        }
        if settings.s.llmEnabled, settings.s.cleanupSpeed != .fast { llm.ensureLoaded() }
        if settings.s.muteWhileDictating { SystemAudio.mute() }
        if settings.s.playSounds { NSSound(named: "Tink")?.play() }
        flowBar.set(.recording, command: command)
    }

    private func cancelRecording(silent: Bool = false) {
        tapTimer?.invalidate()
        streamTimer?.invalidate()
        session = UUID()
        _ = recorder.stop()
        if settings.s.muteWhileDictating { SystemAudio.restore() }
        mode = .idle
        commandMode = false
        if silent { flowBar.set(.idle) } else { flowBar.show(message: L("Annullato", "Cancelled"), seconds: 1) }
    }

    /// While recording: once enough unsent audio piles up, cut it at a pause and transcribe that piece now.
    private func streamTick() {
        let rate = Int(AudioRecorder.sampleRate)
        let total = recorder.sampleCount
        let unsent = total - committedSamples
        guard unsent >= rate * 8 else { return }
        let audio = recorder.snapshot(committedSamples..<total)
        // Look for a pause between 5 s into the piece and 0.4 s before "now" (the user may be mid-word).
        guard let quiet = AudioUtils.quietestPoint(audio, in: (rate * 5)..<(audio.count - rate * 2 / 5)) else { return }
        let sorted = stride(from: 0, to: audio.count, by: 16).map { abs(audio[$0]) }.sorted()
        let loud = sorted[sorted.count * 9 / 10]
        // Cut at a real pause; after 25 s accept the quietest point found.
        guard quiet.rms < max(0.004, loud * 0.15) || unsent >= rate * 25 else { return }
        let piece = Array(audio[..<quiet.index])
        committedSamples += quiet.index
        sendSegment(piece, index: segmentsSent)
        segmentsSent += 1
    }

    private func sendSegment(_ piece: [Float], index: Int) {
        let current = session
        guard let speech = AudioUtils.trimSilence(piece) else {
            segments[index] = ("", "")
            return
        }
        transcribeSegment(speech, language: settings.s.dictationLanguage) { [weak self] text, language in
            guard let self, self.session == current else { return }
            self.segments[index] = (text, language)
            if self.segments.count == self.segmentsSent { self.onSegmentsDone?() }
        }
    }

    private func finishRecording() {
        tapTimer?.invalidate()
        streamTimer?.invalidate()
        let samples = recorder.stop()
        if settings.s.muteWhileDictating { SystemAudio.restore() }
        if settings.s.playSounds { NSSound(named: "Pop")?.play() }
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        if segmentsSent > 0 { return finishStreamed(samples, duration: duration) }
        guard let speech = AudioUtils.trimSilence(samples) else {
            mode = .idle
            commandMode = false
            let peak = samples.map(abs).max() ?? 0
            flowBar.show(message: peak < 0.0005
                         ? L("Nessun audio: il microfono è disattivato?", "No audio: is your microphone muted?")
                         : L("Nessuna voce rilevata", "No speech detected"))
            return
        }
        try? AudioUtils.wavData(speech).write(to: Paths.appSupport.appendingPathComponent("last-recording.wav"))
        mode = .processing
        flowBar.set(.processing, command: commandMode)
        transcribe(speech, duration: duration, language: settings.s.dictationLanguage, retried: false)
    }

    /// Transcribes the rest of a streamed dictation, then joins all pieces in order.
    private func finishStreamed(_ samples: [Float], duration: Double) {
        mode = .processing
        flowBar.set(.processing, command: commandMode)
        let current = session
        let tailIndex = segmentsSent
        segmentsSent += 1
        let tail = committedSamples < samples.count ? Array(samples[committedSamples...]) : []
        onSegmentsDone = { [weak self] in
            guard let self, self.session == current else { return }
            self.onSegmentsDone = nil
            let ordered = (0..<self.segmentsSent).compactMap { self.segments[$0] }.filter { !$0.text.isEmpty }
            let text = ordered.map(\.text).joined(separator: " ")
            // Language of the longest piece wins (mixed IT/EN dictations keep each piece as spoken).
            let language = ordered.max(by: { $0.text.count < $1.text.count })?.language ?? self.settings.s.dictationLanguage
            self.handleTranscript(text, language: language, duration: duration)
        }
        sendSegment(tail, index: tailIndex)
        if segments.count == segmentsSent { onSegmentsDone?() }
    }

    private func transcribe(_ samples: [Float], duration: Double, language: String, retried: Bool) {
        let current = session
        transcribeSegment(samples, language: language) { [weak self] text, lang in
            guard let self, self.session == current else { return }
            if text.isEmpty, lang.isEmpty {
                return self.finish(message: L("Errore trascrizione: ", "Transcription error: ") + self.lastTranscriptionError)
            }
            self.handleTranscript(text, language: lang, duration: duration)
        }
    }

    private var lastTranscriptionError = ""

    /// One whisper request with the recovery rules: retry without prompt when the prompt derailed whisper,
    /// and force Italian/English when auto-detect picked another language. Empty language = failure.
    private func transcribeSegment(_ samples: [Float], language: String, retried: Bool = false, usePrompt: Bool = true,
                                   completion: @escaping (String, String) -> Void) {
        let prompt = usePrompt ? processor.whisperPrompt(focus: focus) : ""
        transcriber.transcribe(samples, language: language, prompt: prompt) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lastTranscriptionError = error.localizedDescription
                completion("", "")
            case .success(let r):
                // Almost no letters from a real utterance: the prompt likely derailed whisper, retry without it.
                if r.text.filter(\.isLetter).count < 2, !prompt.isEmpty {
                    return self.transcribeSegment(samples, language: language, retried: retried, usePrompt: false, completion: completion)
                }
                // Auto mode is limited to Italian/English: re-run if whisper guessed another language.
                if language == "auto", !retried, !["it", "en"].contains(r.language) {
                    let fallback = self.settings.s.uiLanguage == "en" ? "en" : "it"
                    return self.transcribeSegment(samples, language: fallback, retried: true, usePrompt: usePrompt, completion: completion)
                }
                completion(r.text, language == "auto" ? r.language : language)
            }
        }
    }

    private func handleTranscript(_ raw: String, language: String, duration: Double) {
        guard raw.contains(where: \.isLetter) else { return finish(message: L("Nessuna voce rilevata", "No speech detected")) }
        let appName = targetApp?.localizedName ?? "?"
        if commandMode {
            runCommand(instruction: raw, appName: appName, duration: duration, language: language)
            return
        }
        let category = AppCategory.forBundleID(targetApp?.bundleIdentifier)
        let focus = self.focus
        let context = DictationContext(appName: appName, bundleID: targetApp?.bundleIdentifier,
                                       language: language, tone: settings.s.tone(for: category), focus: focus)
        processor.process(raw, context: context) { [weak self] text in
            guard let self else { return }
            guard !text.isEmpty else { return self.finish(message: L("Nessuna voce rilevata", "No speech detected")) }
            self.deliver(text)
            if !focus.isSecure {
                if self.settings.s.autoLearn != .off {
                    self.learner.track(element: focus.element, inserted: text, offset: focus.insertionOffset)
                }
                if self.settings.s.keepHistory {
                    HistoryStore.shared.add(app: appName, raw: raw, text: text, language: language, duration: duration, mode: "dictation")
                }
            }
            self.finish(message: nil)
        }
    }

    private func runCommand(instruction: String, appName: String, duration: Double, language: String) {
        guard settings.s.llmEnabled else {
            return finish(message: L("La modalità comando richiede l'LLM locale attivo", "Command mode needs the local LLM enabled"))
        }
        Paster.selectedText { [weak self] selection in
            guard let self else { return }
            self.llm.chat(self.processor.commandMessages(instruction: instruction, selection: selection), timeout: 90) { result in
                switch result {
                case .success(let text) where !text.isEmpty:
                    self.deliver(text)
                    if self.settings.s.keepHistory {
                        HistoryStore.shared.add(app: appName, raw: instruction, text: text, language: language, duration: duration, mode: "command")
                    }
                    self.finish(message: nil)
                case .success:
                    self.finish(message: L("Il comando non ha prodotto testo", "Command returned no text"))
                case .failure(let error):
                    self.finish(message: "Ollama: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runTransform(_ transform: TransformItem) {
        guard mode == .idle else { return }
        guard settings.s.llmEnabled else {
            return flowBar.show(message: L("Le azioni rapide richiedono l'LLM locale attivo", "Quick actions need the local LLM enabled"))
        }
        mode = .processing
        Paster.selectedText { [weak self] selection in
            guard let self else { return }
            guard let selection, !selection.isEmpty else {
                return self.finish(message: L("Seleziona del testo, poi premi \(transform.shortcut.display)", "Highlight text, then press \(transform.shortcut.display)"))
            }
            self.flowBar.state.message = transform.name
            self.flowBar.set(.processing, command: true)
            self.llm.chat(self.processor.transformMessages(transform, text: selection), timeout: 90) { result in
                switch result {
                case .success(let text) where !text.isEmpty:
                    self.deliver(text)
                    self.finish(message: "\(transform.name) ✓ — " + L("⌘Z per annullare", "⌘Z to undo"))
                case .success:
                    self.finish(message: L("L'azione rapida non ha restituito testo", "Quick action returned no text"))
                case .failure(let error):
                    self.finish(message: L("Azione rapida non riuscita: ", "Quick action failed: ") + error.localizedDescription)
                }
            }
        }
    }

    private func deliver(_ text: String) {
        lastText = text
        Paster.paste(text, restoreClipboard: settings.s.restoreClipboard)
    }

    private func finish(message: String?) {
        mode = .idle
        commandMode = false
        if let message { flowBar.show(message: message, seconds: 3) } else { flowBar.set(.idle) }
    }
}
