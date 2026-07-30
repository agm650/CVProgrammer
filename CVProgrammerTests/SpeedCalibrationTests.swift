import XCTest
@testable import CVProgrammer

final class SpeedCalibrationTests: XCTestCase {
    func testGeneratorCreatesCV67ThroughCV94() {
        let points = SpeedCurveGenerator.generate(SpeedCalibrationConfiguration())
        XCTAssertEqual(points.count, 28)
        XCTAssertEqual(points.first?.cv, 67)
        XCTAssertEqual(points.last?.cv, 94)
        XCTAssertEqual(points.last?.dccStep, 126)
    }

    func testScaleSpeedCalculationForHO() {
        let speed = SpeedCurveGenerator.scaleSpeedKPH(distanceMM: 1000, elapsed: 4, scale: 87)
        XCTAssertEqual(speed, 78.3, accuracy: 0.001)
    }

    func test10819PhysicalInputsMapToTwoConsecutiveRBusModules() {
        XCTAssertEqual(
            Z21FeedbackAddress(detector10819BaseModule: 3, physicalInput: 1),
            Z21FeedbackAddress(module: 3, input: 1)
        )
        XCTAssertEqual(
            Z21FeedbackAddress(detector10819BaseModule: 3, physicalInput: 8),
            Z21FeedbackAddress(module: 3, input: 8)
        )
        XCTAssertEqual(
            Z21FeedbackAddress(detector10819BaseModule: 3, physicalInput: 9),
            Z21FeedbackAddress(module: 4, input: 1)
        )
        XCTAssertEqual(
            Z21FeedbackAddress(detector10819BaseModule: 3, physicalInput: 16),
            Z21FeedbackAddress(module: 4, input: 8)
        )
    }

    func testRBusSnapshotParsing() {
        let packet = Data([
            0x0F, 0x00, 0x80, 0x00, 0x00,
            0x05, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00
        ])
        XCTAssertEqual(
            Z21Protocol.parseInbound(packet),
            .rBusSnapshot(groupIndex: 0, statuses: [0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        )
    }

    func testMonotonicTimestampDuration() {
        let start = MonotonicTimestamp(uptimeNanoseconds: 1_000_000_000)
        let end = MonotonicTimestamp(uptimeNanoseconds: 2_250_000_000)
        XCTAssertEqual(start.duration(to: end), 1.25, accuracy: 0.000_001)
        XCTAssertLessThan(start, end)
    }

    func testMonotonicTimestampAdvanced() {
        let start = MonotonicTimestamp(uptimeNanoseconds: 500_000_000)
        XCTAssertEqual(start.advanced(by: 1.5).uptimeNanoseconds, 2_000_000_000)
    }

    func testRBusPackets() {
        XCTAssertEqual(
            Z21Protocol.makeSetBroadcastFlagsPacket(0x00000002),
            Data([0x08, 0x00, 0x50, 0x00, 0x02, 0x00, 0x00, 0x00])
        )
        XCTAssertEqual(
            Z21Protocol.makeRBusGetDataPacket(groupIndex: 1),
            Data([0x05, 0x00, 0x81, 0x00, 0x01])
        )
    }
}
