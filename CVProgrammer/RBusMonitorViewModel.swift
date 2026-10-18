import Foundation

struct RBusMonitorInputModel: Identifiable, Equatable {
    let number: UInt8
    let state: FeedbackState
    let isStale: Bool

    var id: UInt8 { number }
}

struct RBusMonitorRowModel: Identifiable, Equatable {
    let address: UInt8
    let inputs: [RBusMonitorInputModel]
    let lastUpdate: Date?
    let isStale: Bool

    var id: UInt8 { address }
}

@MainActor
final class RBusMonitorViewModel: ObservableObject {
    @Published private(set) var rows: [RBusMonitorRowModel] = []
    @Published private(set) var connectionState: Z21ConnectionState = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let service: any RBusServicing
    private var groupsTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    init(service: any RBusServicing) {
        self.service = service
    }

    func start() async {
        guard groupsTask == nil else { return }

        groupsTask = Task { [weak self, groups = service.groups] in
            for await groups in groups {
                guard !Task.isCancelled else { return }
                self?.apply(groups)
            }
        }
        connectionTask = Task { [weak self, states = service.connectionStates] in
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.connectionState = state
            }
        }

        do {
            try await service.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await service.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        groupsTask?.cancel()
        groupsTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        Task { await service.stop() }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func apply(_ groups: [RBusGroupState]) {
        rows = groups
            .sorted { $0.address < $1.address }
            .map { group in
                let inputs = group.inputs.enumerated().map { index, value in
                    RBusMonitorInputModel(
                        number: UInt8(index + 1),
                        state: value.effectiveState,
                        isStale: value.isStale
                    )
                }
                return RBusMonitorRowModel(
                    address: group.address,
                    inputs: inputs,
                    lastUpdate: group.lastUpdate,
                    isStale: inputs.contains { $0.isStale }
                )
            }
    }
}
