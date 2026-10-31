import SwiftUI

/// How a status reads at a glance. Every tone has its own symbol as well as its colour, so it never
/// depends on colour alone.
enum StatusTone: Equatable {
    case success, warning, failure, neutral

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .neutral: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .neutral: .secondary
        }
    }
}

/// Symbol, title and an optional detail, read by VoiceOver as one phrase.
struct StatusBadge: View {
    let tone: StatusTone
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tone.symbol).foregroundStyle(tone.tint).imageScale(.small)
            Text(title).fontWeight(.semibold)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A command to copy into Terminal, with what it is for.
struct CommandHint: View {
    let label: String
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// A notice floating over the simulator: what happened, and what to do about it.
struct Banner<Actions: View>: View {
    let tone: StatusTone
    let title: String
    var message: String?
    var showsProgress = false
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: tone.symbol).foregroundStyle(tone.tint).font(.title3)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let message {
                    Text(message).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                HStack(spacing: 8) { actions() }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            }
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

extension Banner where Actions == EmptyView {
    init(tone: StatusTone, title: String, message: String? = nil, showsProgress: Bool = false, onDismiss: (() -> Void)? = nil) {
        self.init(tone: tone, title: title, message: message, showsProgress: showsProgress, onDismiss: onDismiss) { EmptyView() }
    }
}

extension FileSnapshot.Change.Kind {
    /// The one-letter badge git uses: M, A, D.
    var badge: String {
        switch self { case .modified: "M"; case .added: "A"; case .deleted: "D" }
    }

    var tint: Color {
        switch self { case .modified: .orange; case .added: .green; case .deleted: .red }
    }

    var verb: String {
        switch self { case .modified: "edited"; case .added: "new"; case .deleted: "removed" }
    }

    var symbol: String {
        switch self { case .modified: "pencil.circle.fill"; case .added: "plus.circle.fill"; case .deleted: "minus.circle.fill" }
    }
}

/// One changed file in plain words ("Home screen · edited"), with its path underneath for developers.
struct FileChangeRow: View {
    let change: FileSnapshot.Change
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: change.kind.symbol).foregroundStyle(change.kind.tint).imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                (Text(FriendlyName.of(change.path)) + Text(" · \(change.kind.verb)").foregroundStyle(.secondary))
                    .lineLimit(1)
                if !compact {
                    Text(change.path).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
        }
        .font(compact ? .caption : .callout)
        .help(change.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(FriendlyName.of(change.path)), \(change.kind.verb)")
    }
}

/// The context menu of a screen, in the sidebar and on the app flow map.
struct ScreenMenu: View {
    let workspace: Workspace
    let screen: AppScreen

    var body: some View {
        Button("Ask Claude About It") { workspace.mention(screen) }
        if let folder = workspace.project.readyFolder {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(screen.file)
            Button("Open Code") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
