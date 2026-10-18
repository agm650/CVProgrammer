import Foundation

protocol RBusServicing: Sendable {
    var groups: AsyncStream<[RBusGroupState]> { get }

    func start() async throws
    func refresh() async throws
    func stop() async
}

actor RBusService: RBusServicing {
    nonisolated let groups: AsyncStream<[RBusGroupState]>

    private let groupsContinuation:
        AsyncStream<[RBusGroupState]>.Continuation
    private let session: Z21Session
    private let now: @Sendable () -> Date

    private var groupStates: [RBusGroupState]
    private var messageTask: Task<Void, Never>?
    private var connectionStateTask: Task<Void, Never>?
    private var lastConnectionState: Z21ConnectionState = .disconnected

    init(
        session: Z21Session,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
        groupStates = (1...20).map {
            RBusGroupState(address: UInt8($0))
        }

        let stream = AsyncStream<[RBusGroupState]>.makeStream()
        groups = stream.stream
        groupsContinuation = stream.continuation
        groupsContinuation.yield(groupStates)
    }

    func start() async throws {
        guard messageTask == nil else { return }

        let messages = await session.messageStream()
        let connectionStates = await session.connectionStateStream()
        lastConnectionState = await session.currentConnectionState()

        messageTask = Task { [weak self] in
            for await message in messages {
                guard !Task.isCancelled else { return }
                await self?.process(message)
            }
        }
        connectionStateTask = Task { [weak self] in
            for await state in connectionStates {
                guard !Task.isCancelled else { return }
                await self?.processConnectionState(state)
            }
        }

        do {
            _ = try await session.enableBroadcastFlags(.rBus)
            if lastConnectionState == .synchronized {
                try await refresh()
            }
        } catch {
            messageTask?.cancel()
            messageTask = nil
            connectionStateTask?.cancel()
            connectionStateTask = nil
            throw error
        }
    }

    func refresh() async throws {
        try await session.send(.rBusGetData(groupIndex: 0))
        try await session.send(.rBusGetData(groupIndex: 1))
    }

    func stop() {
        messageTask?.cancel()
        messageTask = nil
        connectionStateTask?.cancel()
        connectionStateTask = nil
    }

    func currentGroups() -> [RBusGroupState] {
        groupStates
    }

    private func process(_ message: Z21Message) {
        guard case .rBusDataChanged(_, let snapshots) = message else {
            return
        }

        let updateDate = now()
        for snapshot in snapshots {
            let stateIndex = Int(snapshot.address) - 1
            guard groupStates.indices.contains(stateIndex) else { continue }

            groupStates[stateIndex].inputs = snapshot.inputs.map {
                FeedbackValue(state: $0.state, isStale: false)
            }
            groupStates[stateIndex].lastUpdate = updateDate
        }
        groupsContinuation.yield(groupStates)
    }

    private func processConnectionState(
        _ newState: Z21ConnectionState
    ) async {
        guard newState != lastConnectionState else { return }

        lastConnectionState = newState
        switch newState {
            case .disconnected, .connecting, .degraded:
                markAllInputsStale()
            case .synchronized:
                try? await refresh()
        }
    }

    private func markAllInputsStale() {
        for groupIndex in groupStates.indices {
            for inputIndex in groupStates[groupIndex].inputs.indices {
                groupStates[groupIndex].inputs[inputIndex].isStale = true
            }
        }
        groupsContinuation.yield(groupStates)
    }
}
