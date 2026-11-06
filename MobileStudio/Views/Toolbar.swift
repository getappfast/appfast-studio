import SwiftUI

/// The window toolbar, laid out like Xcode's: Run and Stop on the left, the destination and what is
/// happening in the middle, the tools for a running app and the panel toggles on the right.
struct WorkspaceToolbar: ToolbarContent {
    let workspace: Workspace

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // While the app runs, Run has nothing to do, so its place goes to the two ways of refreshing it.
            if workspace.canHotReload {
                Button(action: workspace.hotRestart) { Label("Hot Restart", systemImage: "arrow.clockwise") }
                    .help("Hot Restart: start the app over, keeping it running (⌥⇧⌘R)")
                Button(action: workspace.hotReload) { Label("Hot Reload", systemImage: "bolt.fill") }
                    .help("Hot Reload: apply code changes and keep the app's state (⇧⌘R)")
            } else {
                Button(action: workspace.runApp) { Label("Run", systemImage: "play.fill") }
                    .disabled(!workspace.canRun)
                    .help(workspace.runBlocker.map { "Run (⌘R): \($0)" } ?? "Run (⌘R)")
            }
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

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Canvas", selection: Bindable(workspace).canvas) {
                Label("Device", systemImage: "iphone").tag(Workspace.Canvas.device)
                    .help("Show the running app (⌘1)")
                Label("App Flow", systemImage: "point.3.connected.trianglepath.dotted").tag(Workspace.Canvas.flow)
                    .help("Show how the app's screens connect (⌘2)")
                Label("Design", systemImage: "paintpalette").tag(Workspace.Canvas.design)
                    .help("Show the app's screens as mockups (⌥⌘D)")
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the device, a map of the app's screens, or their mockups")
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

/// The simulator to run on, grouped by OS version, with Boot and Shut Down for the selected one.
struct DestinationMenu: View {
    let workspace: Workspace
    private var devices: DeviceModel { workspace.deviceModel }

    var body: some View {
        Menu {
            ForEach(osVersions, id: \.self) { osVersion in
                Section(osVersion) {
                    ForEach(devices.devices.filter { $0.osVersion == osVersion }) { device in
                        Toggle(isOn: Binding(get: { device.selection == devices.selected?.selection },
                                             set: { _ in devices.select(device) })) {
                            Text(device.isBooted ? "\(device.name) (Booted)" : device.name)
                        }
                    }
                }
            }
            if let device = devices.selected {
                Divider()
                if device.isBooted {
                    Button("Shut Down \(device.name)") { devices.shutdown() }.disabled(devices.isBusy)
                } else {
                    Button("Boot \(device.name)") { devices.boot() }.disabled(devices.isBusy || device.isTransitioning)
                }
            }
        } label: {
            Label(devices.selected?.name ?? "Choose Simulator", systemImage: "iphone")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(devices.devices.isEmpty)
        .help("Destination")
    }

    private var osVersions: [String] {
        var seen = Set<String>()
        return devices.devices.map(\.osVersion).filter { seen.insert($0).inserted }
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
