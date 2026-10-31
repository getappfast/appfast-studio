import SwiftUI

struct StatusLine: View {
    let color: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).fontWeight(.semibold)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }
}

struct Field: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }
}

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

/// A titled box: the header row with optional controls on the right, a divider, then the content.
/// Used for the project card and each section in Settings.
struct SectionCard<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, systemImage: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: systemImage).font(.headline).lineLimit(1).fixedSize()
                    Spacer()
                    accessory()
                }
                Divider()
                content()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
}
