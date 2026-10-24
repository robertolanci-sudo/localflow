# LocalFlow

**Private voice dictation for macOS. 100% on-device, Italian and English.**
Hold a key, speak, release: clean, punctuated text appears wherever your cursor is.
Audio and text never leave your Mac. Speech recognition runs on whisper.cpp (Metal); optional cleanup and rewriting use a local LLM through [Ollama](https://ollama.com).

[**Download the latest DMG**](https://github.com/robertolanci-sudo/localflow/releases/latest) · Apple Silicon and Intel · macOS 13+

[Italiano ↓](#italiano)

## Features

- **Hold to talk** (fn, or right ⌥/⌘/⌃). Double-tap for hands-free mode, Esc to cancel.
- **Fast**: long dictations are transcribed while you speak, and the LLM only runs when the text needs it (fillers, self-corrections, lists, spoken punctuation).
- **Smart cleanup**: removes fillers (ehm, cioè, um, like…), applies self-corrections ("at 3, no wait at 4" → "at 4"), formats lists, writes numbers and dates properly.
- **Italian/English auto-detection**, with optional translation of the output.
- **Per-app tone**: formal, casual, very casual or excited for personal messages, work chat, email and everything else.
- **App context**: reads the text around the cursor (never in password fields) for correct spacing, capitalization and name spelling.
- **Dictionary** that learns from your corrections, and **voice snippets** (say a phrase, get your signature, address or link).
- **Command mode**: select text, hold the dictation key + ⌃ and say what to do ("make it friendlier", "traduci in inglese").
- **Quick actions** on selected text with ⌃⌥1…9: refine, formal, bullet points, translate IT⇄EN, shorten, email, or your own.
- **Audio/video file transcription** (mp3, m4a, wav, mp4, mov; opus/ogg/webm with ffmpeg) with timestamps, summary, action items and Markdown export.
- **Quick notes**, searchable **history** with stats, **paste last transcript** (⌃⌥V).
- Preferred microphone, launch at login, customizable shortcuts, built-in diagnostics.

## Install

1. Download the DMG and drag **LocalFlow** into **Applications**.
2. The app is not notarized by Apple, so the first launch is blocked:
   - macOS 15+: close the warning, then **System Settings › Privacy & Security › Open Anyway**.
   - macOS 13–14: right-click the app › **Open** › **Open**.
3. Follow the setup guide: it downloads the speech model, asks for **Microphone** and **Accessibility**, and optionally sets up an Ollama model.
4. If you use fn: **System Settings › Keyboard › "Press 🌐 key to" → "Do Nothing"**.

Intel Macs: choose the "Fast" speech model and the 3B LLM.

## Privacy

Dictation, transcription and cleanup all run locally. The only network requests are the one-time model downloads and a daily check of this repository's latest release version, which you can turn off in Settings.

## Build from source

Requires the Xcode Command Line Tools and CMake.

```bash
./build.sh                 # universal app (Apple Silicon + Intel), installs to /Applications
./build.sh --no-install
./scripts/make_dmg.sh      # dist/LocalFlow-<version>.dmg
```

`build.sh` compiles whisper-server from the bundled whisper.cpp (`scripts/build_whisper.sh`) the first time. It signs with a "LocalFlow Code Signing" certificate if one is in your keychain, so macOS keeps the Accessibility permission across rebuilds; otherwise it signs ad hoc.

## License

MIT. Includes [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT).

---

## Italiano

**Dettatura vocale privata per macOS. Tutto sul tuo Mac, in italiano e inglese.**
Tieni premuto un tasto, parla, rilascia: il testo pulito e punteggiato compare dove si trova il cursore. Audio e testo non lasciano mai il Mac.

[**Scarica l'ultimo DMG**](https://github.com/robertolanci-sudo/localflow/releases/latest) · Apple Silicon e Intel · macOS 13+

### Cosa fa

- **Tieni premuto e parla** (fn, oppure ⌥/⌘/⌃ destro). Doppio tocco per le mani libere, Esc annulla.
- **Veloce**: le dettature lunghe vengono trascritte mentre parli, e l'LLM interviene solo quando serve.
- **Pulizia intelligente**: toglie gli intercalari, applica le autocorrezioni ("alle 3, anzi alle 4" → "alle 4"), crea elenchi, scrive bene numeri e date.
- **Italiano/inglese automatico**, con traduzione facoltativa.
- **Tono per app**: formale, informale, molto informale o entusiasta.
- **Contesto dell'app**, **dizionario** che impara dalle tue correzioni, **snippet vocali**.
- **Modalità comando** (tasto dettatura + ⌃) e **azioni rapide** ⌃⌥1…9 sul testo selezionato.
- **Trascrizione di file audio/video** con timestamp, riassunto e cose da fare.
- **Note rapide**, **cronologia** con statistiche, **incolla ultima trascrizione** (⌃⌥V).

### Installazione

1. Scarica il DMG e trascina **LocalFlow** in **Applicazioni**.
2. Primo avvio: macOS 15+ › Impostazioni di Sistema › Privacy e sicurezza › **Apri comunque**; macOS 13–14 › tasto destro sull'app › **Apri**.
3. Segui la configurazione guidata (modello vocale, Microfono, Accessibilità, Ollama facoltativo).
4. Se usi fn: Impostazioni di Sistema › Tastiera › "Premi il tasto 🌐 per" → "Non fare nulla".

### Privacy

Tutto avviene in locale. Le uniche connessioni sono il download dei modelli e un controllo giornaliero della versione più recente, disattivabile nelle impostazioni.
