import SwiftUI

/// Run, Stop and Hot reload, floating under the simulator.
struct RunBar: View {
    let project: ProjectModel
    let simulator: SimulatorModel
    let run: FlutterRunModel
    let fix: FixModel
    let pick: PickModel

    var body: some View {
        if case .ready(let flutter) = project.state {
            VStack(spacing: 8) {
                bar(flutter)
                if let caption = caption(flutter) {
                    Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func bar(_ flutter: FlutterProject) -> some View {
        HStack(spacing: 12) {
            if run.phase.isActive {
                Button { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(fix.phase == .validating)
                if run.phase == .running {
                    Button { run.hotReload() } label: { Label("Hot reload", systemImage: "bolt.fill") }
                    Button { pick.toggle(run: run, folder: flutter.path) } label: {
                        Label(pick.isPicking ? "Cancel pick" : "Pick", systemImage: "scope")
                    }
                    .tint(pick.isPicking ? .accentColor : nil)
                    .disabled(run.vmServiceURL == nil && !pick.isPicking)
                    .help("Tap an element in the app to reference it in the chat")
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Running").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(fix.phase == .validating ? "Checking the fix…" : (run.isAttaching ? "Connecting to the app…" : "Building…"))
                        .foregroundStyle(.secondary)
                }
            } else if run.existing != nil {
                Button { run.reconnect(folder: flutter.path, deviceName: simulator.selected?.name ?? "the simulator") } label: {
                    Label("Reconnect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .help("Attach to the running app, so Hot reload and Pick work again")
                Button { run.stopExisting() } label: { Label("Stop it", systemImage: "stop.fill") }
                    .help("Close the running app")
            } else {
                Button { start(flutter) } label: {
                    Label(simulator.selected.map { "Run on \($0.name)" } ?? "Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocker(flutter) != nil || fix.isBusy)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func start(_ flutter: FlutterProject) {
        guard let device = simulator.selected, device.isBooted else { return }
        run.start(folder: flutter.path, deviceID: device.udid, deviceName: device.name)
    }

    private func caption(_ flutter: FlutterProject) -> String? {
        if let error = run.reconnectError, !run.phase.isActive { return error }
        if run.existing != nil, !run.phase.isActive {
            return "\(flutter.name) is already running here from an earlier run. Reconnect to keep using Hot reload and Pick."
        }
        return blocker(flutter)
    }

    /// Why Run is unavailable, nil when it can start.
    private func blocker(_ flutter: FlutterProject) -> String? {
        if run.phase.isActive { return nil }
        if !flutter.platforms.contains("ios") { return "This project has no ios folder, so it can't run in the iOS Simulator." }
        guard let device = simulator.selected else { return "Choose a simulator above." }
        if !device.isBooted { return "Boot \(device.name) first." }
        guard case .done(let verdict) = project.verification, verdict.isFlutterProject else {
            return "Waiting for Claude's check of the project."
        }
        if !verdict.flavors.isEmpty { return "This project has flavors. Running a flavor isn't supported yet." }
        return nil
    }
}
