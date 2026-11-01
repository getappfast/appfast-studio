import SwiftUI

/// The app's screens as a map, left to right from where it starts, with an arrow for each way from one screen to
/// another. It's read from the source (`FlowFinder`), so it shows before the app has ever run.
struct FlowCanvas: View {
    let workspace: Workspace
    /// How much of the canvas the floating sidebar covers. It isn't a safe area, so the map keeps clear of it itself.
    var leadingInset: CGFloat = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if let flow = workspace.flowWithPlan, flow.folder == workspace.project.readyFolder, !flow.screens.isEmpty {
            FlowMap(workspace: workspace, flow: flow, leadingInset: leadingInset)
        } else {
            message.padding(.leading, leadingInset)
        }
    }

    @ViewBuilder
    private var message: some View {
        if workspace.project.readyFolder == nil {
            ContentUnavailableView("No Project", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Open a Flutter project to see how its screens connect."))
        } else if workspace.flow?.folder == workspace.project.readyFolder {
            ContentUnavailableView("No Screens Found", systemImage: "rectangle.portrait.slash",
                                   description: Text("Screens are widgets named like HomePage, SettingsScreen or ProfileView. Ask Claude to add one."))
        } else {
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text("Reading the app's screens…")
            }
        }
    }
}

/// Where each card goes. Columns are centred on the tallest one; the unlinked screens get a column of their own
/// at the end, under a heading.
struct FlowGeometry {
    static let card = CGSize(width: 128, height: 232)
    static let spacing = CGSize(width: 104, height: 28)
    static let margin = CGSize(width: 48, height: 72)

    let frames: [String: CGRect]
    /// The top centre of the unlinked column, for its heading.
    let unlinkedTop: CGPoint?
    let size: CGSize

    init(_ layout: AppFlow.Layout) {
        let card = Self.card, spacing = Self.spacing, margin = Self.margin
        var columns = layout.columns
        if !layout.unlinked.isEmpty { columns.append(layout.unlinked) }
        func height(_ count: Int) -> CGFloat { CGFloat(count) * card.height + CGFloat(max(count - 1, 0)) * spacing.height }
        let tallest = height(columns.map(\.count).max() ?? 0)

        var frames: [String: CGRect] = [:]
        var unlinkedTop: CGPoint?
        var x = margin.width
        for (index, column) in columns.enumerated() {
            let isUnlinked = !layout.unlinked.isEmpty && index == columns.count - 1
            // A wider gap before the unlinked screens, so they don't read as the next step.
            if isUnlinked, index > 0 { x += spacing.width * 0.5 }
            let top = margin.height + (tallest - height(column.count)) / 2
            for (row, name) in column.enumerated() {
                frames[name] = CGRect(x: x, y: top + CGFloat(row) * (card.height + spacing.height), width: card.width, height: card.height)
            }
            if isUnlinked { unlinkedTop = CGPoint(x: x + card.width / 2, y: top) }
            x += card.width + spacing.width
        }
        self.frames = frames
        self.unlinkedTop = unlinkedTop
        size = CGSize(width: x - spacing.width + margin.width, height: tallest + margin.height * 2)
    }
}

private struct FlowMap: View {
    let workspace: Workspace
    let flow: AppFlow
    let leadingInset: CGFloat
    @State private var hovered: String?

    var body: some View {
        let geometry = FlowGeometry(flow.layout)
        GeometryReader { proxy in
            // Shrunk to fit the canvas, down to half size; a bigger map scrolls.
            let visible = CGSize(width: max(proxy.size.width - leadingInset, 1), height: proxy.size.height)
            let scale = min(1, max(0.5, min(visible.width / geometry.size.width, visible.height / geometry.size.height)))
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    FlowArrows(links: flow.links, frames: geometry.frames, highlighted: hovered)
                    if let top = geometry.unlinkedTop {
                        Text("No links found")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: top.x, y: top.y - 22)
                    }
                    ForEach(flow.screens) { screen in
                        if let frame = geometry.frames[screen.className] {
                            card(screen)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width * scale, height: geometry.size.height * scale, alignment: .topLeading)
                // Centred when the map is smaller than the canvas.
                .frame(minWidth: visible.width, minHeight: visible.height)
                // Padding rather than contentMargins: a scroll view centres content narrower than itself, margins
                // and all, which pushed the map right by half the inset.
                .padding(.leading, leadingInset)
            }
        }
        .overlay(alignment: .bottomLeading) {
            FlowLegend(hasLinks: !flow.links.isEmpty, hasPlanned: flow.screens.contains(where: \.isPlanned)).padding(12).padding(.leading, leadingInset)
        }
    }

    private func card(_ screen: AppScreen) -> some View {
        Button { workspace.mention(screen) } label: {
            ScreenCard(screen: screen, isStart: screen.className == flow.start, isHighlighted: hovered == screen.className)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = screen.className } else if hovered == screen.className { hovered = nil }
        }
        .help(screen.isPlanned ? "Planned, not built yet. Ask Claude to build the \(screen.name) screen."
                               : "Ask Claude to change the \(screen.name) screen (\(screen.file))")
        .contextMenu { ScreenMenu(workspace: workspace, screen: screen) }
        .accessibilityLabel(accessibilityLabel(screen))
        .accessibilityHint("Starts a chat message about this screen.")
    }

    private func accessibilityLabel(_ screen: AppScreen) -> String {
        let names = Dictionary(flow.screens.map { ($0.className, $0.name) }, uniquingKeysWith: { first, _ in first })
        let leads = flow.links.filter { $0.from == screen.className }.compactMap { names[$0.to] }
        var label = screen.isPlanned ? "\(screen.name) screen, planned and not built yet" : "\(screen.name) screen"
        if screen.className == flow.start { label += ", where the app starts" }
        if !leads.isEmpty { label += ". Leads to \(leads.formatted(.list(type: .and)))" }
        return label
    }
}

/// A screen on the map, shaped like a phone so a picture of the screen can take its place later.
private struct ScreenCard: View {
    let screen: AppScreen
    let isStart: Bool
    let isHighlighted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 6) {
            if isStart {
                Label("Start", systemImage: "flag.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.title2).foregroundStyle(.tertiary)
            Text(screen.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(screen.isPlanned ? "Planned" : (screen.file as NSString).lastPathComponent)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: shape)
        .overlay(shape.strokeBorder(isHighlighted ? Color.accentColor : Color(nsColor: screen.isPlanned ? .tertiaryLabelColor : .separatorColor),
                                    style: StrokeStyle(lineWidth: isHighlighted ? 2 : 1, dash: screen.isPlanned ? [6, 4] : [])))
        .contentShape(shape)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// How each kind of link is drawn. The dash, not the colour, tells them apart.
extension AppFlow.Kind {
    var dash: [CGFloat] {
        switch self {
        case .opens: []
        case .replaces: [9, 4]
        case .contains: [2, 4]
        }
    }

    var title: String {
        switch self {
        case .opens: "Opens"
        case .replaces: "Goes to, no way back"
        case .contains: "Shown inside"
        }
    }
}

/// The arrows between cards. Forward links run from the right edge of one card to the left edge of the next;
/// links back, or within a column, loop under the cards.
private struct FlowArrows: View {
    let links: [AppFlow.Link]
    let frames: [String: CGRect]
    let highlighted: String?

    var body: some View {
        Canvas { context, _ in
            let outgoing = Dictionary(grouping: links, by: \.from)
            let incoming = Dictionary(grouping: links, by: \.to)
            // The highlighted screen's links last, so they're drawn on top.
            for link in links.sorted(by: { isHighlighted($0) ? false : isHighlighted($1) }) {
                guard let from = frames[link.from], let to = frames[link.to] else { continue }
                let fromSpread = spread(link, among: outgoing[link.from] ?? [])
                let toSpread = spread(link, among: incoming[link.to] ?? [])
                var path = Path()
                let end: CGPoint, control: CGPoint
                if abs(to.minX - from.minX) < 1 {
                    // Same column: straight from one card to the other.
                    let down = to.minY > from.minY
                    let start = CGPoint(x: from.midX + fromSpread * 18, y: down ? from.maxY : from.minY)
                    end = CGPoint(x: to.midX + toSpread * 18, y: down ? to.minY - 1 : to.maxY + 1)
                    control = CGPoint(x: end.x, y: (start.y + end.y) / 2)
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: control.y), control2: control)
                } else if to.minX > from.maxX {
                    let start = CGPoint(x: from.maxX, y: from.midY + fromSpread * 16)
                    end = CGPoint(x: to.minX - 1, y: to.midY + toSpread * 16)
                    let bend = (end.x - start.x) / 2
                    control = CGPoint(x: end.x - bend, y: end.y)
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: control)
                } else {
                    let start = CGPoint(x: from.midX + fromSpread * 18, y: from.maxY)
                    end = CGPoint(x: to.midX + toSpread * 18, y: to.maxY + 1)
                    let drop = 48 + abs(end.x - start.x) * 0.12
                    control = CGPoint(x: end.x, y: max(start.y, end.y) + drop)
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: max(start.y, end.y) + drop), control2: control)
                }
                // Color.secondary is a style, not a colour, and draws too faint in a Canvas in dark mode.
                let color = isHighlighted(link) ? Color.accentColor : Color.primary.opacity(highlighted == nil ? 0.5 : 0.2)
                let width: CGFloat = isHighlighted(link) ? 2 : 1.25
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: link.kind.dash))
                context.fill(arrowhead(at: end, from: control), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func isHighlighted(_ link: AppFlow.Link) -> Bool {
        highlighted != nil && (link.from == highlighted || link.to == highlighted)
    }

    /// Spreads the ends of several links on one card side, from -1 to 1, so they don't start from one point.
    private func spread(_ link: AppFlow.Link, among links: [AppFlow.Link]) -> CGFloat {
        guard links.count > 1, let index = links.firstIndex(of: link) else { return 0 }
        return CGFloat(index) / CGFloat(links.count - 1) * 2 - 1
    }

    private func arrowhead(at tip: CGPoint, from control: CGPoint) -> Path {
        let angle = atan2(tip.y - control.y, tip.x - control.x)
        let length: CGFloat = 9, spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()
        return path
    }
}

/// What the line styles mean, and what clicking does.
private struct FlowLegend: View {
    let hasLinks: Bool
    var hasPlanned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasLinks {
                ForEach([AppFlow.Kind.opens, .replaces, .contains], id: \.self) { kind in
                    HStack(spacing: 8) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 5))
                            path.addLine(to: CGPoint(x: 28, y: 5))
                        }
                        .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: kind.dash))
                        .frame(width: 28, height: 10)
                        Text(kind.title)
                    }
                }
            } else {
                Text("No links between screens were found in the code.")
            }
            if hasPlanned {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(width: 28, height: 10)
                    Text("Planned, not built yet")
                }
            }
            Text("Click a screen to ask Claude about it.").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
    }
}
