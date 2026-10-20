#if DEBUG
import Foundation

final class RBusMonitorUITestService: RBusServicing, @unchecked Sendable {
    let groups: AsyncStream<[RBusGroupState]>
    let connectionStates: AsyncStream<Z21ConnectionState>

    private let groupsContinuation: AsyncStream<[RBusGroupState]>.Continuation
    private let connectionContinuation: AsyncStream<Z21ConnectionState>.Continuation
    private var updateTask: Task<Void, Never>?

    init() {
        let groupsStream = AsyncStream<[RBusGroupState]>.makeStream()
        groups = groupsStream.stream
        groupsContinuation = groupsStream.continuation

        let stateStream = AsyncStream<Z21ConnectionState>.makeStream()
        connectionStates = stateStream.stream
        connectionContinuation = stateStream.continuation
    }

    func start() async throws {
        connectionContinuation.yield(.disconnected)
        groupsContinuation.yield(Self.makeGroups(firstState: .occupied))
        updateTask = Task { [groupsContinuation] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            groupsContinuation.yield(Self.makeGroups(firstState: .free))
        }
    }

    func refresh() async throws {}

    func startModuleAddressProgramming(address: UInt8) async throws {}

    func stopModuleAddressProgramming() async throws {}

    func stop() async {
        updateTask?.cancel()
        updateTask = nil
    }

    private static func makeGroups(firstState: FeedbackState) -> [RBusGroupState] {
        var groups = (1...20).map { RBusGroupState(address: UInt8($0)) }
        groups[0].inputs[0] = FeedbackValue(state: firstState, isStale: false)
        groups[0].inputs[1] = FeedbackValue(state: .free, isStale: false)
        groups[0].inputs[2] = FeedbackValue(state: .unknown, isStale: false)
        groups[0].lastUpdate = Date()
        return groups
    }
}
#endif
