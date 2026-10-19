import Foundation
import Testing
@testable import CVProgrammer

struct Z21DiagnosticLoggerTests {
    @Test
    func addsEntry() async {
        let logger = Z21DiagnosticLogger(now: { Date(timeIntervalSince1970: 1) })
        await logger.record(
            level: .info,
            direction: .transmit,
            commandName: "COMMAND",
            summary: "value=1",
            rawBytes: nil
        )

        let entries = await logger.entries()
        #expect(entries.count == 1)
        #expect(entries[0].commandName == "COMMAND")
    }

    @Test
    func preservesTemporalOrder() async {
        let clock = DiagnosticTestClock()
        let logger = Z21DiagnosticLogger(now: { clock.next() })

        await logger.record(
            level: .info,
            direction: .transmit,
            commandName: "FIRST",
            summary: "",
            rawBytes: nil
        )
        await logger.record(
            level: .info,
            direction: .receive,
            commandName: "SECOND",
            summary: "",
            rawBytes: nil
        )

        let entries = await logger.entries()
        #expect(entries.map(\.commandName) == ["FIRST", "SECOND"])
        #expect(entries[0].timestamp < entries[1].timestamp)
    }

    @Test
    func boundsRingBuffer() async {
        let logger = Z21DiagnosticLogger(capacity: 2)
        for index in 1...3 {
            await logger.record(
                level: .info,
                direction: .transmit,
                commandName: "COMMAND_\(index)",
                summary: "",
                rawBytes: nil
            )
        }

        #expect(
            await logger.entries().map(\.commandName)
                == ["COMMAND_2", "COMMAND_3"]
        )
    }

    @Test
    func filtersEntriesBelowConfiguredLevel() async {
        let logger = Z21DiagnosticLogger(minimumLevel: .error)
        await logger.record(
            level: .info,
            direction: .transmit,
            commandName: "IGNORED",
            summary: "",
            rawBytes: nil
        )
        await logger.record(
            level: .error,
            direction: .receive,
            commandName: "KEPT",
            summary: "",
            rawBytes: nil
        )

        #expect(await logger.entries().map(\.commandName) == ["KEPT"])
    }

    @Test
    func omitsRawBytesWhenHexDumpIsDisabled() async {
        let logger = Z21DiagnosticLogger(includesRawBytes: false)
        await logger.record(
            level: .info,
            direction: .receive,
            commandName: "COMMAND",
            summary: "",
            rawBytes: Data([0x01, 0xAB])
        )

        #expect(await logger.entries().first?.rawBytes == nil)
    }

    @Test
    func formatsEntriesDeterministically() {
        let entry = Z21DiagnosticEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: .info,
            direction: .transmit,
            commandName: "LAN_RMBUS_GETDATA",
            summary: "group=0",
            rawBytes: Data([0x05, 0xAB])
        )

        #expect(
            entry.formatted()
                == "2023-11-14T22:13:20.000Z TX LAN_RMBUS_GETDATA group=0 bytes=05 AB"
        )
    }

    @Test
    func sessionUsesReplaceableLoggerForRBusAndProgramming() async throws {
        let transport = FakeZ21Transport()
        let recorder = RecordingDiagnosticLogger()
        let session = Z21Session(
            transportFactory: { transport },
            diagnosticLogger: recorder
        )
        try await session.connect(host: "127.0.0.1", port: 21_105)

        try await session.send(.rBusGetData(groupIndex: 0))
        try await session.send(
            .pomWriteByte(
                locomotiveAddress: 3,
                cvAddress: 99,
                value: 2
            )
        )

        #expect(
            await recorder.commandNames == [
                "LAN_RMBUS_GETDATA",
                "LAN_X_CV_POM_WRITE_BYTE"
            ]
        )
    }
}

private final class DiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var interval: TimeInterval = 0

    func next() -> Date {
        lock.withLock {
            defer { interval += 1 }
            return Date(timeIntervalSince1970: interval)
        }
    }
}

private actor RecordingDiagnosticLogger: Z21DiagnosticLogging {
    private(set) var commandNames: [String] = []

    func record(
        level: Z21DiagnosticLevel,
        direction: Z21DiagnosticDirection,
        commandName: String,
        summary: String,
        rawBytes: Data?
    ) {
        commandNames.append(commandName)
    }
}
