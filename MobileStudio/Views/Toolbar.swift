import SwiftUI

/// The window toolbar, laid out like Xcode's: Run and Stop on the left, the destination and what is
/// happening in the middle, the tools for a running app and the panel toggles on the right.
struct WorkspaceToolbar: ToolbarContent {
    let workspace: Workspace

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: workspace.runApp) { Label("Run", systemImage: "play.fill") }
                .disabled(!workspace.canRun)
                .help(workspace.runBlocker.map { "Run (⌘R): \($0)" } ?? "Run (⌘R)")
            Button(action: workspace.stopApp) { Label("Stop", systemImage: "stop.fill") }
                .disabled(!workspace.canStop)
                .help("Stop (⌘.)")
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                DestinationMenu(workspace: workspace)
                Divider().frame(height: 16).padding(.horizontal, 8)
                ActivityView(activity: workspace.activity)
            }
            .padding(.horizontal, 10)
            // Capped so a long status ("Running … on …") truncates instead of pushing the right-hand buttons into
            // the toolbar's overflow menu at the smallest window size.
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 380)
            .frame(height: 28)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }

        // Hot Reload isn't here: Claude's edits reload on their own, and it stays in the Product menu (⇧⌘R).
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Canvas", selection: Bindable(workspace).canvas) {
                Label("Device", systemImage: "iphone").tag(Workspace.Canvas.device)
                    .help("Show the running app (⌘1)")
                Label("App Flow", systemImage: "point.3.connected.trianglepath.dotted").tag(Workspace.Canvas.flow)
                    .help("Show how the app's screens connect (⌘2)")
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the device or a map of the app's screens")
            // The one tool in the toolbar with words: pointing at something is how low-code users say "this one".
            Toggle(isOn: Binding(get: { workspace.pick.isPicking }, set: { _ in workspace.togglePick() })) {
                Label("Point at…", systemImage: "scope").labelStyle(.titleAndIcon)
            }
            .disabled(!workspace.canPick)
            .help("Point at something in the app to show Claude what you mean (⇧⌘E)")
            Toggle(isOn: Bindable(workspace).isLogVisible) { Label("Build Log", systemImage: "text.alignleft") }
                .help("Show Build Log (⇧⌘Y)")
            Toggle(isOn: Bindable(workspace).isChatVisible) { Label("Chat", systemImage: "sidebar.right") }
                .help("Show Chat (⌥⌘0)")
        }
    }
}

/// The simulator to run on, grouped by runtime, with Boot and Shut Down for the selected one.
struct DestinationMenu: View {
    let workspace: Workspace
    private var simulator: SimulatorModel { workspace.simulator }

    var body: some View {
        Menu {
            ForEach(runtimes, id: \.self) { runtime in
                Section(runtime) {
                    ForEach(simulator.devices.filter { $0.runtime == runtime }) { device in
                        Toggle(isOn: Binding(get: { device.udid == simulator.selected?.udid },
                                             set: { _ in simulator.select(device) })) {
                            Text(device.isBooted ? "\(device.name) (Booted)" : device.name)
                        }
                    }
                }
            }
            if let device = simulator.selected {
                Divider()
                if device.isBooted {
                    Button("Shut Down \(device.name)") { simulator.shutdown() }.disabled(simulator.isBusy)
                } else {
                    Button("Boot \(device.name)") { simulator.boot() }.disabled(simulator.isBusy || device.isTransitioning)
                }
            }
        } label: {
            Label(simulator.selected?.name ?? "Choose Simulator", systemImage: "iphone")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(simulator.devices.isEmpty)
        .help("Destination")
    }

    private var runtimes: [String] {
        var seen = Set<String>()
        return simulator.devices.map(\.runtime).filter { seen.insert($0).inserted }
    }
}

/// What the app is doing right now, in one line.
struct ActivityView: View {
    let activity: Workspace.Activity

    var body: some View {
        HStack(spacing: 6) {
            if activity.busy {
                ProgressView().controlSize(.mini)
            } else if activity.tone != .neutral {
                Image(systemName: activity.tone.symbol).foregroundStyle(activity.tone.tint).imageScale(.small)
            }
            Text(activity.text).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(activity.tone == .neutral && !activity.busy ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
