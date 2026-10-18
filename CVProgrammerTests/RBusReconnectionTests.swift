import Foundation
import Testing
@testable import CVProgrammer

struct RBusReconnectionTests {
    @Test
    func marksDataStaleAndResynchronizesAfterReconnect() async throws {
        let firstTransport = FakeZ21Transport()
        let secondTransport = FakeZ21Transport()
        let (session, service) = try await makeStartedService(
            transports: [firstTransport, secondTransport]
        )

        await firstTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x01))
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].state == .occupied
        })

        await session.disconnect()
        #expect(await eventually {
            let value = await service.currentGroups()[0].inputs[0]
            return value.state == .occupied
                && value.isStale
                && value.effectiveState == .unknown
        })

        try await session.reconnect()
        #expect(await eventually {
            await secondTransport.sentPackets().suffix(2) == [
                Data([0x05, 0x00, 0x81, 0x00, 0x00]),
                Data([0x05, 0x00, 0x81, 0x00, 0x01])
            ]
        })

        await secondTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x00))
        #expect(await eventually {
            let value = await service.currentGroups()[0].inputs[0]
            return value.state == .free && !value.isStale
        })
    }

    @Test
    func remainsStaleWhenReconnectReceivesNoRBusReply() async throws {
        let firstTransport = FakeZ21Transport()
        let secondTransport = FakeZ21Transport()
        let (session, service) = try await makeStartedService(
            transports: [firstTransport, secondTransport]
        )
        await firstTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x01))
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].state == .occupied
        })

        await session.disconnect()
        try await session.reconnect()

        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].isStale
        })
    }

    @Test
    func supportsMultipleReconnections() async throws {
        let firstTransport = FakeZ21Transport()
        let secondTransport = FakeZ21Transport()
        let thirdTransport = FakeZ21Transport()
        let (session, service) = try await makeStartedService(
            transports: [
                firstTransport,
                secondTransport,
                thirdTransport
            ]
        )
        await firstTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x01))
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].state == .occupied
        })

        await session.disconnect()
        try await session.reconnect()
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].isStale
        })

        await session.disconnect()
        try await session.reconnect()
        await thirdTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x00))

        #expect(await eventually {
            let value = await service.currentGroups()[0].inputs[0]
            return value.state == .free && !value.isStale
        })
    }

    @Test
    func disconnectsWhileReconnectIsInProgress() async throws {
        let firstTransport = FakeZ21Transport()
        let delayedTransport = FakeZ21Transport()
        await delayedTransport.delayNextConnection(by: 20_000_000)
        let (session, service) = try await makeStartedService(
            transports: [firstTransport, delayedTransport]
        )
        await firstTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x01))
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].state == .occupied
        })

        await session.disconnect()
        let reconnect = Task {
            try? await session.reconnect()
        }
        #expect(await eventually {
            await session.currentConnectionState() == .connecting
        })
        await session.disconnect()
        await reconnect.value

        #expect(await session.currentConnectionState() == .disconnected)
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].isStale
        })
    }

    @Test
    func ignoresLateEventsFromPreviousConnection() async throws {
        let firstTransport = FakeZ21Transport()
        await firstTransport.keepStreamOpenWhenClosed()
        let secondTransport = FakeZ21Transport()
        let (session, service) = try await makeStartedService(
            transports: [firstTransport, secondTransport]
        )
        await firstTransport.inject(rBusPacket(groupIndex: 0, firstStatus: 0x01))
        #expect(await eventually {
            await service.currentGroups()[0].inputs[0].state == .occupied
        })

        await session.disconnect()
        try await session.reconnect()
        await firstTransport.injectLatePacket(
            rBusPacket(groupIndex: 0, firstStatus: 0x00)
        )
        for _ in 0..<10 {
            await Task.yield()
        }

        let value = await service.currentGroups()[0].inputs[0]
        #expect(value.state == .occupied)
        #expect(value.isStale)
    }

    private func makeStartedService(
        transports: [FakeZ21Transport]
    ) async throws -> (Z21Session, RBusService) {
        let factory = FakeZ21TransportFactory(transports)
        let session = Z21Session {
            factory.makeTransport()
        }
        try await session.connect(
            host: "192.168.0.111",
            port: 21_105
        )
        let service = RBusService(session: session)
        try await service.start()
        return (session, service)
    }

    private func rBusPacket(
        groupIndex: UInt8,
        firstStatus: UInt8
    ) -> Data {
        var packet = Data([
            0x0F, 0x00, 0x80, 0x00,
            groupIndex,
            firstStatus
        ])
        packet.append(contentsOf: Array(repeating: 0, count: 9))
        return packet
    }

    private func eventually(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}
