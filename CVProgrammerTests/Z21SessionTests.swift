import Foundation
import Testing
@testable import CVProgrammer

final class FakeZ21TransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeZ21Transport]

    init(_ transports: [FakeZ21Transport]) {
        self.transports = transports
    }

    func makeTransport() -> any Z21Transport {
        lock.lock()
        defer { lock.unlock() }

        precondition(!transports.isEmpty, "No fake Z21 transport remains.")
        return transports.removeFirst()
    }
}

struct Z21SessionTests {
    @Test
    func publishesConnectingThenSynchronized() async throws {
        let transport = FakeZ21Transport()
        let session = makeSession(transports: [transport])
        let states = collectStates(from: session.connectionStates, count: 3)

        try await session.connect(host: "192.168.0.111", port: 21_105)

        #expect(
            await states.value == [
                .disconnected,
                .connecting,
                .synchronized
            ]
        )
        #expect(await session.currentConnectionState() == .synchronized)
    }

    @Test
    func publishesDegradedAfterConnectionFailure() async {
        let transport = FakeZ21Transport()
        await transport.failNextConnection(
            with: .connectionFailed("Test failure")
        )
        let session = makeSession(transports: [transport])
        let states = collectStates(from: session.connectionStates, count: 3)

        do {
            try await session.connect(host: "invalid", port: 21_105)
            Issue.record("Expected connection failure.")
        } catch {
            // The typed transport failure is expected.
        }

        #expect(
            await states.value == [
                .disconnected,
                .connecting,
                .degraded
            ]
        )
        #expect(await session.currentConnectionState() == .degraded)
    }

    @Test
    func combinesBroadcastFlags() async throws {
        let transport = FakeZ21Transport()
        let session = makeSession(transports: [transport])
        try await session.connect(host: "192.168.0.111", port: 21_105)

        _ = try await session.enableBroadcastFlags(.general)
        let combined = try await session.enableBroadcastFlags(.rBus)

        #expect(combined == [.general, .rBus])
        #expect(await session.activeBroadcastFlags() == [.general, .rBus])
        #expect(
            await transport.sentPackets().last
                == Data([0x08, 0x00, 0x50, 0x00, 0x03, 0x00, 0x00, 0x00])
        )
    }

    @Test
    func preservesBroadcastFlagsAcrossReconnect() async throws {
        let firstTransport = FakeZ21Transport()
        let secondTransport = FakeZ21Transport()
        let session = makeSession(
            transports: [firstTransport, secondTransport]
        )

        _ = try await session.enableBroadcastFlags([.general, .rBus])
        try await session.connect(host: "192.168.0.111", port: 21_105)
        try await session.reconnect()

        let expectedPacket = Data([
            0x08, 0x00, 0x50, 0x00,
            0x03, 0x00, 0x00, 0x00
        ])
        #expect(await firstTransport.sentPackets() == [expectedPacket])
        #expect(await secondTransport.sentPackets() == [expectedPacket])
    }

    @Test
    func routesDecodedMessage() async throws {
        let transport = FakeZ21Transport()
        let session = makeSession(transports: [transport])
        let messages = await session.messageStream()
        let receivedMessage = Task<Z21Message?, Never> {
            for await message in messages {
                return message
            }
            return nil
        }
        try await session.connect(host: "192.168.0.111", port: 21_105)

        await transport.inject(
            Data([
                0x0A, 0x00, 0x40, 0x00,
                0x64, 0x14, 0x00, 0x1C,
                0x22, 0x4E
            ])
        )

        #expect(
            await receivedMessage.value
                == .cvResult(cvAddress: 28, value: 34)
        )
    }

    @Test
    func closesSession() async throws {
        let transport = FakeZ21Transport()
        let session = makeSession(transports: [transport])
        try await session.connect(host: "192.168.0.111", port: 21_105)

        await session.disconnect()

        #expect(await transport.isClosed())
        #expect(await session.currentConnectionState() == .disconnected)
    }

    @Test
    func reconnectsUsingStoredEndpoint() async throws {
        let firstTransport = FakeZ21Transport()
        let secondTransport = FakeZ21Transport()
        let session = makeSession(
            transports: [firstTransport, secondTransport]
        )
        try await session.connect(host: "192.168.0.111", port: 21_105)

        try await session.reconnect()

        let endpoints = await secondTransport.connectedEndpoints()
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.host == "192.168.0.111")
        #expect(endpoints.first?.port == 21_105)
        #expect(await session.currentConnectionState() == .synchronized)
    }

    private func makeSession(
        transports: [FakeZ21Transport]
    ) -> Z21Session {
        let factory = FakeZ21TransportFactory(transports)
        return Z21Session {
            factory.makeTransport()
        }
    }

    private func collectStates(
        from stream: AsyncStream<Z21ConnectionState>,
        count: Int
    ) -> Task<[Z21ConnectionState], Never> {
        Task {
            var states: [Z21ConnectionState] = []
            for await state in stream {
                states.append(state)
                if states.count == count {
                    break
                }
            }
            return states
        }
    }
}
