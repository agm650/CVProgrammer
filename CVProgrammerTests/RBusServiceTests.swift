import Foundation
import Testing
@testable import CVProgrammer

struct RBusServiceTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func startsWithTwentyUnknownGroups() async throws {
        let (service, _) = try await makeService()
        let groups = await service.currentGroups()

        #expect(groups.count == 20)
        #expect(groups.flatMap(\.inputs).count == 160)
        #expect(
            groups.flatMap(\.inputs).allSatisfy {
                $0.state == .unknown && !$0.isStale
            }
        )
        #expect(groups.allSatisfy { $0.lastUpdate == nil })
    }

    @Test
    func startEnablesRBusAndRequestsInitialState() async throws {
        let (service, transport) = try await makeService()
        try await service.start()

        #expect(
            await transport.sentPackets() == [
                Data([0x08, 0x00, 0x50, 0x00, 0x02, 0x00, 0x00, 0x00]),
                Data([0x05, 0x00, 0x81, 0x00, 0x00]),
                Data([0x05, 0x00, 0x81, 0x00, 0x01])
            ]
        )
    }

    @Test
    func updatesGroupZeroAndLeavesGroupOneUnknown() async throws {
        let (service, transport) = try await makeService()
        let update = nextUpdate(afterInitialValueFrom: service.groups)
        try await service.start()

        await transport.inject(
            rBusPacket(
                groupIndex: 0,
                statuses: [0x01] + Array(repeating: 0, count: 9)
            )
        )
        let groups = await update.value

        #expect(groups?[0].inputs[0].state == .occupied)
        #expect(groups?[0].inputs[1].state == .free)
        #expect(groups?[9].inputs.allSatisfy { $0.state != .unknown } == true)
        #expect(groups?[10].inputs.allSatisfy { $0.state == .unknown } == true)
        #expect(groups?[0].lastUpdate == fixedDate)
        #expect(groups?[9].lastUpdate == fixedDate)
        #expect(groups?[10].lastUpdate == nil)
    }

    @Test
    func updatesGroupOneIndependently() async throws {
        let (service, transport) = try await makeService()
        let update = nextUpdate(afterInitialValueFrom: service.groups)
        try await service.start()

        await transport.inject(
            rBusPacket(
                groupIndex: 1,
                statuses: Array(repeating: 0, count: 9) + [0x80]
            )
        )
        let groups = await update.value

        #expect(groups?[0].inputs.allSatisfy { $0.state == .unknown } == true)
        #expect(groups?[10].inputs.allSatisfy { $0.state == .free } == true)
        #expect(groups?[19].inputs[7].state == .occupied)
        #expect(groups?[9].lastUpdate == nil)
        #expect(groups?[10].lastUpdate == fixedDate)
        #expect(groups?[19].lastUpdate == fixedDate)
    }

    @Test
    func appliesSuccessiveChangesInOrder() async throws {
        let (service, transport) = try await makeService()
        let updates = collectUpdates(from: service.groups, count: 3)
        try await service.start()

        await transport.inject(
            rBusPacket(
                groupIndex: 0,
                statuses: [0x01] + Array(repeating: 0, count: 9)
            )
        )
        await transport.inject(
            rBusPacket(
                groupIndex: 0,
                statuses: [0x80] + Array(repeating: 0, count: 9)
            )
        )
        let receivedUpdates = await updates.value

        #expect(receivedUpdates.count == 3)
        #expect(receivedUpdates[1][0].inputs[0].state == .occupied)
        #expect(receivedUpdates[1][0].inputs[7].state == .free)
        #expect(receivedUpdates[2][0].inputs[0].state == .free)
        #expect(receivedUpdates[2][0].inputs[7].state == .occupied)
    }

    private func makeService() async throws -> (
        service: RBusService,
        transport: FakeZ21Transport
    ) {
        let transport = FakeZ21Transport()
        let factory = FakeZ21TransportFactory([transport])
        let session = Z21Session {
            factory.makeTransport()
        }
        let service = RBusService(
            session: session,
            now: { fixedDate }
        )

        try await session.connect(
            host: "192.168.0.111",
            port: 21_105
        )
        return (service, transport)
    }

    private func rBusPacket(
        groupIndex: UInt8,
        statuses: [UInt8]
    ) -> Data {
        var packet = Data([0x0F, 0x00, 0x80, 0x00, groupIndex])
        packet.append(contentsOf: statuses)
        return packet
    }

    private func nextUpdate(
        afterInitialValueFrom stream: AsyncStream<[RBusGroupState]>
    ) -> Task<[RBusGroupState]?, Never> {
        Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next()
        }
    }

    private func collectUpdates(
        from stream: AsyncStream<[RBusGroupState]>,
        count: Int
    ) -> Task<[[RBusGroupState]], Never> {
        Task {
            var updates: [[RBusGroupState]] = []
            for await groups in stream {
                updates.append(groups)
                if updates.count == count {
                    break
                }
            }
            return updates
        }
    }
}
