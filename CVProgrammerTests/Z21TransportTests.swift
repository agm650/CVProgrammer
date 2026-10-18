import Foundation
import Testing
@testable import CVProgrammer

actor FakeZ21Transport: Z21Transport {
    nonisolated let incomingPackets: AsyncStream<Data>

    private let packetContinuation: AsyncStream<Data>.Continuation
    private var capturedPackets: [Data] = []
    private var connectionAttempts: [(host: String, port: UInt16)] = []
    private var nextConnectError: Z21TransportError?
    private var nextSendError: Z21TransportError?
    private var closed = false

    init() {
        let stream = AsyncStream<Data>.makeStream()
        incomingPackets = stream.stream
        packetContinuation = stream.continuation
    }

    func connect(host: String, port: UInt16) async throws {
        connectionAttempts.append((host, port))
        if let nextConnectError {
            self.nextConnectError = nil
            throw nextConnectError
        }
        closed = false
    }

    func send(_ data: Data) async throws {
        guard !closed else {
            throw Z21TransportError.notConnected
        }
        if let nextSendError {
            self.nextSendError = nil
            throw nextSendError
        }
        capturedPackets.append(data)
    }

    func close() {
        guard !closed else { return }

        closed = true
        packetContinuation.finish()
    }

    func inject(_ data: Data) {
        guard !closed else { return }
        packetContinuation.yield(data)
    }

    func failNextConnection(with error: Z21TransportError) {
        nextConnectError = error
    }

    func failNextSend(with error: Z21TransportError) {
        nextSendError = error
    }

    func sentPackets() -> [Data] {
        capturedPackets
    }

    func connectedEndpoints() -> [(host: String, port: UInt16)] {
        connectionAttempts
    }

    func isClosed() -> Bool {
        closed
    }
}

struct Z21TransportTests {
    @Test
    func capturesSentPacket() async throws {
        let transport = FakeZ21Transport()
        let packet = Data([0x04, 0x00, 0x10, 0x00])

        try await transport.send(packet)

        #expect(await transport.sentPackets() == [packet])
    }

    @Test
    func receivesInjectedPacket() async {
        let transport = FakeZ21Transport()
        let packet = Data([0x08, 0x00, 0x40, 0x00])
        let receivedPacket = Task<Data?, Never> {
            for await incomingPacket in transport.incomingPackets {
                return incomingPacket
            }
            return nil
        }

        await transport.inject(packet)

        #expect(await receivedPacket.value == packet)
    }

    @Test
    func closesCleanly() async {
        let transport = FakeZ21Transport()

        await transport.close()

        #expect(await transport.isClosed())
    }

    @Test
    func closingTwiceIsSafe() async {
        let transport = FakeZ21Transport()

        await transport.close()
        await transport.close()

        #expect(await transport.isClosed())
    }

    @Test
    func propagatesSendError() async {
        let transport = FakeZ21Transport()
        await transport.failNextSend(with: .sendFailed("Test failure"))

        do {
            try await transport.send(Data([0x01]))
            Issue.record("Expected the send operation to fail.")
        } catch let error as Z21TransportError {
            #expect(error == .sendFailed("Test failure"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func listenerCanBeCancelled() async {
        let transport = FakeZ21Transport()
        let listener = Task {
            for await _ in transport.incomingPackets {
                // Keep listening until cancellation.
            }
        }

        listener.cancel()
        await listener.value

        #expect(listener.isCancelled)
    }

    @Test
    func simulatesTimeout() async {
        let transport = FakeZ21Transport()
        await transport.failNextSend(with: .timedOut)

        do {
            try await transport.send(Data([0x01]))
            Issue.record("Expected the send operation to time out.")
        } catch let error as Z21TransportError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
