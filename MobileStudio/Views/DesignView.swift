import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Design canvas in the main window: the look step before there is one, otherwise the app's screens as
/// mockups with the selected screen's versions underneath. Claude's design chat is in the sidebar.
struct DesignView: View {
    @Bindable var workspace: Workspace

    private var design: DesignModel { workspace.design }

    var body: some View {
        Group {
            if workspace.project.readyFolder == nil {
                ContentUnavailableView("No Project", systemImage: "paintpalette",
                                       description: Text("Open a Flutter project in the main window to design its screens."))
            } else {
                VStack(spacing: 0) {
                    DesignHeader(workspace: workspace)
                    Divider()
                    DesignNotices(workspace: workspace)
                    if design.stage == .look {
                        LookStage(workspace: workspace)
                    } else {
                        DesignCanvas(workspace: workspace)
                    }
                    if design.stage == .screens, let screen = design.focused {
                        Divider()
                        VersionStrip(workspace: workspace, screen: screen)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: $workspace.designDiffFile) { change in
            if let folder = workspace.project.readyFolder {
                DiffSheet(workspace: workspace, folder: folder, change: change) { workspace.designDiffFile = nil }
            }
        }
        .onAppear { design.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in design.refresh() }
    }
}

/// The step, the mode and zoom controls, and approving the look, above the canvas.
private struct DesignHeader: View {
    let workspace: Workspace

    private var design: DesignModel { workspace.design }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Step", selection: Binding(get: { design.stage }, set: { design.stage = $0 })) {
                Text("Look").tag(DesignModel.Stage.look)
                Text("Screens").tag(DesignModel.Stage.screens)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Look: the style, colours and fonts. Screens: every screen as a mockup.")
            Spacer()
            Toggle(isOn: Binding(get: { design.isDark }, set: { design.isDark = $0 })) {
                Label(design.isDark ? "Dark" : "Light", systemImage: design.isDark ? "moon.fill" : "sun.max")
            }
            .labelStyle(.iconOnly)
            .help("Show the mockups in \(design.isDark ? "light" : "dark") mode")
            Button { design.zoom = max(0.3, design.zoom - 0.1) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .labelStyle(.iconOnly)
                .help("Zoom out")
            Button { design.zoom = min(1.2, design.zoom + 0.1) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .labelStyle(.iconOnly)
                .help("Zoom in")
            Button("Use This Design", systemImage: "checkmark.seal", action: workspace.approveDesign)
                .buttonStyle(.borderedProminent)
                .disabled(design.tokens == nil || workspace.designBlocker != nil || workspace.designChat.isSending)
                .help(design.tokens == nil ? "Pick a look first."
                      : workspace.designBlocker ?? "Give the app this look: its theme, colours and fonts. Screens are built from their mockups later.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// What's wrong right now: the tokens, the latest answer's mockups, fonts that didn't download.
private struct DesignNotices: View {
    let workspace: Workspace

    var body: some View {
        let design = workspace.design
        let failedFonts = design.fonts.compactMap { family, state -> String? in
            if case .failed = state { return family }
            return nil
        }.sorted()
        VStack(spacing: 8) {
            if let issue = design.tokenIssues.first {
                Banner(tone: .warning, title: "The look has a problem", message: issue + (design.tokenIssues.count > 1 ? " (and \(design.tokenIssues.count - 1) more)" : ""))
            }
            if !failedFonts.isEmpty {
                Banner(tone: .warning, title: "Couldn't download \(failedFonts.formatted(.list(type: .and)))",
                       message: "The mockups show the system font instead. Check the connection and open the window again.")
            }
        }
        .padding(design.tokenIssues.isEmpty && failedFonts.isEmpty ? 0 : 12)
    }
}

// MARK: Canvas

/// Every screen as a mockup, side by side, in the order the app is used.
private struct DesignCanvas: View {
    let workspace: Workspace

    private var design: DesignModel { workspace.design }

    var body: some View {
        let items = workspace.designScreens
        if items.isEmpty {
            ContentUnavailableView("No Screens Yet", systemImage: "rectangle.portrait.slash",
                                   description: Text("Plan the app, or add a screen in the main chat, then design it here."))
        } else {
            ScrollView([.horizontal, .vertical]) {
                // Lazy, so a screen scrolled far out of view doesn't keep a web view alive.
                LazyHStack(alignment: .top, spacing: 36) {
                    ForEach(items) { item in
                        ArtboardTile(workspace: workspace, item: item)
                    }
                }
                .padding(36)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onTapGesture { design.selection = [] }
        }
    }
}

/// One screen on the canvas: its name and state, then its mockup (or what to do about not having one).
private struct ArtboardTile: View {
    let workspace: Workspace
    let item: DesignScreenItem

    private var design: DesignModel { workspace.design }
    private var isSelected: Bool { design.selection.contains(item.id) }

    var body: some View {
        let scale = design.zoom
        let width = DesignCanvasSize.width * scale
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 16) {
                board(version: item.design.flatMap(design.shownVersion(of:)), scale: scale)
                if isSelected, let comparing = design.comparing, design.focused?.id == item.id {
                    VStack(alignment: .leading, spacing: 4) {
                        board(version: comparing, scale: scale)
                        Text("Comparing with \(label(comparing))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                if isSelected { design.selection.remove(item.id) } else { design.selection.insert(item.id) }
            } else {
                design.selection = [item.id]
                design.comparing = nil
            }
        }
        .contextMenu { ArtboardMenu(workspace: workspace, item: item) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name) screen")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.name).font(.headline)
            if let screen = item.design {
                if design.staleScreens.contains(screen.id) {
                    StatusBadge(tone: .warning, title: "App changed")
                } else if let version = screen.versions.inApp, version != DesignVersions.current {
                    StatusBadge(tone: .success, title: "\(version) in the app")
                }
                let issues = screen.files.flatMap { design.lint["\(DesignPaths.screen(screen.id))/\($0)"] ?? [] }
                if !issues.isEmpty { StatusBadge(tone: .warning, title: "\(issues.count) to fix").help(issues.map(\.message).joined(separator: "\n")) }
            } else {
                StatusBadge(tone: .neutral, title: item.isBuilt ? "Not drawn" : "Planned")
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func board(version: String?, scale: Double) -> some View {
        let size = CGSize(width: DesignCanvasSize.width * scale, height: DesignCanvasSize.height * scale)
        let shape = RoundedRectangle(cornerRadius: DesignCanvasSize.cornerRadius(scale: scale), style: .continuous)
        Group {
            if let screen = item.design, let version, screen.files.contains(version + ".html") {
                ArtboardView(url: DesignURL.projectURL("screens/\(screen.id)/\(version).html"), folder: workspace.project.readyFolder,
                             dark: design.isDark, scale: scale, revision: design.revision)
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // Around the mockup rather than over it: the web view draws above SwiftUI overlays.
        .padding(4)
        .background(RoundedRectangle(cornerRadius: DesignCanvasSize.cornerRadius(scale: scale) + 4, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 3 : 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .overlay {
            if workspace.designChat.isSending, isWorkedOn {
                ProgressView().controlSize(.large).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// Whether the turn running now writes this screen.
    private var isWorkedOn: Bool {
        guard let request = workspace.designChat.messages.last(where: { $0.role == .user })?.text else { return false }
        return isSelected || request.localizedCaseInsensitiveContains(item.name)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: item.isBuilt ? "rectangle.portrait.on.rectangle.portrait" : "rectangle.dashed")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(item.isBuilt ? "Not drawn yet" : "Planned, not built").foregroundStyle(.secondary)
            if item.isBuilt {
                Button("Redesign") {
                    if let screen = workspace.screens.first(where: { AppFlow.screenKey($0.name) == AppFlow.screenKey(item.name) }) {
                        workspace.redesign(screen)
                    }
                }
                .disabled(!workspace.canSendDesign)
                .help(workspace.designBlocker ?? "Claude draws the screen as it is now, from its code")
            } else if workspace.design.tokens != nil {
                Button("Draw It") {
                    workspace.design.selection = [item.id]
                    workspace.sendDesignMessage("Draw the \(item.name) screen.")
                }
                .disabled(!workspace.canSendDesign)
                .help(workspace.designBlocker ?? "Claude draws this screen from the plan, in the app's look")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func label(_ version: String) -> String { version == DesignVersions.current ? "Current" : version }
}

/// What can be done with a screen on the canvas.
private struct ArtboardMenu: View {
    let workspace: Workspace
    let item: DesignScreenItem

    var body: some View {
        if item.isBuilt {
            Button("Redraw from the App") { workspace.redrawFromApp(item.id, name: item.name, file: item.file) }
                .disabled(!workspace.canSendDesign)
            Button("Take Picture from the Device") { workspace.captureCurrent(for: item.id) }
                .disabled(!workspace.canCapture)
        }
        if let screen = item.design {
            Button("Apply to the App") { workspace.applyDesign(to: screen.id) }
                .disabled(workspace.applyBlocker(for: screen) != nil)
            if let folder = workspace.project.readyFolder {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder).appendingPathComponent(DesignPaths.screen(screen.id))])
                }
            }
        }
    }
}

/// A mockup at any size. The page is always laid out at the phone's full size and the view scaled: zooming the page
/// itself would hit WebKit's minimum font size and reflow the text.
struct ArtboardView: View {
    let url: URL
    let folder: String?
    var tokensCSS: String?
    let dark: Bool
    let scale: Double
    let revision: Int

    var body: some View {
        ArtboardWebView(url: url, folder: folder, tokensCSS: tokensCSS, dark: dark, scale: scale, revision: revision)
            .frame(width: DesignCanvasSize.width * scale, height: DesignCanvasSize.height * scale)
            .accessibilityHidden(true)
    }
}

/// The web view behind `ArtboardView`: it serves `ms-design://` only and runs no page scripts.
private struct ArtboardWebView: NSViewRepresentable {
    let url: URL
    let folder: String?
    let tokensCSS: String?
    let dark: Bool
    let scale: Double
    let revision: Int

    @MainActor
    final class Coordinator {
        let handler = DesignSchemeHandler()
        var loaded: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ArtboardHost {
        let host = ArtboardHost(page: DesignWebView.make(handler: context.coordinator.handler))
        host.apply(scale: scale)
        return host
    }

    func updateNSView(_ host: ArtboardHost, context: Context) {
        let coordinator = context.coordinator
        coordinator.handler.folder = folder
        coordinator.handler.tokensOverride = tokensCSS
        host.apply(scale: scale)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if host.page.appearance != appearance { host.page.appearance = appearance }
        let key = "\(url.absoluteString)#\(revision)#\(tokensCSS?.hashValue ?? 0)"
        if coordinator.loaded != key {
            coordinator.loaded = key
            host.page.load(URLRequest(url: url))
        }
    }
}

/// Shows a page scaled down and clipped to the phone's corners. SwiftUI's clip doesn't reach an AppKit view, so a
/// scaled web view would paint over whatever sits beside it; the host clips the page on its own layer instead.
final class ArtboardHost: NSView {
    let page: WKWebView
    private var appliedScale: Double = 1

    init(page: WKWebView) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        page.wantsLayer = true
        page.frame = NSRect(x: 0, y: 0, width: DesignCanvasSize.width, height: DesignCanvasSize.height)
        addSubview(page)
    }

    required init?(coder: NSCoder) { fatalError("ArtboardHost is built in code") }

    /// AppKit resets a layer-backed view's anchor, position and transform when it lays out, so the scale is set again then.
    override func layout() {
        super.layout()
        apply(scale: appliedScale)
    }

    /// Scales the page from its top-left corner; the corner radius is in the scaled space.
    func apply(scale: Double) {
        appliedScale = scale
        page.layer?.anchorPoint = .zero
        page.layer?.position = .zero
        page.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        layer?.cornerRadius = DesignCanvasSize.cornerRadius(scale: scale)
        layer?.cornerCurve = .continuous
    }
}

// MARK: Versions

/// Pictures for the version strip, kept until the file changes: reading them in the view's body made every redraw wait on the disk.
@MainActor
private enum ThumbnailCache {
    private static var images: [URL: (modified: Date, image: NSImage)] = [:]

    static func image(_ url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return nil }
        if let cached = images[url], cached.modified == modified { return cached.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = (modified, image)
        return image
    }
}

/// The selected screen's versions: Current, then each version with what was asked for it, to show, compare,
/// choose and apply.
private struct VersionStrip: View {
    let workspace: Workspace
    let screen: DesignLibrary.Screen

    private var design: DesignModel { workspace.design }

    var body: some View {
        let shown = design.shownVersion(of: screen)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(screen.name).font(.headline)
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                if design.staleScreens.contains(screen.id) {
                    Button("Redraw from the App") { workspace.redrawFromApp(screen.id) }
                        .disabled(!workspace.canSendDesign)
                        .help("The screen's code changed since Current was drawn")
                }
                Menu("Compare") {
                    ForEach(choices.filter { $0 != shown }, id: \.self) { version in
                        Button(label(version)) { design.comparing = version }
                    }
                    if design.comparing != nil {
                        Divider()
                        Button("Stop Comparing") { design.comparing = nil }
                    }
                }
                .fixedSize()
                .disabled(choices.count < 2)
                .help("Show another version next to this one")
                Button("Choose") { if let shown { workspace.chooseVersion(shown, for: screen.id) } }
                    .disabled(shown == nil || shown == screen.versions.chosen || shown == DesignVersions.current)
                    .help("Make the version shown the reference for building this screen")
                Button("Apply to the App", systemImage: "hammer") { workspace.applyDesign(to: screen.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.applyBlocker(for: screen) != nil)
                    .help(workspace.applyBlocker(for: screen) ?? "Claude changes the screen's code to match the chosen version, in the main chat")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    if screen.hasCapture, let folder = workspace.project.readyFolder {
                        thumbnail(image: ThumbnailCache.image(URL(fileURLWithPath: folder).appendingPathComponent(DesignPaths.capture(screen.id))),
                                  title: "In the app", detail: "Picture from the device", selected: false, badges: []) {}
                    }
                    ForEach(choices, id: \.self) { version in
                        let entry = screen.versions.version(version)
                        thumbnail(image: design.previewURL(screen: screen.id, version: version).flatMap(ThumbnailCache.image),
                                  title: label(version),
                                  detail: version == DesignVersions.current ? "As the code builds it" : (entry?.summary.nonEmpty ?? entry?.request ?? ""),
                                  selected: version == shown, badges: badges(version)) {
                            design.shown[screen.id] = version
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .frame(height: 230)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var choices: [String] {
        (screen.hasCurrent ? [DesignVersions.current] : []) + screen.versions.versions.map(\.id)
    }

    private var summary: String {
        let count = screen.versions.versions.count
        return count == 0 ? "Not changed yet" : "\(count) version\(count == 1 ? "" : "s")"
    }

    private func label(_ version: String) -> String { version == DesignVersions.current ? "Current" : version }

    private func badges(_ version: String) -> [(StatusTone, String)] {
        var badges: [(StatusTone, String)] = []
        if screen.versions.chosen == version { badges.append((.success, "Chosen")) }
        if screen.versions.inApp == version { badges.append((.neutral, "In the app")) }
        return badges
    }

    private func thumbnail(image: NSImage?, title: String, detail: String, selected: Bool, badges: [(StatusTone, String)],
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 70, height: 152)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold))
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in StatusBadge(tone: badge.0, title: badge.1).font(.caption) }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 130, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Look

/// Style, then colours, then fonts: each a row of cards. Only picking a style costs a Claude turn; trying colours
/// and fonts swaps the tokens under the same drawing.
private struct LookStage: View {
    let workspace: Workspace
    @State private var ownColour = Color.accentColor

    private var design: DesignModel { workspace.design }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                styles
                if design.styleID != nil || design.tokens != nil {
                    colours
                    fonts
                    HStack {
                        Spacer()
                        Button("Use This Look", systemImage: "checkmark", action: workspace.useLook)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(design.palette == nil || workspace.designChat.isSending)
                            .help(design.palette == nil ? "Pick a colour theme first." : "Save this look and draw the other screens in it")
                    }
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { design.downloadStyleFonts() }
    }

    private var styles: some View {
        let recommended = DesignStyle.recommended(for: workspace.plan)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("1. Style", detail: "Picking one asks Claude to draw your first screen in it and suggest colours and fonts (about $1–3). You can also describe your own in the chat.")
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(DesignStyle.bundled) { style in
                        LookCard(title: style.name, detail: style.feel, isSelected: design.styleID == style.id,
                                 badge: recommended == style.id ? "Recommended" : nil) {
                            ArtboardView(url: DesignURL.styleURL(style.id), folder: nil, dark: design.isDark, scale: 0.36,
                                         revision: design.revision)
                        } action: {
                            workspace.chooseStyle(style.id)
                        }
                        .disabled(!workspace.canSendDesign)
                        .help(workspace.designBlocker ?? "Draw the app in the \(style.name) style")
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var colours: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("2. Colours", detail: design.suggestions.palettes.isEmpty ? "Claude suggests colour themes once it has drawn the first screen."
                         : "Try each on your first screen. Trying costs nothing.")
            if let screen = design.lookScreen, let version = screen.shown, !design.suggestions.palettes.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(design.palettes) { palette in
                            LookCard(title: palette.name, detail: palette.mood, isSelected: design.paletteID == palette.id, badge: nil) {
                                lookBoard(screen: screen, version: version, look: design.lookTokens(palette: palette))
                            } action: {
                                design.paletteID = palette.id
                            }
                            .help(palette.why)
                        }
                    }
                    .padding(.bottom, 6)
                }
                HStack(spacing: 10) {
                    Button("More Like These") { workspace.moreSuggestions(.palettes, hint: "more like \(design.palette?.name ?? "these")") }
                    Button("Something Different") { workspace.moreSuggestions(.palettes, hint: "something clearly different from these") }
                    Divider().frame(height: 18)
                    ColorPicker("Use my colour", selection: $ownColour, supportsOpacity: false)
                    Button("Build Themes Around It") {
                        workspace.moreSuggestions(.palettes, hint: "themes built around the brand colour \(hex(ownColour))")
                    }
                }
                .disabled(!workspace.canSendDesign)
                .controlSize(.small)
            } else if workspace.designChat.isSending {
                ProgressView("Claude is drawing your first screen…").controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var fonts: some View {
        if let screen = design.lookScreen, let version = screen.shown, !design.suggestions.pairings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("3. Fonts", detail: "Google Fonts pairings: one for headlines, one for everything else.")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(design.pairings) { pairing in
                            LookCard(title: pairing.title, detail: pairing.why, isSelected: design.pairingID == pairing.id,
                                     badge: fontBadge(pairing)) {
                                lookBoard(screen: screen, version: version, look: design.lookTokens(pairing: pairing))
                            } action: {
                                design.pairingID = pairing.id
                            }
                            .onAppear { if let look = design.lookTokens(pairing: pairing) { design.downloadFonts(for: look, install: false) } }
                        }
                    }
                    .padding(.bottom, 6)
                }
                Button("More Fonts") { workspace.moreSuggestions(.pairings) }
                    .disabled(!workspace.canSendDesign)
                    .controlSize(.small)
            }
        }
    }

    private func lookBoard(screen: DesignLibrary.Screen, version: String, look: DesignTokens?) -> some View {
        ArtboardView(url: DesignURL.projectURL("screens/\(screen.id)/\(version).html"), folder: workspace.project.readyFolder,
                     tokensCSS: look.map(design.css(for:)), dark: design.isDark, scale: 0.36, revision: design.revision)
    }

    private func fontBadge(_ pairing: LookSuggestions.Pairing) -> String? {
        let states = [pairing.display, pairing.body].compactMap { design.fonts[$0] }
        if states.contains(.downloading) { return "Downloading…" }
        if states.contains(where: { if case .failed = $0 { true } else { false } }) { return "Not downloaded" }
        return nil
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

/// A card of the look step: a small mockup, a name and a line, selectable.
private struct LookCard<Board: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let badge: String?
    @ViewBuilder let board: Board
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // The ring goes around the mockup, not over it: the web view draws above SwiftUI overlays.
                board
                    .frame(width: DesignCanvasSize.width * 0.36, height: DesignCanvasSize.height * 0.36)
                    .clipShape(RoundedRectangle(cornerRadius: DesignCanvasSize.cornerRadius(scale: 0.36), style: .continuous))
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: DesignCanvasSize.cornerRadius(scale: 0.36) + 4, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 3 : 1))
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: DesignCanvasSize.width * 0.36 + 8, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Chat

/// The design chat: the same transcript rows as the main chat, with a composer that knows what's selected.
struct DesignChatPanel: View {
    let workspace: Workspace
    @FocusState private var focused: Bool
    @State private var attaching = false
    @State private var dropTargeted = false

    private var chat: ChatModel { workspace.designChat }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Designer").font(.headline)
                Spacer()
                if chat.totalCost > 0 {
                    Text(chat.totalCost, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .help(String(format: "Spent on Claude in this design chat: $%.3f", chat.totalCost))
                }
                Button { chat.reset() } label: { Label("New Chat", systemImage: "square.and.pencil").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .disabled(chat.messages.isEmpty || chat.isSending)
                    .help("Start a new design chat. The mockups stay.")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if chat.messages.isEmpty { empty }
                        ForEach(chat.messages) { message in
                            MessageRow(message: message, actions: actions).id(message.id)
                        }
                        if let pending = workspace.approvals.current {
                            ApprovalCard(pending: pending, others: workspace.approvals.queue.count - 1, onAnswer: workspace.approvals.answer)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.last?.activity.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actions: ChatRowActions {
        ChatRowActions(chat: chat, folder: workspace.project.readyFolder, canSend: workspace.canSendDesign,
                       isBusy: chat.isSending, undo: workspace.undoDesign,
                       choose: { answers, message in
                           let labels = answers.flatMap(\.labels)
                           chat.recordChoice(labels, for: message.id)
                           workspace.sendDesignMessage(answers.count == 1 ? ChoiceSet.reply(choosing: labels) : ChoiceSet.reply(answering: answers))
                       },
                       other: { focused = true }, showDiff: { workspace.designDiffFile = $0 })
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "paintpalette").font(.title).foregroundStyle(.secondary)
            Text("Design your app's screens").font(.title3.weight(.semibold))
            Text(workspace.designBlocker ?? (workspace.design.stage == .look
                 ? "Pick a style to start, or describe the look you want."
                 : "Select a screen and say what to change. Each request makes a new version to compare; nothing in the app changes until you apply one."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var placeholder: String {
        if let blocker = workspace.designBlocker { return blocker }
        let design = workspace.design
        if design.stage == .look, design.tokens == nil, design.styleID == nil { return "Describe the look you want" }
        let names = workspace.designScreens.filter { design.selection.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "Select a screen, then describe a change"
        case 1: return "Describe a change to \(names[0])"
        default: return "Describe a change to these \(names.count) screens"
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !workspace.designAttachments.isEmpty { attachments }
            TextField(placeholder, text: Binding(get: { workspace.designDraft }, set: { workspace.designDraft = $0 }), axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
                .disabled(workspace.designBlocker != nil)
                .padding(.horizontal, 10).padding(.top, workspace.designAttachments.isEmpty ? 10 : 6).padding(.bottom, 6)
            HStack {
                Text("Say \"show me three\" for several versions.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { attaching = true } label: { Label("Attach Screenshot", systemImage: "paperclip").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .disabled(workspace.designBlocker != nil)
                    .help("Attach a screenshot for reference. You can also drop pictures here.")
                if chat.isSending {
                    Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly) }
                        .help("Stop Claude")
                } else {
                    Button(action: send) { Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!workspace.canSendDesign || !canSend)
                        .help("Send (Return)")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused || dropTargeted ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
        .dropDestination(for: URL.self) { urls, _ in
            let pictures = urls.filter(\.isFileURL)
            guard !pictures.isEmpty, workspace.designBlocker == nil else { return false }
            workspace.attachDesignReferences(pictures)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $attaching, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { workspace.attachDesignReferences(urls) }
        }
        .padding(12)
    }

    /// The pictures waiting to go with the next message, each removable before it's sent.
    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(workspace.designAttachments.enumerated()), id: \.element) { index, path in
                    HStack(spacing: 6) {
                        if let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                                .accessibilityHidden(true)
                        }
                        Text("Reference \(index + 1)").font(.callout)
                        Button { workspace.removeDesignAttachment(path) } label: {
                            Label("Remove Reference \(index + 1)", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this reference")
                    }
                    .padding(4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    private var canSend: Bool {
        !workspace.designDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workspace.designAttachments.isEmpty
    }

    private func send() {
        let text = workspace.designDraft
        guard workspace.canSendDesign, canSend else { return }
        workspace.designDraft = ""
        workspace.sendDesignMessage(text)
    }
}
