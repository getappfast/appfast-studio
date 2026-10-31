import Foundation
import Observation

/// "Reference UI": tap an element in the running app and attach it to the chat.
@MainActor
@Observable
final class PickModel {
    enum Phase: Equatable {
        case idle
        case connecting
        /// Select mode is on in the app; the next tap picks.
        case picking
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var picks: [PickedWidget] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    var isPicking: Bool { phase == .connecting || phase == .picking }

    /// Starts picking, or stops it when already picking.
    func toggle(run: FlutterRunModel, folder: String?) {
        if isPicking { cancel(); return }
        guard run.phase == .running, let url = run.vmServiceURL, let folder else { return }
        start(serviceURL: url, folder: folder) { await run.bringAppToFront() }
    }

    func start(serviceURL: URL, folder: String, prepare: @escaping @MainActor () async -> Void = {}) {
        guard !isPicking else { return }
        phase = .connecting
        task = Task {
            // A backgrounded app is suspended and cannot answer, so bring it forward first.
            await prepare()
            let client = InspectorClient(serviceURL: serviceURL)
            do {
                try await client.connect()
                try await client.beginPicking()
                if !Task.isCancelled { phase = .picking }
                // The app reports a tap as a changed selection, so look for one until the user taps or cancels.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(350))
                    if Task.isCancelled { break }
                    if let widget = try await client.pickedWidget(projectFolder: folder) {
                        add(widget)
                        break
                    }
                }
                await client.endPicking()
                await client.close()
                phase = .idle
            } catch {
                await client.endPicking()
                await client.close()
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        if phase != .idle { phase = .idle }
    }

    func add(_ widget: PickedWidget) {
        if !picks.contains(where: { $0.place == widget.place }) { picks.append(widget) }
    }

    func setThumbnail(_ data: Data?, for id: UUID) {
        if let index = picks.firstIndex(where: { $0.id == id }) { picks[index].thumbnail = data }
    }

    func remove(_ pick: PickedWidget) { picks.removeAll { $0.id == pick.id } }

    func clear() { picks = [] }

    /// Swaps a pick for one of its parents, e.g. the whole button instead of the icon in it.
    func useParent(of pick: PickedWidget, at index: Int) {
        guard let position = picks.firstIndex(where: { $0.id == pick.id }), pick.ancestors.indices.contains(index) else { return }
        var updated = pick
        let parent = pick.ancestors[index]
        updated.place = parent
        updated.details = []
        updated.size = nil
        updated.ancestors = Array(pick.ancestors.dropFirst(index + 1))
        picks[position] = updated
    }
}
