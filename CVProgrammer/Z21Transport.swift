import Foundation
import Network

enum Z21TransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidPort(UInt16)
    case alreadyConnected
    case notConnected
    case connectionFailed(String)
    case sendFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
            case .invalidPort(let port):
                return "Invalid UDP port: \(port)"
            case .alreadyConnected:
                return "The Z21 transport is already connected."
            case .notConnected:
                return "The Z21 transport is not connected."
            case .connectionFailed(let message):
                return "The Z21 connection failed: \(message)"
            case .sendFailed(let message):
                return "Sending a Z21 packet failed: \(message)"
            case .timedOut:
                return "The Z21 transport operation timed out."
        }
    }
}

protocol Z21Transport: Sendable {
    var incomingPackets: AsyncStream<Data> { get }

    func connect(host: String, port: UInt16) async throws
    func send(_ data: Data) async throws
    func close() async
}

actor Z21UDPTransport: Z21Transport {
    nonisolated let incomingPackets: AsyncStream<Data>

    private let packetContinuation: AsyncStream<Data>.Continuation
    private var connection: NWConnection?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var isClosed = false

    init() {
        let stream = AsyncStream<Data>.makeStream()
        incomingPackets = stream.stream
        packetContinuation = stream.continuation
    }

    func connect(host: String, port: UInt16) async throws {
        guard connection == nil else {
            throw Z21TransportError.alreadyConnected
        }
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw Z21TransportError.invalidPort(port)
        }

        isClosed = false
        let newConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: networkPort,
            using: .udp
        )
        connection = newConnection

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectionContinuation = continuation
                newConnection.stateUpdateHandler = { [weak self] state in
                    Task {
                        await self?.handleState(state, for: newConnection)
                    }
                }
                newConnection.start(queue: .global())
                receiveNext(on: newConnection)
            }
        } onCancel: {
            newConnection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        guard let connection, !isClosed else {
            throw Z21TransportError.notConnected
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: Z21TransportError.sendFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        guard !isClosed else { return }

        isClosed = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connectionContinuation?.resume(throwing: Z21TransportError.notConnected)
        connectionContinuation = nil
        packetContinuation.finish()
    }

    private func handleState(
        _ state: NWConnection.State,
        for observedConnection: NWConnection
    ) {
        guard connection === observedConnection else { return }

        switch state {
            case .ready:
                connectionContinuation?.resume()
                connectionContinuation = nil
            case .failed(let error):
                connectionContinuation?.resume(
                    throwing: Z21TransportError.connectionFailed(error.localizedDescription)
                )
                connectionContinuation = nil
                finishConnection(observedConnection)
            case .cancelled:
                connectionContinuation?.resume(throwing: Z21TransportError.notConnected)
                connectionContinuation = nil
                finishConnection(observedConnection)
            default:
                break
        }
    }

    private func receiveNext(on observedConnection: NWConnection) {
        observedConnection.receiveMessage { [weak self] content, _, _, error in
            Task {
                await self?.handleReceived(
                    content,
                    error: error,
                    from: observedConnection
                )
            }
        }
    }

    private func handleReceived(
        _ content: Data?,
        error: NWError?,
        from observedConnection: NWConnection
    ) {
        guard connection === observedConnection, !isClosed else { return }

        if let content, !content.isEmpty {
            packetContinuation.yield(content)
        }

        if error == nil {
            receiveNext(on: observedConnection)
        } else {
            finishConnection(observedConnection)
        }
    }

    private func finishConnection(_ observedConnection: NWConnection) {
        guard connection === observedConnection else { return }

        observedConnection.stateUpdateHandler = nil
        observedConnection.cancel()
        connection = nil
        isClosed = true
        packetContinuation.finish()
    }
}
