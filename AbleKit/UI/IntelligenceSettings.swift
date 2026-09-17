import AbleKitCore
import SwiftUI

/// Where AbleKit's reasoning runs, and the opt-in for Private Cloud Compute.
///
/// Opting in is the one setting in AbleKit that changes what leaves the Mac, so it is never a bare
/// toggle: turning it on shows exactly what would be sent and asks first. Turning it off needs no
/// confirmation — moving toward more privacy should never have friction.
struct IntelligenceSettings: View {
    @Environment(AppState.self) private var state
    @State private var isConfirmingCloud = false
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("On this Mac") {
                LabeledContent("Apple Intelligence") {
                    switch state.intelligenceAvailability {
                    case .available:
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable(let reason, _):
                        Text(reason).foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Use Private Cloud Compute when available", isOn: cloudBinding)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: state.cloudStatus.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(state.cloudStatus.isAvailable ? .green : .orange)
                        Text(state.cloudStatus.explanation)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Button("Test Connection") {
                        isTesting = true
                        Task {
                            await state.testCloudAccess()
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if state.cloudStatus == .accessNotGranted {
                    Text(
                        """
                        Until access is granted, AbleKit reasons on this Mac even with this \
                        setting on. Nothing is lost by leaving it on.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Private Cloud Compute")
            } footer: {
                Text(
                    """
                    Apple's larger model, running on Apple's privacy-hardened servers. It can plan \
                    harder tasks more reliably. Whenever it cannot be used, AbleKit reasons on this \
                    Mac instead, and the task window shows which was used.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshEnvironment() }
        .alert("Use Private Cloud Compute?", isPresented: $isConfirmingCloud) {
            Button("Cancel", role: .cancel) {}
            Button("Use Private Cloud Compute") {
                state.settings.reasoningLocation = .privateCloudCompute
            }
        } message: {
            Text(
                """
                To plan each step, AbleKit will send Apple a text description of what is on your \
                screen: the app and window names, the names and contents of controls, text read \
                from the screen, any text you have selected, and your request.

                Screenshots and your clipboard are never sent. Apple does not store the data or \
                make it accessible to anyone, including Apple.
                """
            )
        }
    }

    /// Turning on asks first; turning off takes effect immediately.
    private var cloudBinding: Binding<Bool> {
        Binding(
            get: { state.settings.reasoningLocation == .privateCloudCompute },
            set: { wantsCloud in
                if wantsCloud {
                    isConfirmingCloud = true
                } else {
                    state.settings.reasoningLocation = .onDevice
                }
            }
        )
    }
}
