import Foundation
import Observation

@MainActor
@Observable
final class DartSDKModel {
    private(set) var state: DartState = .checking

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        state = .checking
        state = await DartSDKService().detect()
    }

    @ObservationIgnored private var isRefreshing = false
}
