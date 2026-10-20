import Foundation

enum Z21Command: Equatable, Sendable {
    case pomReadByte(locomotiveAddress: UInt16, cvAddress: UInt16)
    case pomWriteByte(locomotiveAddress: UInt16, cvAddress: UInt16, value: UInt8)
    case pomAccessoryWriteByte(accessoryAddress: UInt16, cvAddress: UInt16, value: UInt8)
    case setBroadcastFlags(UInt32)
    case rBusGetData(groupIndex: UInt8)
    case rBusProgramModule(address: UInt8)
}

enum Z21Message: Equatable, Sendable {
    case cvResult(cvAddress: UInt16, value: UInt8)
    case cvNack
    case rBusDataChanged(groupIndex: UInt8, groups: [RBusGroupSnapshot])
    case unknown(header: UInt16, payload: Data)
}

enum Z21ProtocolCodecError: Error, Equatable, LocalizedError, Sendable {
    case packetTooShort(minimum: Int, actual: Int)
    case dataLengthMismatch(expected: Int, actual: Int)
    case unsupportedHeader(UInt16)
    case invalidPayloadLength(expected: Int, actual: Int)
    case invalidChecksum
    case invalidLocomotiveAddress(UInt16)
    case invalidAccessoryAddress(UInt16)
    case invalidCVAddress(UInt16)
    case invalidRBusGroupIndex(UInt8)
    case invalidRBusModuleAddress(UInt8)

    var errorDescription: String? {
        switch self {
            case .packetTooShort(let minimum, let actual):
                return "Z21 packet is too short: expected at least \(minimum) bytes, got \(actual)."
            case .dataLengthMismatch(let expected, let actual):
                return "Z21 DataLen is \(expected), but the packet contains \(actual) bytes."
            case .unsupportedHeader(let header):
                return String(format: "Unsupported Z21 header: 0x%04X.", header)
            case .invalidPayloadLength(let expected, let actual):
                return "Invalid Z21 payload length: expected \(expected) bytes, got \(actual)."
            case .invalidChecksum:
                return "Invalid Z21 X-BUS checksum."
            case .invalidLocomotiveAddress(let address):
                return "Invalid locomotive address: \(address)."
            case .invalidAccessoryAddress(let address):
                return "Invalid zero-based accessory decoder address: \(address)."
            case .invalidCVAddress(let address):
                return "Invalid zero-based CV address: \(address)."
            case .invalidRBusGroupIndex(let groupIndex):
                return "Invalid R-BUS group index: \(groupIndex)."
            case .invalidRBusModuleAddress(let address):
                return "Invalid R-BUS module address: \(address). Use an address from 0 through 20."
        }
    }
}

protocol Z21ProtocolCodec: Sendable {
    func encode(_ command: Z21Command) throws -> Data
    func decode(_ packet: Data) throws -> Z21Message
}

struct DefaultZ21ProtocolCodec: Z21ProtocolCodec {
    private static let xBusHeader: UInt16 = 0x0040
    private static let maximumLocomotiveAddress: UInt16 = 9_999
    private static let maximumCVAddress: UInt16 = 1_023

    func encode(_ command: Z21Command) throws -> Data {
        switch command {
            case .pomReadByte(let locomotiveAddress, let cvAddress):
                return try encodePOM(
                    locomotiveAddress: locomotiveAddress,
                    cvAddress: cvAddress,
                    optionBase: 0xE4,
                    value: 0x00
                )
            case .pomWriteByte(let locomotiveAddress, let cvAddress, let value):
                return try encodePOM(
                    locomotiveAddress: locomotiveAddress,
                    cvAddress: cvAddress,
                    optionBase: 0xEC,
                    value: value
                )
            case .pomAccessoryWriteByte(
                let accessoryAddress,
                let cvAddress,
                let value
            ):
                return try encodeAccessoryPOM(
                    accessoryAddress: accessoryAddress,
                    cvAddress: cvAddress,
                    value: value
                )
            case .setBroadcastFlags(let flags):
                return Data([
                    0x08, 0x00, 0x50, 0x00,
                    UInt8(flags & 0xFF),
                    UInt8((flags >> 8) & 0xFF),
                    UInt8((flags >> 16) & 0xFF),
                    UInt8((flags >> 24) & 0xFF)
                ])
            case .rBusGetData(let groupIndex):
                guard groupIndex <= 1 else {
                    throw Z21ProtocolCodecError.invalidRBusGroupIndex(groupIndex)
                }
                return Data([0x05, 0x00, 0x81, 0x00, groupIndex])
            case .rBusProgramModule(let address):
                guard address <= 20 else {
                    throw Z21ProtocolCodecError.invalidRBusModuleAddress(address)
                }
                return Data([0x05, 0x00, 0x82, 0x00, address])
        }
    }

    func decode(_ packet: Data) throws -> Z21Message {
        let bytes = [UInt8](packet)
        guard bytes.count >= 4 else {
            throw Z21ProtocolCodecError.packetTooShort(
                minimum: 4,
                actual: bytes.count
            )
        }

        let dataLength = Int(bytes[0]) | (Int(bytes[1]) << 8)
        guard dataLength == bytes.count else {
            throw Z21ProtocolCodecError.dataLengthMismatch(
                expected: dataLength,
                actual: bytes.count
            )
        }

        let header = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        switch header {
            case Self.xBusHeader:
                return try decodeXBus(bytes)
            case 0x0080:
                return try decodeRBusDataChanged(bytes)
            default:
                throw Z21ProtocolCodecError.unsupportedHeader(header)
        }
    }

    private func decodeXBus(_ bytes: [UInt8]) throws -> Z21Message {
        guard bytes.count >= 7 else {
            throw Z21ProtocolCodecError.packetTooShort(
                minimum: 7,
                actual: bytes.count
            )
        }

        let xBusBytes = bytes[4...]
        guard xBusBytes.reduce(0, ^) == 0 else {
            throw Z21ProtocolCodecError.invalidChecksum
        }

        let xHeader = bytes[4]
        let db0 = bytes[5]

        if xHeader == 0x61, db0 == 0x13 {
            guard bytes.count == 7 else {
                throw Z21ProtocolCodecError.invalidPayloadLength(
                    expected: 3,
                    actual: bytes.count - 4
                )
            }
            return .cvNack
        }

        if xHeader == 0x64, db0 == 0x14 {
            guard bytes.count == 10 else {
                throw Z21ProtocolCodecError.invalidPayloadLength(
                    expected: 6,
                    actual: bytes.count - 4
                )
            }

            let cvAddress = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
            guard cvAddress <= Self.maximumCVAddress else {
                throw Z21ProtocolCodecError.invalidCVAddress(cvAddress)
            }
            return .cvResult(cvAddress: cvAddress, value: bytes[8])
        }

        return .unknown(
            header: Self.xBusHeader,
            payload: Data(bytes.dropFirst(4).dropLast())
        )
    }

    private func decodeRBusDataChanged(
        _ bytes: [UInt8]
    ) throws -> Z21Message {
        let expectedPayloadLength = 11
        guard bytes.count == 4 + expectedPayloadLength else {
            throw Z21ProtocolCodecError.invalidPayloadLength(
                expected: expectedPayloadLength,
                actual: bytes.count - 4
            )
        }

        let groupIndex = bytes[4]
        guard groupIndex <= 1 else {
            throw Z21ProtocolCodecError.invalidRBusGroupIndex(groupIndex)
        }

        let firstAddress = groupIndex * 10 + 1
        let groups = (0..<10).map { offset in
            RBusGroupSnapshot(
                address: firstAddress + UInt8(offset),
                statusByte: bytes[5 + offset]
            )
        }
        return .rBusDataChanged(
            groupIndex: groupIndex,
            groups: groups
        )
    }

    private func encodePOM(
        locomotiveAddress: UInt16,
        cvAddress: UInt16,
        optionBase: UInt8,
        value: UInt8
    ) throws -> Data {
        guard (1...Self.maximumLocomotiveAddress).contains(locomotiveAddress) else {
            throw Z21ProtocolCodecError.invalidLocomotiveAddress(locomotiveAddress)
        }
        guard cvAddress <= Self.maximumCVAddress else {
            throw Z21ProtocolCodecError.invalidCVAddress(cvAddress)
        }

        let addressMSB = UInt8((locomotiveAddress >> 8) & 0x3F)
        let addressLSB = UInt8(locomotiveAddress & 0xFF)
        let cvMSB = UInt8((cvAddress >> 8) & 0x03)
        let cvLSB = UInt8(cvAddress & 0xFF)
        let option = optionBase | cvMSB

        var xBusPayload: [UInt8] = [
            0xE6,
            0x30,
            addressMSB,
            addressLSB,
            option,
            cvLSB,
            value
        ]
        xBusPayload.append(xBusPayload.reduce(0, ^))

        let dataLength = UInt16(4 + xBusPayload.count)
        var packet = Data([
            UInt8(dataLength & 0xFF),
            UInt8((dataLength >> 8) & 0xFF),
            UInt8(Self.xBusHeader & 0xFF),
            UInt8((Self.xBusHeader >> 8) & 0xFF)
        ])
        packet.append(contentsOf: xBusPayload)
        return packet
    }

    private func encodeAccessoryPOM(
        accessoryAddress: UInt16,
        cvAddress: UInt16,
        value: UInt8
    ) throws -> Data {
        guard accessoryAddress <= 0x01FF else {
            throw Z21ProtocolCodecError.invalidAccessoryAddress(
                accessoryAddress
            )
        }
        guard cvAddress <= Self.maximumCVAddress else {
            throw Z21ProtocolCodecError.invalidCVAddress(cvAddress)
        }

        let addressAndOutput = (accessoryAddress & 0x01FF) << 4
        let cvMSB = UInt8((cvAddress >> 8) & 0x03)
        var xBusPayload: [UInt8] = [
            0xE6,
            0x31,
            UInt8((addressAndOutput >> 8) & 0xFF),
            UInt8(addressAndOutput & 0xFF),
            0xEC | cvMSB,
            UInt8(cvAddress & 0xFF),
            value
        ]
        xBusPayload.append(xBusPayload.reduce(0, ^))

        return Data([
            0x0C, 0x00,
            UInt8(Self.xBusHeader & 0xFF),
            UInt8((Self.xBusHeader >> 8) & 0xFF)
        ] + xBusPayload)
    }
}
