import Foundation
import Dispatch

struct Z21FeedbackAddress: Hashable, Codable, Sendable {
    let module: Int
    let input: Int

    init(module: Int, input: Int) {
        self.module = module
        self.input = input
    }

    /// Maps one physical input of a 10819 (1...16) to its two consecutive
    /// R-BUS module addresses (8 inputs per address).
    init(detector10819BaseModule: Int, physicalInput: Int) {
        let zeroBased = max(0, min(15, physicalInput - 1))
        self.module = detector10819BaseModule + zeroBased / 8
        self.input = zeroBased % 8 + 1
    }
}

/// Monotonic timestamp backed by `DispatchTime`, available on macOS 12.
/// It must only be used for elapsed-time measurements, never as a wall-clock date.
struct MonotonicTimestamp: Equatable, Comparable, Sendable {
    let uptimeNanoseconds: UInt64

    static func now() -> MonotonicTimestamp {
        MonotonicTimestamp(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    static func < (lhs: MonotonicTimestamp, rhs: MonotonicTimestamp) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    func advanced(by seconds: TimeInterval) -> MonotonicTimestamp {
        guard seconds > 0 else { return self }
        let requested = seconds * 1_000_000_000.0
        let increment = requested >= Double(UInt64.max) ? UInt64.max : UInt64(requested.rounded())
        let (value, overflow) = uptimeNanoseconds.addingReportingOverflow(increment)
        return MonotonicTimestamp(uptimeNanoseconds: overflow ? UInt64.max : value)
    }

    func duration(to end: MonotonicTimestamp) -> TimeInterval {
        guard end.uptimeNanoseconds >= uptimeNanoseconds else { return 0 }
        return Double(end.uptimeNanoseconds - uptimeNanoseconds) / 1_000_000_000.0
    }
}

struct Z21FeedbackEvent: Equatable, Sendable {
    let address: Z21FeedbackAddress
    let occupied: Bool
    let timestamp: MonotonicTimestamp
}

struct Z21FeedbackSample: Equatable, Sendable {
    let occupied: Bool
    let timestamp: MonotonicTimestamp
}

extension Z21Protocol {
    static func makeSetBroadcastFlagsPacket(_ flags: UInt32) -> Data {
        Data([
            0x08, 0x00, 0x50, 0x00,
            UInt8(flags & 0xff),
            UInt8((flags >> 8) & 0xff),
            UInt8((flags >> 16) & 0xff),
            UInt8((flags >> 24) & 0xff)
        ])
    }

    static func makeRBusGetDataPacket(groupIndex: UInt8) -> Data {
        Data([0x05, 0x00, 0x81, 0x00, groupIndex])
    }

    static func makeLocoDrive128Packet(address: UInt16, step: UInt8, forward: Bool) -> Data {
        let msbBase = UInt8((address >> 8) & 0x3f)
        let msb = address >= 128 ? (0xc0 | msbBase) : msbBase
        let lsb = UInt8(address & 0xff)
        let encodedStep: UInt8 = step == 0 ? 0 : min(127, step &+ 1)
        let speed = (forward ? 0x80 : 0x00) | encodedStep
        let x: [UInt8] = [0xe4, 0x13, msb, lsb, speed]
        let xor = x.reduce(0, ^)
        return Data([0x0a, 0x00, 0x40, 0x00] + x + [xor])
    }

    static func makeEmergencyStopPacket() -> Data {
        Data([0x06, 0x00, 0x40, 0x00, 0x80, 0x80])
    }
}

extension Z21Client {
    func setLocomotiveSpeed(address: UInt16, step: UInt8, forward: Bool) {
        sendCalibrationPacket(
            Z21Protocol.makeLocoDrive128Packet(address: address, step: step, forward: forward),
            note: "LOCO \(address) step \(step)"
        )
    }

    func calibrationEmergencyStop() {
        sendCalibrationPacket(Z21Protocol.makeEmergencyStopPacket(), note: "EMERGENCY STOP")
    }

    func subscribeToRBusFeedback() {
        // R-BUS changes only. Broadcast subscriptions are per UDP client and
        // must be renewed after each connection.
        sendCalibrationPacket(Z21Protocol.makeSetBroadcastFlagsPacket(0x00000002), note: "SUBSCRIBE R-BUS")
        requestAllRBusFeedback()
    }

    func requestAllRBusFeedback() {
        sendCalibrationPacket(Z21Protocol.makeRBusGetDataPacket(groupIndex: 0), note: "GET R-BUS 1...10")
        sendCalibrationPacket(Z21Protocol.makeRBusGetDataPacket(groupIndex: 1), note: "GET R-BUS 11...20")
    }
}
