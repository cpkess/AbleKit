import AbleKitCore
import AppKit
import SwiftUI

/// The panel shown while a task runs.
@MainActor
final class HUDWindowController {
    private let panel: FloatingPanel

    init(state: AppState) {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 140),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        // Above the overlay highlight, so the controls are never obscured by the thing they
        // control. The user must be able to reach Stop at all times.
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.contentView = NSHostingView(
            rootView: AgentHUDView(onDismiss: { [weak panel] in panel?.orderOut(nil) })
                .environment(state)
        )
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Bottom-right: out of the way of whatever AbleKit is operating, but always in sight.
        panel.setFrameOrigin(
            NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        )
        panel.orderFrontRegardless()
    }
}

/// What AbleKit is doing, and how to stop it.
///
/// The brief's requirement is that the user can *always* pause, stop, or take over (§21). Those
/// three controls are therefore permanent fixtures here, not something revealed on hover or hidden
/// behind a disclosure — and Stop is never disabled while a task is running.
struct AgentHUDView: View {
    let onDismiss: () -> Void

    @Environment(AppState.self) private var state
    @State private var showsDetail = false
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prompt = state.interaction.pending {
                promptView(prompt)
            } else if let session = state.session {
                header(session)
                activity(session)
                controls(session)
            } else {
                Text("Nothing running")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    // MARK: - Running

    private func header(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            if session.phase.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: session.phase.symbol)
                    .foregroundStyle(session.phase.tint)
            }
            Text(session.goal)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func activity(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.currentActivity ?? session.phase.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !session.history.isEmpty {
                Text("Step \(session.history.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if showsDetail, state.settings.showsDebugInterface {
                DebugDetailView(session: session)
            }
        }
    }

    @ViewBuilder
    private func controls(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            if session.phase.isTerminal {
                Button("Done") {
                    state.dismissFinishedTask()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                if session.phase == .paused {
                    Button("Resume") { state.resume() }
                } else {
                    Button("Pause") { state.pause() }
                }
                Button("Stop", role: .destructive) {
                    state.cancel()
                    onDismiss()
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            Spacer()

            if state.settings.showsDebugInterface {
                Button {
                    showsDetail.toggle()
                } label: {
                    Image(systemName: showsDetail ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Show what AbleKit is working from")
            }
        }
    }

    // MARK: - Asking the user

    @ViewBuilder
    private func promptView(_ prompt: UserPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch prompt.style {
            case .confirmation(let action, let reason):
                Label("Confirm before continuing", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(action.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The full text of anything leaving the machine is shown, never summarised —
                // the user cannot consent to a handoff they have not seen (brief §15).
                if case .askAIBridge(let bridge, let text) = action {
                    GroupBox("Sent to \(bridge.displayName)") {
                        ScrollView {
                            Text(text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }

                HStack {
                    Button("Don't") { state.interaction.decline() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Go Ahead") { state.interaction.approve() }
                        .keyboardShortcut(.defaultAction)
                }

            case .input:
                Label("AbleKit needs to know", systemImage: "questionmark.circle.fill")
                    .font(.headline)
                Text(prompt.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Your answer", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitAnswer() }
                HStack {
                    Button("Cancel") { state.interaction.dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Send") { submitAnswer() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submitAnswer() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer = ""
        state.interaction.answer(trimmed)
    }
}

extension AgentPhase {
    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .waitingForUser: "questionmark.circle.fill"
        default: "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}
