import Foundation
import Testing
@testable import CVProgrammer

@MainActor
struct RBusMonitorViewModelTests {
    @Test
    func transformsGroupsAndOrdersRowsByAddress() async {
        let service = FakeRBusMonitorService()
        let model = RBusMonitorViewModel(service: service)
        await model.start()

        var addressTwo = RBusGroupState(address: 2)
        addressTwo.inputs[0] = FeedbackValue(state: .occupied, isStale: false)
        var addressOne = RBusGroupState(address: 1)
        addressOne.inputs[0] = FeedbackValue(state: .free, isStale: false)
        service.send(groups: [addressTwo, addressOne])
        await waitUntil { model.rows.count == 2 }

        #expect(model.rows.map(\.address) == [1, 2])
        #expect(model.rows[0].inputs.map(\.number) == Array(1...8))
        #expect(model.rows[0].inputs[0].state == .free)
        #expect(model.rows[1].inputs[0].state == .occupied)
    }

    @Test
    func staleFeedbackIsPresentedAsUnknown() async {
        let service = FakeRBusMonitorService()
        let model = RBusMonitorViewModel(service: service)
        await model.start()

        var group = RBusGroupState(address: 1)
        group.inputs[0] = FeedbackValue(state: .occupied, isStale: true)
        service.send(groups: [group])
        await waitUntil { model.rows.first?.isStale == true }

        #expect(model.rows[0].inputs[0].state == .unknown)
        #expect(model.rows[0].inputs[0].isStale)
    }

    @Test
    func reflectsConnectionChanges() async {
        let service = FakeRBusMonitorService()
        let model = RBusMonitorViewModel(service: service)
        await model.start()

        service.send(connectionState: .synchronized)
        await waitUntil { model.connectionState == .synchronized }
        #expect(model.connectionState == .synchronized)

        service.send(connectionState: .disconnected)
        await waitUntil { model.connectionState == .disconnected }
        #expect(model.connectionState == .disconnected)
    }

    @Test
    func refreshUsesServiceAndKeepsFailureNonBlocking() async {
        let service = FakeRBusMonitorService()
        let model = RBusMonitorViewModel(service: service)
        await model.start()

        await model.refresh()
        #expect(service.refreshCount == 1)
        #expect(model.errorMessage == nil)

        service.refreshError = TestError.refreshFailed
        await model.refresh()
        #expect(service.refreshCount == 2)
        #expect(model.errorMessage != nil)
        #expect(!model.isRefreshing)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }
}

private enum TestError: Error {
    case refreshFailed
}

private final class FakeRBusMonitorService: RBusServicing, @unchecked Sendable {
    let groups: AsyncStream<[RBusGroupState]>
    let connectionStates: AsyncStream<Z21ConnectionState>

    private let groupsContinuation: AsyncStream<[RBusGroupState]>.Continuation
    private let connectionContinuation: AsyncStream<Z21ConnectionState>.Continuation
    private let lock = NSLock()
    private var storedRefreshCount = 0
    var refreshError: Error?

    var refreshCount: Int {
        lock.withLock { storedRefreshCount }
    }

    init() {
        let groupsStream = AsyncStream<[RBusGroupState]>.makeStream()
        groups = groupsStream.stream
        groupsContinuation = groupsStream.continuation

        let stateStream = AsyncStream<Z21ConnectionState>.makeStream()
        connectionStates = stateStream.stream
        connectionContinuation = stateStream.continuation
    }

    func start() async throws {}

    func refresh() async throws {
        let error = lock.withLock { () -> Error? in
            storedRefreshCount += 1
            return refreshError
        }
        if let error { throw error }
    }

    func stop() async {}

    func send(groups: [RBusGroupState]) {
        groupsContinuation.yield(groups)
    }

    func send(connectionState: Z21ConnectionState) {
        connectionContinuation.yield(connectionState)
    }
}
