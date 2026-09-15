import AbleKitCore
import SwiftUI

/// The developer panel: what AbleKit can see, and what happens when it acts.
///
/// Two things that are otherwise impossible to check without running a whole task:
///
/// - **The inspector** shows the context exactly as the planner receives it — the same collector,
///   so it cannot disagree with what the agent actually saw.
/// - **The tester** runs a single action through the real pipeline, safety gate included. A tester
///   that bypassed the gate would be testing something other than what AbleKit does.
///
/// This is also the fastest way to find out whether a permission is really granted: the errors
/// here are the same ones a task would hit, without spending a task to find them.
struct DeveloperSettings: View {
    @Environment(AppState.self) private var state

    @State private var context: DesktopContext?
    @State private var includesScreen = false
    @State private var isWorking = false
    @State private var selectedElementID: String?
    @State private var report: ExecutionReport?
    @State private var elementFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            if let context {
                inspector(context)
            } else {
                ContentUnavailableView(
                    "Nothing captured yet",
                    systemImage: "viewfinder",
                    description: Text(
                        "Switch to the app you want to look at, then come back and capture. "
                            + "AbleKit reads whatever is frontmost."
                    )
                )
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                capture()
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Capture Context")
                }
            }
            .disabled(isWorking)

            Toggle("Include the screen", isOn: $includesScreen)
                .toggleStyle(.checkbox)
                .help("Also capture the screen and run text recognition over it")

            Spacer()

            if let context {
                Text(context.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func inspector(_ context: DesktopContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary(context)
                elements(context)
                if let report { result(report) }
            }
            .padding(12)
        }
    }

    private func summary(_ context: DesktopContext) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 3) {
                row("App", context.frontmostApplication?.localizedName ?? "unknown")
                row("Bundle", context.frontmostApplication?.bundleIdentifier ?? "\u{2014}")
                row("Window", context.focusedWindow?.title ?? "\u{2014}")
                row(
                    "Controls",
                    "\(context.accessibility?.elements.count ?? 0) total, "
                        + "\(context.accessibility?.interactiveElements.count ?? 0) worth showing"
                        + ((context.accessibility?.wasTruncated ?? false) ? ", truncated" : "")
                )
                if let screen = context.screen {
                    row(
                        "Screen",
                        screen.image.map { "\($0.width)\u{00D7}\($0.height)px" } ?? "no image"
                            + ", \(screen.textRegions.count) text regions"
                    )
                }
                if let selection = context.selectedText {
                    row("Selection", selection.prefix(60) + (selection.count > 60 ? "\u{2026}" : ""))
                }
                row("Displays", "\(context.arrangement.displays.count)")
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func elements(_ context: DesktopContext) -> some View {
        let all = context.accessibility?.interactiveElements ?? []
        let shown = elementFilter.isEmpty
            ? all
            : all.filter {
                ($0.bestLabel ?? "").localizedCaseInsensitiveContains(elementFilter)
                    || $0.role.localizedCaseInsensitiveContains(elementFilter)
            }

        GroupBox("Controls") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Filter by label or role", text: $elementFilter)
                    .textFieldStyle(.roundedBorder)

                if shown.isEmpty {
                    Text(
                        all.isEmpty
                            ? "This app exposes nothing to Accessibility. A task here would fall back to reading the screen."
                            : "Nothing matches."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    List(shown, selection: $selectedElementID) { element in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(element.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(element.description).font(.caption)
                                if !element.isEnabled {
                                    Text("disabled").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text(
                                "\(Int(element.frame.minX)), \(Int(element.frame.minY)) "
                                    + "\(Int(element.frame.width))\u{00D7}\(Int(element.frame.height))"
                                    + (element.actions.isEmpty
                                        ? "" : "  \u{2014}  \(element.actions.joined(separator: ", "))")
                            )
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                        .tag(element.id)
                    }
                    .frame(height: 150)

                    actionButtons(context, elements: all)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func actionButtons(_ context: DesktopContext, elements: [ElementReference]) -> some View {
        let selected = elements.first { $0.id == selectedElementID }

        HStack(spacing: 8) {
            Button("Highlight") {
                guard let selected else { return }
                run(.movePointer(to: .element(selected)), context: context)
            }
            .disabled(selected == nil)
            .help("Moves the pointer to the control, which is the safest way to check the geometry")

            Button("Press") {
                guard let selected else { return }
                run(.click(target: .element(selected)), context: context)
            }
            .disabled(selected == nil)
            .help("Runs a real click through the full pipeline, safety gate included")

            Spacer()

            Text("Runs through validation, policy and routing, exactly as a task would.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func result(_ report: ExecutionReport) -> some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 3) {
                row("Action", report.action.summary)
                row("Capability", report.capability.displayName)
                row("Class", report.classification.rawValue)
                row("Outcome", report.outcome.summary)
                if let refinement = report.refinement {
                    row("Refined", refinement)
                }
            }
            .padding(4)
        }
    }

    private func row(_ label: String, _ value: some StringProtocol) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capture() {
        isWorking = true
        Task {
            // A moment's delay so the Settings window is not itself the frontmost app being
            // inspected — which is the first thing everyone hits, and is never what they meant.
            try? await Task.sleep(for: .milliseconds(150))
            context = await state.inspectContext(includingScreen: includesScreen)
            report = nil
            selectedElementID = nil
            isWorking = false
        }
    }

    private func run(_ action: DesktopAction, context: DesktopContext) {
        Task { report = await state.testExecute(action, context: context) }
    }
}
