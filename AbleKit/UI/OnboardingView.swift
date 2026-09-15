import AbleKitCore
import SwiftUI

/// First-run setup.
///
/// AbleKit asks for two of the most powerful permissions macOS has. The honest way to do that is to
/// say what each one buys, what still works without it, and let the user decide — rather than
/// throwing up a system prompt and hoping. Nothing here fails silently: every permission shows its
/// live status and re-checks when the user comes back from System Settings (brief §26).
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                intelligenceSection
                permissionsSection
                privacyNote
                footer
            }
            .padding(28)
        }
        .frame(minWidth: 520, minHeight: 520)
        .task { await state.refreshEnvironment() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
            Text("AbleKit")
                .font(.largeTitle.weight(.semibold))
            Text(
                """
                AbleKit can see what is on your screen and operate applications for you \u{2014} \
                including the ones that have no API and cannot be connected to anything.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intelligenceSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol(for: state.intelligenceAvailability.isAvailable))
                    .foregroundStyle(state.intelligenceAvailability.isAvailable ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Intelligence").font(.headline)
                    switch state.intelligenceAvailability {
                    case .available:
                        Text("Ready. All reasoning happens on this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .unavailable(let reason, let suggestion):
                        Text(reason).font(.callout)
                        if let suggestion {
                            Text(suggestion).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.title3.weight(.semibold))

            ForEach(PermissionKind.allCases) { permission in
                PermissionRow(permission: permission)
                    .environment(state)
            }
        }
    }

    private var privacyNote: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("What leaves this Mac", systemImage: "lock.shield")
                    .font(.headline)
                Text(
                    """
                    Nothing, unless you ask it to. Screenshots are analysed locally and never \
                    written to disk. There is no AbleKit account and no AbleKit server. When a \
                    task involves another application such as Copilot, AbleKit shows you exactly \
                    what it is about to send and waits for you to agree.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            if state.permissions.hasMinimumPermissions {
                Label("Ready to go", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Accessibility is required before AbleKit can operate anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.permissions.hasMinimumPermissions)
        }
    }

    private func statusSymbol(for granted: Bool) -> String {
        granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }
}

private struct PermissionRow: View {
    let permission: PermissionKind
    @Environment(AppState.self) private var state

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isGranted ? .green : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 6) {
                    Text(permission.displayName).font(.headline)
                    Text(permission.rationale)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isGranted {
                        Text(permission.degradedBehaviour)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                if !isGranted {
                    VStack(spacing: 6) {
                        Button("Grant\u{2026}") {
                            Task {
                                await state.permissions.request(permission)
                                if let url = permission.settingsURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Button("Re-check") { state.permissions.refresh() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .padding(6)
        }
    }

    private var isGranted: Bool {
        state.permissions.isGranted(permission)
    }
}
