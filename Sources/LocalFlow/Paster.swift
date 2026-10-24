import AppKit
import ApplicationServices

/// Inserts text into the focused app and reads the current selection.
enum Paster {
    private static let vKey: CGKeyCode = 9
    private static let cKey: CGKeyCode = 8

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private struct SavedItem { var type: NSPasteboard.PasteboardType; var data: Data }

    private static func savePasteboard() -> [[SavedItem]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { SavedItem(type: t, data: $0) } }
        }
    }

    private static func restorePasteboard(_ saved: [[SavedItem]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for e in entries { item.setData(e.data, forType: e.type) }
            return item
        }
        pb.writeObjects(items)
    }

    /// Pastes `text` with ⌘V, then restores the previous clipboard if requested.
    static func paste(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        let saved = restoreClipboard ? savePasteboard() : []
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tells clipboard managers not to record this entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pb.changeCount
        postKey(vKey, flags: .maskCommand)
        guard restoreClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if pb.changeCount == ourChange { restorePasteboard(saved) }
        }
    }

    /// Returns the selected text in the focused app (Accessibility first, then a ⌘C round-trip).
    static func selectedText(completion: @escaping (String?) -> Void) {
        if let ax = axSelectedText(), !ax.isEmpty { return completion(ax) }
        let pb = NSPasteboard.general
        let saved = savePasteboard()
        let before = pb.changeCount
        postKey(cKey, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var result: String?
            if pb.changeCount != before { result = pb.string(forType: .string) }
            if pb.changeCount != before { restorePasteboard(saved) }
            completion(result?.isEmpty == true ? nil : result)
        }
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Mutes system output while dictating and restores it afterwards.
enum SystemAudio {
    private static var wasMuted: Bool?

    private static func osascript(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mute() {
        DispatchQueue.global(qos: .userInitiated).async {
            let state = osascript("output muted of (get volume settings)")
            wasMuted = state == "true"
            if state == "false" { _ = osascript("set volume with output muted") }
        }
    }

    static func restore() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
            if wasMuted == false { _ = osascript("set volume without output muted") }
            wasMuted = nil
        }
    }
}
