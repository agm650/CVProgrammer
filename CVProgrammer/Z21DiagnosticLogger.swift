import Foundation

enum Z21DiagnosticLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case error = 2
    case off = 3

    static func < (
        lhs: Z21DiagnosticLevel,
        rhs: Z21DiagnosticLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum Z21DiagnosticDirection: String, Sendable {
    case transmit = "TX"
    case receive = "RX"
}

struct Z21DiagnosticEntry: Equatable, Sendable {
    let timestamp: Date
    let level: Z21DiagnosticLevel
    let direction: Z21DiagnosticDirection
    let commandName: String
    let summary: String
    let rawBytes: Data?

    func formatted() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        var components = [
            formatter.string(from: timestamp),
            direction.rawValue,
            commandName
        ]
        if !summary.isEmpty {
            components.append(summary)
        }
        if let rawBytes {
            let hex = rawBytes.map {
                String(format: "%02X", $0)
            }.joined(separator: " ")
            components.append("bytes=\(hex)")
        }
        return components.joined(separator: " ")
    }
}

protocol Z21DiagnosticLogging: Sendable {
    func record(
        level: Z21DiagnosticLevel,
        direction: Z21DiagnosticDirection,
        commandName: String,
        summary: String,
        rawBytes: Data?
    ) async
}

actor Z21DiagnosticLogger: Z21DiagnosticLogging {
    private let capacity: Int
    private let minimumLevel: Z21DiagnosticLevel
    private let includesRawBytes: Bool
    private let now: @Sendable () -> Date
    private var buffer: [Z21DiagnosticEntry] = []

    init(
        capacity: Int = 200,
        minimumLevel: Z21DiagnosticLevel = .info,
        includesRawBytes: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capacity = max(0, capacity)
        self.minimumLevel = minimumLevel
        self.includesRawBytes = includesRawBytes
        self.now = now
    }

    func record(
        level: Z21DiagnosticLevel,
        direction: Z21DiagnosticDirection,
        commandName: String,
        summary: String,
        rawBytes: Data?
    ) {
        guard capacity > 0,
              minimumLevel != .off,
              level >= minimumLevel else {
            return
        }

        buffer.append(
            Z21DiagnosticEntry(
                timestamp: now(),
                level: level,
                direction: direction,
                commandName: commandName,
                summary: summary,
                rawBytes: includesRawBytes ? rawBytes : nil
            )
        )
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    func entries() -> [Z21DiagnosticEntry] {
        buffer
    }

    func removeAll() {
        buffer.removeAll(keepingCapacity: true)
    }
}

extension Z21Command {
    var diagnosticName: String {
        switch self {
            case .pomReadByte: return "LAN_X_CV_POM_READ_BYTE"
            case .pomWriteByte: return "LAN_X_CV_POM_WRITE_BYTE"
            case .pomAccessoryWriteByte:
                return "LAN_X_CV_POM_ACCESSORY_WRITE_BYTE"
            case .setBroadcastFlags: return "LAN_SET_BROADCASTFLAGS"
            case .rBusGetData: return "LAN_RMBUS_GETDATA"
        }
    }

    var diagnosticSummary: String {
        switch self {
            case .pomReadByte(let address, let cv):
                return "address=\(address) cv=\(cv + 1)"
            case .pomWriteByte(let address, let cv, let value):
                return "address=\(address) cv=\(cv + 1) value=\(value)"
            case .pomAccessoryWriteByte(let address, let cv, let value):
                return "address=\(address + 1) cv=\(cv + 1) value=\(value)"
            case .setBroadcastFlags(let flags):
                return String(format: "flags=0x%08X", flags)
            case .rBusGetData(let groupIndex):
                return "group=\(groupIndex)"
        }
    }
}

extension Z21Message {
    var diagnosticName: String {
        switch self {
            case .cvResult: return "LAN_X_CV_RESULT"
            case .cvNack: return "LAN_X_CV_NACK"
            case .rBusDataChanged: return "LAN_RMBUS_DATACHANGED"
            case .unknown: return "UNKNOWN"
        }
    }

    var diagnosticSummary: String {
        switch self {
            case .cvResult(let cv, let value):
                return "cv=\(cv + 1) value=\(value)"
            case .cvNack:
                return ""
            case .rBusDataChanged(let groupIndex, _):
                return "group=\(groupIndex)"
            case .unknown(let header, _):
                return String(format: "header=0x%04X", header)
        }
    }
}
