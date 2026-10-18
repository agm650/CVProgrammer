import Foundation
import Testing
@testable import CVProgrammer

struct Z21RBusProtocolTests {
    private let codec = DefaultZ21ProtocolCodec()

    @Test
    func encodesRBusGroupRequests() throws {
        #expect(
            try codec.encode(.rBusGetData(groupIndex: 0))
                == Data([0x05, 0x00, 0x81, 0x00, 0x00])
        )
        #expect(
            try codec.encode(.rBusGetData(groupIndex: 1))
                == Data([0x05, 0x00, 0x81, 0x00, 0x01])
        )
    }

    @Test
    func mapsGroupZeroToAddressesOneThroughTen() throws {
        let message = try codec.decode(
            rBusPacket(groupIndex: 0, statuses: [0x81] + Array(repeating: 0, count: 9))
        )
        let groups = try groups(from: message)

        #expect(groups.map(\.address) == (1...10).map(UInt8.init))
        #expect(groups[0].inputs[0] == input(address: 1, number: 1, state: .occupied))
        #expect(groups[0].inputs[7] == input(address: 1, number: 8, state: .occupied))
        #expect(groups[1].inputs[0] == input(address: 2, number: 1, state: .free))
    }

    @Test
    func mapsGroupOneToAddressesElevenThroughTwenty() throws {
        let statuses: [UInt8] = [
            0x01, 0x00, 0xC5, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x80
        ]
        let message = try codec.decode(
            rBusPacket(groupIndex: 1, statuses: statuses)
        )
        let groups = try groups(from: message)

        #expect(groups.map(\.address) == (11...20).map(UInt8.init))
        #expect(groups[0].inputs[0] == input(address: 11, number: 1, state: .occupied))
        #expect(groups[2].inputs[0] == input(address: 13, number: 1, state: .occupied))
        #expect(groups[2].inputs[1] == input(address: 13, number: 2, state: .free))
        #expect(groups[2].inputs[2] == input(address: 13, number: 3, state: .occupied))
        #expect(groups[2].inputs[6] == input(address: 13, number: 7, state: .occupied))
        #expect(groups[2].inputs[7] == input(address: 13, number: 8, state: .occupied))
        #expect(groups[9].inputs[7] == input(address: 20, number: 8, state: .occupied))
    }

    @Test
    func mapsZeroStatusByteToFreeInputs() {
        let group = RBusGroupSnapshot(address: 4, statusByte: 0x00)

        #expect(group.inputs.count == 8)
        #expect(
            group.inputs == (1...8).map {
                input(address: 4, number: UInt8($0), state: .free)
            }
        )
    }

    @Test
    func mapsFullStatusByteToOccupiedInputs() {
        let group = RBusGroupSnapshot(address: 7, statusByte: 0xFF)

        #expect(group.inputs.count == 8)
        #expect(
            group.inputs == (1...8).map {
                input(address: 7, number: UInt8($0), state: .occupied)
            }
        )
    }

    @Test
    func rejectsInvalidRBusGroupIndex() {
        expectCodecError(.invalidRBusGroupIndex(2)) {
            try codec.encode(.rBusGetData(groupIndex: 2))
        }
        expectCodecError(.invalidRBusGroupIndex(2)) {
            try codec.decode(
                rBusPacket(
                    groupIndex: 2,
                    statuses: Array(repeating: 0, count: 10)
                )
            )
        }
    }

    @Test
    func rejectsIncompleteRBusPayload() {
        let packet = Data([
            0x0E, 0x00, 0x80, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])

        expectCodecError(
            .invalidPayloadLength(expected: 11, actual: 10)
        ) {
            try codec.decode(packet)
        }
    }

    @Test
    func rejectsTruncatedRBusPacket() {
        let packet = Data([
            0x0F, 0x00, 0x80, 0x00, 0x00,
            0x00, 0x00, 0x00
        ])

        expectCodecError(
            .dataLengthMismatch(expected: 15, actual: 8)
        ) {
            try codec.decode(packet)
        }
    }

    private func rBusPacket(
        groupIndex: UInt8,
        statuses: [UInt8]
    ) -> Data {
        var packet = Data([0x0F, 0x00, 0x80, 0x00, groupIndex])
        packet.append(contentsOf: statuses)
        return packet
    }

    private func groups(
        from message: Z21Message
    ) throws -> [RBusGroupSnapshot] {
        guard case .rBusDataChanged(_, let groups) = message else {
            Issue.record("Expected an R-BUS data changed message.")
            return []
        }
        return groups
    }

    private func input(
        address: UInt8,
        number: UInt8,
        state: FeedbackState
    ) -> RBusFeedbackInput {
        RBusFeedbackInput(
            rBusAddress: address,
            input: number,
            state: state
        )
    }

    private func expectCodecError<Result>(
        _ expectedError: Z21ProtocolCodecError,
        operation: () throws -> Result
    ) {
        do {
            _ = try operation()
            Issue.record("Expected codec error: \(expectedError)")
        } catch let error as Z21ProtocolCodecError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
