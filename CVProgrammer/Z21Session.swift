import Foundation

enum Z21ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case synchronized
    case degraded
}

struct Z21BroadcastFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let general = Z21BroadcastFlags(rawValue: 0x0000_0001)
    static let rBus = Z21BroadcastFlags(rawValue: 0x0000_0002)
    static let railCom = Z21BroadcastFlags(rawValue: 0x0000_0004)
    static let systemState = Z21BroadcastFlags(rawValue: 0x0000_0100)
}

enum Z21SessionError: Error, Equatable, LocalizedError, Sendable {
    case notConnected
    case missingEndpoint

    var errorDescription: String? {
        switch self {
            case .notConnected:
                return "The Z21 session is not connected."
            case .missingEndpoint:
                return "The Z21 session has no endpoint to reconnect to."
        }
    }
}

actor Z21Session {
    typealias TransportFactory = @Sendable () -> any Z21Transport

    private var connectionStateContinuations:
        [UUID: AsyncStream<Z21ConnectionState>.Continuation] = [:]
    private var messageContinuations:
        [UUID: AsyncStream<Z21Message>.Continuation] = [:]
    private let transportFactory: TransportFactory
    private let codec: any Z21ProtocolCodec
    private let diagnosticLogger: any Z21DiagnosticLogging

    private var transport: (any Z21Transport)?
    private var listenerTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var endpoint: (host: String, port: UInt16)?
    private var connectionState: Z21ConnectionState = .disconnected
    private var broadcastFlags: Z21BroadcastFlags = []

    init(
        transportFactory: @escaping TransportFactory = {
            Z21UDPTransport()
        },
        codec: any Z21ProtocolCodec = DefaultZ21ProtocolCodec(),
        diagnosticLogger: any Z21DiagnosticLogging = Z21DiagnosticLogger()
    ) {
        self.transportFactory = transportFactory
        self.codec = codec
        self.diagnosticLogger = diagnosticLogger
    }

    func connect(host: String, port: UInt16) async throws {
        await stopCurrentTransport(publishDisconnected: false)
        endpoint = (host, port)

        let newTransport = transportFactory()
        let generation = UUID()
        connectionGeneration = generation
        transport = newTransport
        publishConnectionState(.connecting)

        listenerTask = Task { [weak self] in
            for await packet in newTransport.incomingPackets {
                guard !Task.isCancelled else { return }
                await self?.route(packet, generation: generation)
            }
            await self?.transportStreamEnded(generation: generation)
        }

        do {
            try await newTransport.connect(host: host, port: port)
            guard connectionGeneration == generation else {
                await newTransport.close()
                return
            }

            if !broadcastFlags.isEmpty {
                try await sendBroadcastFlags(using: newTransport)
            }
            publishConnectionState(.synchronized)
        } catch {
            guard connectionGeneration == generation else { throw error }

            publishConnectionState(.degraded)
            listenerTask?.cancel()
            listenerTask = nil
            await newTransport.close()
            transport = nil
            throw error
        }
    }

    func reconnect() async throws {
        guard let endpoint else {
            throw Z21SessionError.missingEndpoint
        }
        try await connect(host: endpoint.host, port: endpoint.port)
    }

    func disconnect() async {
        await stopCurrentTransport(publishDisconnected: true)
    }

    func send(_ command: Z21Command) async throws {
        guard connectionState == .synchronized, let transport else {
            throw Z21SessionError.notConnected
        }

        let packet = try codec.encode(command)
        await diagnosticLogger.record(
            level: .info,
            direction: .transmit,
            commandName: command.diagnosticName,
            summary: command.diagnosticSummary,
            rawBytes: packet
        )
        try await transport.send(packet)
    }

    @discardableResult
    func enableBroadcastFlags(
        _ flags: Z21BroadcastFlags
    ) async throws -> Z21BroadcastFlags {
        broadcastFlags.formUnion(flags)

        if connectionState == .synchronized, let transport {
            try await sendBroadcastFlags(using: transport)
        }

        return broadcastFlags
    }

    func activeBroadcastFlags() -> Z21BroadcastFlags {
        broadcastFlags
    }

    func connectionStateStream() -> AsyncStream<Z21ConnectionState> {
        let identifier = UUID()
        let stream = AsyncStream<Z21ConnectionState>.makeStream()
        connectionStateContinuations[identifier] = stream.continuation
        stream.continuation.yield(connectionState)
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeConnectionStateContinuation(identifier)
            }
        }
        return stream.stream
    }

    func messageStream() -> AsyncStream<Z21Message> {
        let identifier = UUID()
        let stream = AsyncStream<Z21Message>.makeStream()
        messageContinuations[identifier] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeMessageContinuation(identifier)
            }
        }
        return stream.stream
    }

    func currentConnectionState() -> Z21ConnectionState {
        connectionState
    }

    private func route(_ packet: Data, generation: UUID) async {
        guard connectionGeneration == generation else { return }

        do {
            let message = try codec.decode(packet)
            await diagnosticLogger.record(
                level: .info,
                direction: .receive,
                commandName: message.diagnosticName,
                summary: message.diagnosticSummary,
                rawBytes: packet
            )
            for continuation in messageContinuations.values {
                continuation.yield(message)
            }
        } catch {
            await diagnosticLogger.record(
                level: .error,
                direction: .receive,
                commandName: "MALFORMED_PACKET",
                summary: error.localizedDescription,
                rawBytes: packet
            )
        }
    }

    private func removeConnectionStateContinuation(_ identifier: UUID) {
        connectionStateContinuations.removeValue(forKey: identifier)
    }

    private func removeMessageContinuation(_ identifier: UUID) {
        messageContinuations.removeValue(forKey: identifier)
    }

    private func transportStreamEnded(generation: UUID) {
        guard connectionGeneration == generation else { return }
        guard connectionState != .disconnected else { return }

        transport = nil
        listenerTask = nil
        publishConnectionState(.degraded)
    }

    private func sendBroadcastFlags(
        using transport: any Z21Transport
    ) async throws {
        let command = Z21Command.setBroadcastFlags(broadcastFlags.rawValue)
        let packet = try codec.encode(command)
        await diagnosticLogger.record(
            level: .info,
            direction: .transmit,
            commandName: command.diagnosticName,
            summary: command.diagnosticSummary,
            rawBytes: packet
        )
        try await transport.send(packet)
    }

    private func stopCurrentTransport(
        publishDisconnected: Bool
    ) async {
        connectionGeneration = UUID()
        listenerTask?.cancel()
        listenerTask = nil

        if let transport {
            await transport.close()
        }
        transport = nil

        if publishDisconnected {
            publishConnectionState(.disconnected)
        }
    }

    private func publishConnectionState(_ newState: Z21ConnectionState) {
        guard connectionState != newState else { return }

        connectionState = newState
        for continuation in connectionStateContinuations.values {
            continuation.yield(newState)
        }
    }
}
