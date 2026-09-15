import AbleKitCore
import SwiftUI

/// What AbleKit is actually working from.
///
/// Computer-use behaviour is close to undebuggable from the outside: when an agent does something
/// unexpected, the question is always *what did it think it was looking at?* This answers it —
/// the context, the chosen capability, the refinement the router applied, and how each step was
/// verified (brief §25).
///
/// It is off by default and lives behind a Settings toggle, because none of this belongs in the
/// ordinary experience.
struct DebugDetailView: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if let context = session.latestContext {
                row("App", context.frontmostApplication?.localizedName ?? "unknown")
                row("Window", context.focusedWindow?.title ?? "none")
                row(
                    "Controls",
                    "\(context.accessibility?.interactiveElements.count ?? 0) readable"
                        + ((context.accessibility?.wasTruncated ?? false) ? " (truncated)" : "")
                )
                if let screen = context.screen {
                    row("Screen text", "\(screen.textRegions.count) regions")
                }
            }

            if let last = session.history.last {
                row("Capability", last.capability.displayName)
                row("Class", last.classification.rawValue)
                row("Result", last.outcome.summary)
                row("Took", String(format: "%.2fs", last.duration))
            }

            if !session.gatheredInformation.isEmpty {
                Divider()
                ForEach(session.gatheredInformation, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.source).font(.caption.bold())
                        Text(item.text)
                            .font(.caption.monospaced())
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }

            if session.history.count > 1 {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(session.history, id: \.id) { record in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(record.index + 1).")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.action.summary).font(.caption2)
                                    Text(record.outcome.summary)
                                        .font(.caption2)
                                        .foregroundStyle(
                                            // Both branches must be the same shape style; mixing
                                            // a hierarchical style with a Color does not type-check.
                                            record.outcome.isSuccess ? Color.secondary : Color.orange
                                        )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
