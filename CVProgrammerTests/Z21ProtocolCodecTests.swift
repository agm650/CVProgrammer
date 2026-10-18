import Foundation
import Testing
@testable import CVProgrammer

struct Z21ProtocolCodecTests {
    private let codec = DefaultZ21ProtocolCodec()

    @Test
    func encodesLocomotivePOMReadVector() throws {
        // Z21 LAN Protocol 1.13, section 6.8:
        // locomotive 3, zero-based CV address 0 (CV1).
        let packet = try codec.encode(
            .pomReadByte(locomotiveAddress: 3, cvAddress: 0)
        )

        #expect(
            packet == Data([
                0x0C, 0x00, 0x40, 0x00,
                0xE6, 0x30, 0x00, 0x03,
                0xE4, 0x00, 0x00, 0x31
            ])
        )
    }

    @Test
    func encodesLocomotivePOMWriteVector() throws {
        // Z21 LAN Protocol 1.13, section 6.6:
        // locomotive 3, zero-based CV address 28 (CV29), value 34.
        let packet = try codec.encode(
            .pomWriteByte(
                locomotiveAddress: 3,
                cvAddress: 28,
                value: 34
            )
        )

        #expect(
            packet == Data([
                0x0C, 0x00, 0x40, 0x00,
                0xE6, 0x30, 0x00, 0x03,
                0xEC, 0x1C, 0x22, 0x07
            ])
        )
    }

    @Test
    func decodesValidCVResultVector() throws {
        // Z21 LAN Protocol 1.13, section 6.5:
        // zero-based CV address 28 (CV29), value 34.
        let packet = Data([
            0x0A, 0x00, 0x40, 0x00,
            0x64, 0x14, 0x00, 0x1C,
            0x22, 0x4E
        ])

        let message = try codec.decode(packet)

        #expect(message == .cvResult(cvAddress: 28, value: 34))
    }

    @Test
    func decodesValidCVNackVector() throws {
        let packet = Data([
            0x07, 0x00, 0x40, 0x00,
            0x61, 0x13, 0x72
        ])

        #expect(try codec.decode(packet) == .cvNack)
    }

    @Test
    func rejectsPacketShorterThanDatasetHeader() {
        expectCodecError(.packetTooShort(minimum: 4, actual: 3)) {
            try codec.decode(Data([0x03, 0x00, 0x40]))
        }
    }

    @Test
    func rejectsInconsistentDataLength() {
        expectCodecError(.dataLengthMismatch(expected: 10, actual: 7)) {
            try codec.decode(
                Data([0x0A, 0x00, 0x40, 0x00, 0x61, 0x13, 0x72])
            )
        }
    }

    @Test
    func rejectsUnsupportedHeader() {
        expectCodecError(.unsupportedHeader(0x0010)) {
            try codec.decode(Data([0x04, 0x00, 0x10, 0x00]))
        }
    }

    @Test
    func rejectsTruncatedCVResultPayload() {
        expectCodecError(.invalidPayloadLength(expected: 6, actual: 5)) {
            try codec.decode(
                Data([
                    0x09, 0x00, 0x40, 0x00,
                    0x64, 0x14, 0x00, 0x1C,
                    0x6C
                ])
            )
        }
    }

    @Test
    func rejectsInvalidXBusChecksum() {
        expectCodecError(.invalidChecksum) {
            try codec.decode(
                Data([
                    0x07, 0x00, 0x40, 0x00,
                    0x61, 0x13, 0x00
                ])
            )
        }
    }

    @Test
    func acceptsEncodingBoundaryValues() throws {
        let minimumPacket = try codec.encode(
            .pomWriteByte(
                locomotiveAddress: 1,
                cvAddress: 0,
                value: .min
            )
        )
        let maximumPacket = try codec.encode(
            .pomWriteByte(
                locomotiveAddress: 9_999,
                cvAddress: 1_023,
                value: .max
            )
        )

        #expect(minimumPacket.count == 12)
        #expect(maximumPacket.count == 12)
    }

    @Test
    func rejectsInvalidEncodingValues() {
        expectCodecError(.invalidLocomotiveAddress(0)) {
            try codec.encode(
                .pomReadByte(locomotiveAddress: 0, cvAddress: 0)
            )
        }
        expectCodecError(.invalidLocomotiveAddress(10_000)) {
            try codec.encode(
                .pomReadByte(locomotiveAddress: 10_000, cvAddress: 0)
            )
        }
        expectCodecError(.invalidCVAddress(1_024)) {
            try codec.encode(
                .pomReadByte(locomotiveAddress: 3, cvAddress: 1_024)
            )
        }
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
