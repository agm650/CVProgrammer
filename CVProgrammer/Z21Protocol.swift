//
//  Z21Protocol.swift
//  CVProgrammer
//
//  Created by Luc Dandoy on 22/12/2025.
//
import Foundation

enum Z21Protocol {

    // MARK: - POM write byte (same as before, but keep it)

    /// LAN_X_CV_POM_WRITE_BYTE (no reply). :contentReference[oaicite:5]{index=5}
    static func makePOMWriteBytePacket(locoAddress: UInt16, cvAddress0Based: UInt8, value: UInt8) -> Data {
        let (adrMSB, adrLSB) = splitLocoAddressForXBus(locoAddress)

        let cvMSB = UInt8((cvAddress0Based >> 8) & 0xFF)
        let cvLSB = UInt8(cvAddress0Based & 0xFF)

        // DB3 = 111011MM => base 0xEC, MM carries CVAdr_MSB (low bits). :contentReference[oaicite:6]{index=6}
        let option = UInt8(0xEC | (cvMSB & 0x03))

        var payload: [UInt8] = [
            0x40, 0x00, // Header
            0xE6,       // X-Header
            0x30,       // DB0
            adrMSB,     // DB1
            adrLSB,     // DB2
            option,     // DB3
            cvLSB,      // DB4
            value       // DB5
        ]

        let xorByte = xorChecksum(bytes: Array(payload.dropFirst(2))) // XOR from X-Header..DB5
        payload.append(xorByte)

        return withDataLenPrefix(0x000C, payload: payload) // total len 12 :contentReference[oaicite:7]{index=7}
    }

    // MARK: - POM read byte (new)

    /// LAN_X_CV_POM_READ_BYTE (reply: CV_NACK or CV_RESULT). :contentReference[oaicite:8]{index=8}
    static func makePOMReadBytePacket(locoAddress: UInt16, cvAddress0Based: UInt8) -> Data {
        let (adrMSB, adrLSB) = splitLocoAddressForXBus(locoAddress)

        let cvMSB = UInt8((cvAddress0Based >> 8) & 0xFF)
        let cvLSB = UInt8(cvAddress0Based & 0xFF)

        // DB3 = 111001MM => base 0xE4, MM carries CVAdr_MSB (low bits). :contentReference[oaicite:9]{index=9}
        let option = UInt8(0xE4 | (cvMSB & 0x03))

        var payload: [UInt8] = [
            0x40, 0x00, // Header
            0xE6,       // X-Header
            0x30,       // DB0
            adrMSB,     // DB1
            adrLSB,     // DB2
            option,     // DB3
            cvLSB,      // DB4
            0x00        // DB5 must be 0 for read. :contentReference[oaicite:10]{index=10}
        ]

        let xorByte = xorChecksum(bytes: Array(payload.dropFirst(2))) // XOR from X-Header..DB5
        payload.append(xorByte)

        return withDataLenPrefix(0x000C, payload: payload) // total len 12 :contentReference[oaicite:11]{index=11}
    }

    // MARK: - Inbound parsing (CV_RESULT / CV_NACK)

    /// Parses Z21 inbound messages we care about:
    /// - LAN_X_CV_RESULT: Header 0x40 0x00, XHdr 0x64, DB0 0x14, DB1/2=CV, DB3=Value :contentReference[oaicite:12]{index=12}
    /// - LAN_X_CV_NACK:   Header 0x40 0x00, XHdr 0x61, DB0 0x13 :contentReference[oaicite:13]{index=13}
    static func parseInbound(_ data: Data) -> Z21Event {
        let b = [UInt8](data)
        guard b.count >= 6 else { return .unknown }

        // LAN_RMBUS_DATACHANGED: Header 0x80 0x00, group index, 10 status bytes.
        if b.count >= 15, b[2] == 0x80, b[3] == 0x00 {
            return .rBusSnapshot(groupIndex: b[4], statuses: Array(b[5..<15]))
        }

        // Basic check for X-BUS datasets: Z21 header 0x40 0x00.
        // Dataset = [lenLE0 lenLE1][hdr0 hdr1][...]
        guard b.count >= 4, b[2] == 0x40, b[3] == 0x00 else { return .unknown }

        // Need at least X-Header + DB0
        guard b.count >= 6 else { return .unknown }
        let xHeader = b[4]
        let db0 = b[5]

        // CV_NACK: XHdr 0x61, DB0 0x13 :contentReference[oaicite:14]{index=14}
        if xHeader == 0x61, db0 == 0x13 {
            return .cvNack
        }

        // CV_RESULT: XHdr 0x64, DB0 0x14, DB1=CV_MSB, DB2=CV_LSB, DB3=Value :contentReference[oaicite:15]{index=15}
        if xHeader == 0x64, db0 == 0x14, b.count >= 9 {
            let cvMSB = UInt16(b[6])
            let cvLSB = UInt16(b[7])
            let cv0 = (cvMSB << 8) | cvLSB
            let value = b[8]
            return .cvResult(cvAddress0Based: UInt8(cv0), value: value)
        }

        return .unknown
    }

    // MARK: - Helpers

    /// Spec uses loco address = (Adr_MSB & 0x3F) << 8 + Adr_LSB for these POM params. :contentReference[oaicite:16]{index=16}
    static func splitLocoAddressForXBus(_ address: UInt16) -> (UInt8, UInt8) {
        let msb = UInt8((address >> 8) & 0x3F) // keep low 6 bits
        let lsb = UInt8(address & 0xFF)
        return (msb, lsb)
    }

    static func xorChecksum(bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x00, ^)
    }

    static func withDataLenPrefix(_ dataLen: UInt16, payload: [UInt8]) -> Data {
        var out = Data()
        out.append(UInt8(dataLen & 0xFF))
        out.append(UInt8((dataLen >> 8) & 0xFF))
        out.append(contentsOf: payload)
        return out
    }
}
