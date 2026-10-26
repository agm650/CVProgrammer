import Foundation

protocol RBusServicing: Sendable {
    func groupStream() async -> AsyncStream<[RBusGroupState]>
    func connectionStateStream() async -> AsyncStream<Z21ConnectionState>
    func start() async throws
    func refresh() async throws
    func startModuleAddressProgramming(address: UInt8) async throws
    func stopModuleAddressProgramming() async throws
    func stop() async
}

actor RBusService: RBusServicing {
    private let session: Z21Session
    private let now: @Sendable () -> Date

    private var groupStates: [RBusGroupState]
    private var groupContinuations: [
        UUID: AsyncStream<[RBusGroupState]>.Continuation
    ] = [:]
    private var connectionStateContinuations: [
        UUID: AsyncStream<Z21ConnectionState>.Continuation
    ] = [:]
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

    }

    func groupStream() -> AsyncStream<[RBusGroupState]> {
        let id = UUID()
        let pair = AsyncStream<[RBusGroupState]>.makeStream()
        groupContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeGroupContinuation(id: id) }
        }
        pair.continuation.yield(groupStates)
        return pair.stream
    }

    func connectionStateStream() -> AsyncStream<Z21ConnectionState> {
        let id = UUID()
        let pair = AsyncStream<Z21ConnectionState>.makeStream()
        connectionStateContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConnectionStateContinuation(id: id) }
        }
        pair.continuation.yield(lastConnectionState)
        return pair.stream
    }

    func start() async throws {
        guard messageTask == nil else { return }

        let messages = await session.messageStream()
        let connectionStates = await session.connectionStateStream()
        lastConnectionState = await session.currentConnectionState()
        yieldConnectionState(lastConnectionState)

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

    func startModuleAddressProgramming(address: UInt8) async throws {
        try await session.send(.rBusProgramModule(address: address))
    }

    func stopModuleAddressProgramming() async throws {
        try await session.send(.rBusProgramModule(address: 0))
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
        yieldGroups()
    }

    private func processConnectionState(
        _ newState: Z21ConnectionState
    ) async {
        guard newState != lastConnectionState else { return }

        lastConnectionState = newState
        yieldConnectionState(newState)
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
        yieldGroups()
    }

    private func yieldGroups() {
        for continuation in groupContinuations.values {
            continuation.yield(groupStates)
        }
    }

    private func yieldConnectionState(_ state: Z21ConnectionState) {
        for continuation in connectionStateContinuations.values {
            continuation.yield(state)
        }
    }

    private func removeGroupContinuation(id: UUID) {
        groupContinuations[id] = nil
    }

    private func removeConnectionStateContinuation(id: UUID) {
        connectionStateContinuations[id] = nil
    }
}
