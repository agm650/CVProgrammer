import Foundation
import Testing
@testable import CVProgrammer

struct Z21AccessoryPOMTests {
    private let codec = DefaultZ21ProtocolCodec()

    @Test
    func encodesMinimumAddressCVAndValue() throws {
        let address = try AccessoryAddress(1)

        let packet = try codec.encode(
            .pomAccessoryWriteByte(
                accessoryAddress: address.zeroBasedValue,
                cvAddress: 0,
                value: 0
            )
        )

        #expect(
            packet == Data([
                0x0C, 0x00, 0x40, 0x00,
                0xE6, 0x31, 0x00, 0x00,
                0xEC, 0x00, 0x00, 0x3B
            ])
        )
    }

    @Test
    func encodesMaximumAddressCVAndValue() throws {
        let address = try AccessoryAddress(512)

        let packet = try codec.encode(
            .pomAccessoryWriteByte(
                accessoryAddress: address.zeroBasedValue,
                cvAddress: 1_023,
                value: 255
            )
        )

        #expect(
            packet == Data([
                0x0C, 0x00, 0x40, 0x00,
                0xE6, 0x31, 0x1F, 0xF0,
                0xEF, 0xFF, 0xFF, 0xD7
            ])
        )
    }

    @Test(arguments: [UInt16(0), UInt16(513)])
    func rejectsInvalidDisplayedAccessoryAddress(_ value: UInt16) {
        #expect(
            throws: ProgrammingAddressError.invalidAccessoryAddress(value)
        ) {
            try AccessoryAddress(value)
        }
    }

    @Test
    func rejectsRawAccessoryAddressOutsideNineBits() {
        #expect(
            throws: Z21ProtocolCodecError.invalidAccessoryAddress(512)
        ) {
            try codec.encode(
                .pomAccessoryWriteByte(
                    accessoryAddress: 512,
                    cvAddress: 0,
                    value: 0
                )
            )
        }
    }

    @Test
    func rejectsCVAboveMaximum() {
        #expect(
            throws: Z21ProtocolCodecError.invalidCVAddress(1_024)
        ) {
            try codec.encode(
                .pomAccessoryWriteByte(
                    accessoryAddress: 0,
                    cvAddress: 1_024,
                    value: 0
                )
            )
        }
    }

    @Test
    func accessoryAndLocomotivePOMUseDifferentPackets() throws {
        let accessoryPacket = try codec.encode(
            .pomAccessoryWriteByte(
                accessoryAddress: 2,
                cvAddress: 99,
                value: 2
            )
        )
        let locomotivePacket = try codec.encode(
            .pomWriteByte(
                locomotiveAddress: 3,
                cvAddress: 99,
                value: 2
            )
        )

        #expect(accessoryPacket != locomotivePacket)
        #expect(accessoryPacket[5] == 0x31)
        #expect(locomotivePacket[5] == 0x30)
    }
}
