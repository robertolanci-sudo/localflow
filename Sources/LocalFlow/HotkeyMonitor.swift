import AppKit
import CoreGraphics

/// Global keyboard listener (CGEventTap) for the dictation key and LocalFlow shortcuts.
final class HotkeyMonitor {
    enum Event {
        /// Dictation key pressed; `command` is true when ⌃ (or ⇧ for a ⌃ trigger) was held too.
        case triggerDown(command: Bool)
        case triggerUp
        /// Command modifier pressed while the dictation key is held.
        case commandModifier
        case escape
        case otherKey
        case transform(id: UUID)
        case pasteLast
        case openScratchpad
        case transcribeFile
    }

    /// True while the settings UI records a new shortcut: key events then pass through untouched.
    static var isRecordingShortcut = false

    /// Return true to swallow the key event (only honoured for key-down events).
    var handler: ((Event) -> Bool)?
    var trigger: HotkeyChoice { SettingsStore.shared.s.hotkey }

    private var tap: CFMachPort?
    private var triggerHeld = false


    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Whether the event tap exists and is currently enabled.
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private static func action(keyCode: Int, modifiers: UInt64) -> Event? {
        let s = SettingsStore.shared.s
        func matches(_ k: KeyShortcut) -> Bool { !k.isEmpty && k.keyCode == keyCode && k.modifiers == modifiers }
        if matches(s.pasteLastShortcut) { return .pasteLast }
        if matches(s.scratchpadShortcut) { return .openScratchpad }
        if matches(s.transcribeFileShortcut) { return .transcribeFile }
        if let t = s.transforms.first(where: { matches($0.shortcut) }) { return .transform(id: t.id) }
        return nil
    }

    private var commandFlag: CGEventFlags { trigger == .rightControl ? .maskShift : .maskControl }

    private func isTriggerPressed(_ flags: CGEventFlags) -> Bool {
        switch trigger {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.contains(.maskAlternate)
        case .rightCommand: return flags.contains(.maskCommand)
        case .rightControl: return flags.contains(.maskControl)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .flagsChanged {
            if keyCode == trigger.keyCode {
                let pressed = isTriggerPressed(flags)
                if pressed && !triggerHeld {
                    triggerHeld = true
                    _ = handler?(.triggerDown(command: flags.contains(commandFlag)))
                } else if !pressed && triggerHeld {
                    triggerHeld = false
                    _ = handler?(.triggerUp)
                }
            } else if triggerHeld && flags.contains(commandFlag) {
                _ = handler?(.commandModifier)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if keyCode == 53 {
            return handler?(.escape) == true ? nil : Unmanaged.passUnretained(event)
        }
        let modifiers = flags.rawValue & KeyShortcut.modifierMask
        if !HotkeyMonitor.isRecordingShortcut, modifiers != 0 || KeyShortcut.isFunctionKey(Int(keyCode)),
           let action = HotkeyMonitor.action(keyCode: Int(keyCode), modifiers: modifiers),
           handler?(action) == true {
            return nil
        }
        if triggerHeld { _ = handler?(.otherKey) }
        return Unmanaged.passUnretained(event)
    }
}
