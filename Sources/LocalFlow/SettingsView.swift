import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var flow: FlowState
    var onRestartEngine: () -> Void
    var onHotkeyChange: () -> Void
    var onFixIssue: (HealthIssue) -> Void

    var body: some View {
        TabView {
            GeneralTab(store: store, flow: flow, onRestartEngine: onRestartEngine, onHotkeyChange: onHotkeyChange, onFixIssue: onFixIssue)
                .tabItem { Label(L("Generale", "General"), systemImage: "gearshape") }
            ShortcutsTab(store: store)
                .tabItem { Label(L("Scorciatoie", "Shortcuts"), systemImage: "command") }
            StyleTab(store: store)
                .tabItem { Label(L("Stile", "Style"), systemImage: "textformat") }
            DictionaryTab(store: store)
                .tabItem { Label(L("Dizionario", "Dictionary"), systemImage: "book") }
            SnippetsTab(store: store)
                .tabItem { Label("Snippet", systemImage: "text.badge.plus") }
            TransformsTab(store: store)
                .tabItem { Label(L("Azioni rapide", "Quick actions"), systemImage: "wand.and.stars") }
            HistoryTab()
                .tabItem { Label(L("Cronologia", "History"), systemImage: "clock") }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var flow: FlowState
    var onRestartEngine: () -> Void
    var onHotkeyChange: () -> Void
    var onFixIssue: (HealthIssue) -> Void
    @ObservedObject private var health = HealthMonitor.shared
    @State private var models: [String] = []
    @StateObject private var puller = OllamaPuller()
    private static let downloadable: [(name: String, size: String)] = [
        ("qwen2.5:1.5b", "1 GB"), ("qwen2.5:3b", "2 GB"), ("qwen2.5:7b", "4.7 GB"), ("qwen2.5:14b", "9 GB"),
    ]
    /// Embedding models can't chat: keep them out of the picker.
    private static func chatModels(_ names: [String]?) -> [String] {
        (names ?? []).filter { !$0.localizedCaseInsensitiveContains("embed") }
    }
    @State private var axTrusted = Paster.accessibilityTrusted
    @State private var microphones: [AudioInputDevice] = []
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError = ""

    var body: some View {
        Form {
            Section(L("Diagnostica", "Diagnostics")) {
                if health.issues.isEmpty {
                    Label(L("Tutto funziona", "Everything is working"), systemImage: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    ForEach(health.issues) { issue in
                        HStack {
                            Image(systemName: issue.isBlocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundColor(issue.isBlocking ? .red : .orange)
                            Text(issue.message)
                            Spacer()
                            if let fix = issue.fixTitle { Button(fix) { onFixIssue(issue) } }
                        }
                    }
                }
            }
            Section(L("Dettatura", "Dictation")) {
                Picker(L("Tasto dettatura", "Dictation key"), selection: $store.s.hotkey) {
                    ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: store.s.hotkey) { _ in onHotkeyChange() }
                Text(L("Tieni premuto e parla, rilascia per inserire. Doppio tocco = mani libere (tocca di nuovo per finire). Aggiungi ⌃ Control = modalità comando. Esc annulla.",
                       "Hold and speak, release to insert. Double-tap = hands-free (tap again to finish). Add ⌃ Control = command mode. Esc cancels."))
                    .font(.caption).foregroundColor(.secondary)
                if store.s.hotkey == .fn {
                    Text(L("Suggerimento: Impostazioni di Sistema › Tastiera › \"Premi il tasto 🌐 per\" → \"Non fare nulla\".",
                           "Tip: System Settings › Keyboard › \"Press 🌐 key to\" → \"Do Nothing\"."))
                        .font(.caption).foregroundColor(.orange)
                }
                Picker(L("Microfono", "Microphone"), selection: $store.s.microphoneUID) {
                    Text(L("Predefinito di sistema", "System default")).tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if !store.s.microphoneUID.isEmpty, !microphones.contains(where: { $0.id == store.s.microphoneUID }) {
                        Text(L("Non collegato", "Not connected")).tag(store.s.microphoneUID)
                    }
                }
                Text(L("Suggerimento: scegli il microfono del Mac per non far passare le AirPods in modalità chiamata (audio peggiore).",
                       "Tip: pick the Mac's microphone so AirPods don't switch to call mode (worse audio)."))
                    .font(.caption).foregroundColor(.secondary)
                Picker(L("Lingua parlata", "Spoken language"), selection: $store.s.dictationLanguage) {
                    Text(L("Automatica (italiano / inglese)", "Automatic (Italian / English)")).tag("auto")
                    Text("Italiano").tag("it")
                    Text("English").tag("en")
                }
                Picker(L("Lingua del testo", "Output language"), selection: $store.s.outputLanguage) {
                    Text(L("Uguale a quella parlata", "Same as spoken")).tag("same")
                    Text(L("Traduci sempre in italiano", "Always translate to Italian")).tag("it")
                    Text(L("Traduci sempre in inglese", "Always translate to English")).tag("en")
                }
            }
            Section(L("Pulizia del testo", "Text cleanup")) {
                Toggle(L("Rimuovi intercalari (ehm, cioè, um, like…)", "Remove filler words (ehm, cioè, um, like…)"), isOn: $store.s.removeFillers)
                Toggle(L("Autocorrezioni: applica le correzioni a voce (\"alle 3, anzi alle 4\")", "Self-corrections: apply spoken corrections (\"at 3, no wait at 4\")"), isOn: $store.s.backtrack)
                Toggle(L("Formattazione smart (elenchi, a capo, punteggiatura)", "Smart formatting (lists, new lines, punctuation)"), isOn: $store.s.smartFormatting)
                Toggle(L("Usa il contesto dell'app (testo attorno al cursore, titolo finestra)", "Use app context (text around the cursor, window title)"), isOn: $store.s.useAppContext)
                Picker(L("Impara dalle tue correzioni", "Learn from your corrections"), selection: $store.s.autoLearn) {
                    ForEach(AutoLearn.allCases) { Text($0.label).tag($0) }
                }
                Text(L("Se correggi una parola appena dettata, LocalFlow la propone per il dizionario.",
                       "If you fix a word right after dictating, LocalFlow offers to add it to the dictionary."))
                    .font(.caption).foregroundColor(.secondary)
                Toggle(L("Usa LLM locale (Ollama) per la pulizia", "Use local LLM (Ollama) for cleanup"), isOn: $store.s.llmEnabled)
                Picker(L("Velocità", "Speed"), selection: $store.s.cleanupSpeed) {
                    ForEach(CleanupSpeed.allCases) { Text($0.label).tag($0) }
                }.disabled(!store.s.llmEnabled)
                Toggle(L("Trascrivi mentre parli (dettature lunghe più rapide)", "Transcribe while you speak (faster long dictations)"), isOn: $store.s.streamingTranscription)
                HStack {
                    TextField(L("Modello Ollama", "Ollama model"), text: $store.s.ollamaModel)
                    if !models.isEmpty {
                        Menu(L("Installati", "Installed")) {
                            ForEach(models, id: \.self) { m in Button(m) { store.s.ollamaModel = m } }
                        }.frame(width: 110)
                    }
                    Menu(L("Scarica", "Download")) {
                        ForEach(Self.downloadable.filter { !models.contains($0.name) }, id: \.name) { m in
                            Button("\(m.name)  (\(m.size))") {
                                puller.pull(m.name) { ok in
                                    if ok { store.s.ollamaModel = m.name }
                                    LLMClient().availableModels { models = Self.chatModels($0) }
                                }
                            }
                        }
                    }.frame(width: 100).disabled(puller.running)
                }
                if puller.running || !puller.status.isEmpty {
                    HStack {
                        if puller.running { ProgressView(value: puller.progress).frame(maxWidth: 200) }
                        Text(puller.running ? "\(Int(puller.progress * 100))% — \(puller.status)" : puller.status)
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                TextField("Ollama URL", text: $store.s.ollamaURL)
            }
            Section(L("Comportamento", "Behaviour")) {
                Toggle(L("Controlla aggiornamenti ogni giorno (solo il numero di versione da GitHub)", "Check for updates daily (only the version number from GitHub)"), isOn: $store.s.checkUpdates)
                Toggle(L("Apri LocalFlow al login", "Open LocalFlow at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            try LoginItem.set(on)
                            loginError = LoginItem.status == .requiresApproval
                                ? L("Approva LocalFlow in Impostazioni di Sistema › Generali › Elementi login", "Approve LocalFlow in System Settings › General › Login Items") : ""
                        } catch { loginError = error.localizedDescription }
                        launchAtLogin = LoginItem.isEnabled
                    }))
                if !loginError.isEmpty {
                    Text(loginError).font(.caption).foregroundColor(.orange)
                }
                Toggle(L("Timestamp nelle trascrizioni dei file", "Timestamps in file transcripts"), isOn: $store.s.fileTimestamps)
                Toggle(L("Silenzia l'audio durante la dettatura", "Mute audio while dictating"), isOn: $store.s.muteWhileDictating)
                Toggle(L("Suoni di avvio/fine", "Start/stop sounds"), isOn: $store.s.playSounds)
                Toggle(L("Mostra sempre la barra vocale", "Always show the voice bar"), isOn: $store.s.flowBarAlways)
                Toggle(L("Nascondi la barra vocale da condivisione schermo e screenshot", "Hide the voice bar from screen sharing and screenshots"), isOn: $store.s.hideFromScreenShare)
                Toggle(L("Ripristina gli appunti dopo l'incolla", "Restore clipboard after pasting"), isOn: $store.s.restoreClipboard)
                Toggle(L("Salva cronologia (solo su questo Mac)", "Keep history (on this Mac only)"), isOn: $store.s.keepHistory)
                Picker(L("Lingua interfaccia", "Interface language"), selection: $store.s.uiLanguage) {
                    Text("Italiano").tag("it")
                    Text("English").tag("en")
                }
            }
            Section(L("Motore vocale (whisper.cpp)", "Speech engine (whisper.cpp)")) {
                HStack {
                    Circle().fill(flow.engineReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(Transcriber.findModel().map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("Nessun modello", "No model"))
                    Spacer()
                    Button(L("Riavvia", "Restart"), action: onRestartEngine)
                    Button(L("Cartella modelli", "Models folder")) {
                        try? FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Paths.models)
                    }
                }
                HStack {
                    Circle().fill(axTrusted ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(L("Permesso Accessibilità", "Accessibility permission"))
                    Spacer()
                    if !axTrusted {
                        Button(L("Concedi", "Grant")) {
                            Paster.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Text(L("Tutto gira in locale: audio e testo non lasciano mai questo Mac.", "Everything runs locally: audio and text never leave this Mac."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            axTrusted = Paster.accessibilityTrusted
            microphones = AudioDevices.inputs()
            launchAtLogin = LoginItem.isEnabled
            LLMClient().availableModels { models = Self.chatModels($0) }
            health.check(forceOllama: true)
        }
    }
}

// MARK: - Style

struct StyleTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Text(L("LocalFlow adatta tono e formattazione all'app in cui stai scrivendo.", "LocalFlow adapts tone and formatting to the app you're writing in."))
                    .foregroundColor(.secondary)
            }
            ForEach(AppCategory.allCases) { category in
                Section("\(category.label) — \(category.appsHint)") {
                    Picker(L("Tono", "Tone"), selection: Binding(
                        get: { store.s.tone(for: category) },
                        set: { store.s.tones[category.rawValue] = $0 })) {
                        ForEach(Tone.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(store.s.tone(for: category).example).font(.callout).italic().foregroundColor(.secondary)
                }
            }
            Section(L("Istruzioni personali", "Custom instructions")) {
                TextEditor(text: $store.s.customInstructions)
                    .frame(minHeight: 70)
                    .font(.body)
                Text(L("Es.: \"Usa il tu, non il lei. Scrivi 'ok' minuscolo.\"", "E.g. \"Use British spelling. Write 'ok' in lowercase.\""))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictionary

struct DictionaryTab: View {
    @ObservedObject var store: SettingsStore
    @State private var word = ""
    @State private var misspellings = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Parole, nomi e sigle che LocalFlow deve scrivere sempre correttamente. Facoltativo: varianti sbagliate da sostituire.",
                   "Words, names and acronyms LocalFlow should always spell right. Optional: wrong variants to replace."))
                .foregroundColor(.secondary)
            HStack {
                TextField(L("Parola (es. Kubernetes)", "Word (e.g. Kubernetes)"), text: $word)
                TextField(L("Varianti errate, separate da virgola", "Wrong variants, comma separated"), text: $misspellings)
                Button(L("Aggiungi", "Add")) {
                    let w = word.trimmingCharacters(in: .whitespaces)
                    guard !w.isEmpty else { return }
                    store.s.dictionary.insert(DictionaryEntry(word: w, misspellings: misspellings), at: 0)
                    word = ""; misspellings = ""
                }
                .keyboardShortcut(.defaultAction)
            }
            List {
                ForEach($store.s.dictionary) { $entry in
                    HStack {
                        TextField("", text: $entry.word).frame(width: 200)
                        TextField(L("varianti", "variants"), text: $entry.misspellings)
                        Button(role: .destructive) {
                            store.s.dictionary.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - Snippets

struct SnippetsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Scorciatoie vocali: pronuncia la frase e LocalFlow inserisce il testo completo (email, link, indirizzi, firme…).",
                   "Voice shortcuts: say the phrase and LocalFlow inserts the full text (emails, links, addresses, signatures…)."))
                .foregroundColor(.secondary)
            HStack(alignment: .top) {
                TextField(L("Quando dico… (es. \"la mia email\")", "When I say… (e.g. \"my email\")"), text: $trigger).frame(width: 220)
                TextField(L("Inserisci…", "Insert…"), text: $text, axis: .vertical).lineLimit(1...4)
                Button(L("Aggiungi", "Add")) {
                    guard !trigger.isEmpty, !text.isEmpty else { return }
                    store.s.snippets.insert(Snippet(trigger: trigger, text: text), at: 0)
                    trigger = ""; text = ""
                }
            }
            List {
                ForEach($store.s.snippets) { $snippet in
                    HStack(alignment: .top) {
                        TextField("", text: $snippet.trigger).frame(width: 200)
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        TextField("", text: $snippet.text, axis: .vertical).lineLimit(1...6)
                        Button(role: .destructive) {
                            store.s.snippets.removeAll { $0.id == snippet.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - Transforms

struct TransformsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Seleziona del testo in qualsiasi app e premi la scorciatoia di un'azione rapida (predefinite ⌃⌥ + numero) per riscriverlo con l'LLM locale. Modalità comando: seleziona, tieni premuto il tasto dettatura + ⌃ e di' cosa fare (\"rendilo più gentile\", \"translate to English\").",
                   "Select text in any app and press a quick action's shortcut (default ⌃⌥ + number) to rewrite it with the local LLM. Command mode: select, hold the dictation key + ⌃ and say what to do (\"make it friendlier\", \"traduci in italiano\")."))
                .foregroundColor(.secondary)
            List {
                ForEach($store.s.transforms) { $t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(L("Nome", "Name"), text: $t.name).font(.headline)
                            ShortcutRecorder(shortcut: $t.shortcut)
                            Button(role: .destructive) {
                                store.s.transforms.removeAll { $0.id == t.id }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        TextField(L("Istruzione", "Instruction"), text: $t.prompt, axis: .vertical)
                            .lineLimit(1...4).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Button(L("Nuova azione rapida", "New quick action")) {
                    let used = Set(store.s.transforms.map(\.shortcut))
                    let slot = (1...9).first { !used.contains(.ctrlOptDigit($0)) } ?? 0
                    store.s.transforms.append(TransformItem(name: L("Personalizzato", "Custom"), prompt: "", slot: slot))
                }
                Button(L("Ripristina predefiniti", "Restore defaults")) { store.s.transforms = AppSettings.defaultTransforms }
            }
        }
    }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var history = HistoryStore.shared
    @State private var search = ""
    @State private var items: [HistoryItem] = []
    @State private var stats = (count: 0, words: 0, minutes: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                stat("\(stats.count)", L("dettature", "dictations"))
                stat("\(stats.words)", L("parole", "words"))
                stat(stats.minutes > 0 ? "\(Int(Double(stats.words) / stats.minutes))" : "–", L("parole/min", "words/min"))
                Spacer()
                Button(L("Svuota", "Clear"), role: .destructive) { history.clear() }
            }
            TextField(L("Cerca…", "Search…"), text: $search)
            List(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                        Text("· \(item.app) · \(item.language.uppercased())\(item.mode == "command" ? " · Command" : "")")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button { copy(item.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        Button { history.delete(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    Text(item.text).textSelection(.enabled)
                    if item.raw != item.text {
                        Text(item.raw).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { _ in reload() }
        .onChange(of: history.revision) { _ in reload() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    private func reload() {
        items = history.items(search: search)
        stats = history.stats()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Shortcuts

struct ShortcutsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section(L("Dettatura", "Dictation")) {
                LabeledContent(L("Tieni premuto per dettare", "Hold to dictate"), value: store.s.hotkey.label)
                LabeledContent(L("Mani libere", "Hands-free"), value: L("doppio tocco", "double-tap"))
                LabeledContent(L("Modalità comando", "Command mode"), value: store.s.hotkey == .rightControl ? "+ ⇧" : "+ ⌃")
                LabeledContent(L("Annulla", "Cancel"), value: "⎋")
                Text(L("Il tasto dettatura si cambia nella scheda Generale.", "Change the dictation key in the General tab."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("Azioni", "Actions")) {
                LabeledContent(L("Incolla ultima trascrizione", "Paste last transcript")) { ShortcutRecorder(shortcut: $store.s.pasteLastShortcut) }
                LabeledContent(L("Note rapide", "Quick notes")) { ShortcutRecorder(shortcut: $store.s.scratchpadShortcut) }
                LabeledContent(L("Trascrivi file", "Transcribe files")) { ShortcutRecorder(shortcut: $store.s.transcribeFileShortcut) }
            }
            Section(L("Azioni rapide", "Quick actions")) {
                ForEach($store.s.transforms) { $t in
                    LabeledContent(t.name.isEmpty ? L("Senza nome", "Untitled") : t.name) { ShortcutRecorder(shortcut: $t.shortcut) }
                }
            }
            if let conflict = conflicts.first {
                Text(L("Attenzione: \(conflict) è usata più volte.", "Warning: \(conflict) is used more than once."))
                    .foregroundColor(.orange)
            }
        }
        .formStyle(.grouped)
    }

    private var conflicts: [String] {
        let all = [store.s.pasteLastShortcut, store.s.scratchpadShortcut, store.s.transcribeFileShortcut]
            + store.s.transforms.map(\.shortcut)
        var seen = Set<KeyShortcut>(), dup: [String] = []
        for k in all where !k.isEmpty {
            if !seen.insert(k).inserted { dup.append(k.display) }
        }
        return dup
    }
}

/// Click, then press a key combination (with ⌃ ⌥ ⌘ or ⇧, or an F-key). Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? L("Premi i tasti…", "Press keys…") : shortcut.display) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if !shortcut.isEmpty && !recording {
                Button { shortcut = .none } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotkeyMonitor.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let modifiers = UInt64(event.modifierFlags.rawValue) & KeyShortcut.modifierMask
            guard modifiers != 0 || KeyShortcut.isFunctionKey(Int(event.keyCode)) else {
                NSSound.beep()
                return nil
            }
            shortcut = KeyShortcut(keyCode: Int(event.keyCode), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotkeyMonitor.isRecordingShortcut = false
    }
}
