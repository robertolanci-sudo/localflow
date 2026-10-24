import AppKit
import SwiftUI

final class FlowState: ObservableObject {
    enum Phase: Equatable { case idle, recording, handsFree, processing, message, suggestion }
    @Published var phase: Phase = .idle
    @Published var command = false
    @Published var levels: [Float] = Array(repeating: 0, count: 18)
    @Published var message = ""
    @Published var engineReady = false

    func push(level: Float) {
        levels.removeFirst()
        levels.append(min(1, level * 12))
    }
}

/// Floating pill at the bottom of the screen showing dictation state (like Wispr's Flow Bar).
final class FlowBarController {
    let state = FlowState()
    private let panel: NSPanel
    private var messageTimer: Timer?
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onAcceptSuggestion: (() -> Void)?
    var onRejectSuggestion: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = FlowBarView(state: state,
                               onClick: { [weak self] in self?.onClick?() },
                               onCancel: { [weak self] in self?.onCancel?() },
                               onStop: { [weak self] in self?.onStop?() },
                               onAccept: { [weak self] in self?.onAcceptSuggestion?() },
                               onReject: { [weak self] in self?.onRejectSuggestion?() },
                               onDrop: { [weak self] urls in self?.onDropFiles?(urls) })
        panel.contentView = NSHostingView(rootView: view)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
        refresh()
    }

    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 6))
    }

    func refresh() {
        let settings = SettingsStore.shared.s
        panel.sharingType = settings.hideFromScreenShare ? .none : .readOnly
        if state.phase == .idle && !settings.flowBarAlways {
            panel.orderOut(nil)
        } else {
            if !panel.isVisible { reposition() }
            panel.orderFrontRegardless()
        }
    }

    func set(_ phase: FlowState.Phase, command: Bool = false) {
        messageTimer?.invalidate()
        if phase == .recording || phase == .handsFree { reposition() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            state.phase = phase
            state.command = command
        }
        if phase == .recording { state.levels = Array(repeating: 0, count: state.levels.count) }
        refresh()
    }

    /// Shows a question with Yes/No buttons; dismisses itself (as "No") after `seconds`.
    func ask(_ question: String, seconds: TimeInterval = 10) {
        state.message = question
        set(.suggestion)
        messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard self?.state.phase == .suggestion else { return }
            self?.onRejectSuggestion?()
        }
    }

    var isBusy: Bool { [.recording, .handsFree, .processing].contains(state.phase) }

    func show(message: String, seconds: TimeInterval = 2.5) {
        state.message = message
        set(.message)
        messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.set(.idle)
        }
    }
}

struct FlowBarView: View {
    @ObservedObject var state: FlowState
    var onClick: () -> Void
    var onCancel: () -> Void
    var onStop: () -> Void
    var onAccept: () -> Void
    var onReject: () -> Void
    var onDrop: ([URL]) -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    private var accent: Color { state.command ? Color.purple : Color.white }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .background(Capsule().fill(Color.black.opacity(0.88)))
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .onHover { hovering = $0 }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    FilesView.loadURLs(providers, completion: onDrop)
                    return true
                }
        }
        .frame(width: 300, height: 64)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle:
            Capsule()
                .fill(Color.clear)
                .frame(width: hovering || dropTargeted ? 120 : 44, height: hovering || dropTargeted ? 22 : 8)
                .overlay(
                    Group {
                        if dropTargeted {
                            Text(L("Rilascia per trascrivere", "Drop to transcribe"))
                                .font(.system(size: 9, weight: .medium)).foregroundColor(.white).fixedSize()
                        } else if hovering {
                            Text(state.engineReady ? L("Clicca o tieni premuto", "Click or hold key") : L("Avvio…", "Starting…"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                )
                .contentShape(Capsule())
                .onTapGesture(perform: onClick)
                .animation(.easeOut(duration: 0.15), value: hovering)
        case .recording, .handsFree:
            HStack(spacing: 8) {
                if state.phase == .handsFree {
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.8))
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.15)))
                    }.buttonStyle(.plain)
                }
                if state.command {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundColor(.purple)
                }
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(state.levels.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(accent)
                            .frame(width: 3, height: max(3, CGFloat(level) * 22))
                    }
                }
                .frame(height: 24)
                .animation(.easeOut(duration: 0.08), value: state.levels)
                if state.phase == .handsFree {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundColor(.black)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.red.opacity(0.9)))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text(state.command ? L("Elaboro…", "Working…") : L("Trascrivo…", "Transcribing…"))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        case .suggestion:
            HStack(spacing: 8) {
                Image(systemName: "book.closed").font(.system(size: 11)).foregroundColor(.white.opacity(0.8))
                Text(state.message)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                    .lineLimit(2).frame(maxWidth: 170, alignment: .leading)
                Button(action: onAccept) {
                    Text(L("Sì", "Yes")).font(.system(size: 10, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white))
                }.buttonStyle(.plain)
                Button(action: onReject) {
                    Text("No").font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.15)))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        case .message:
            Text(state.message)
                .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
