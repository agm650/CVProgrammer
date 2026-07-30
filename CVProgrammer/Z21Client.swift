//
//  Z21Client.swift
//  CVProgrammer
//
//  Created by Luc Dandoy on 22/12/2025.
//
import Foundation
import Network
import Combine

@MainActor
final class Z21Client: ObservableObject, CVBackend {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var logText: String = ""

    private let maxLogLines = 100

    private let eventsSubject = PassthroughSubject<CVEvent, Never>()
    var cvEvents: AnyPublisher<CVEvent, Never> { eventsSubject.eraseToAnyPublisher() }

    private var connection: NWConnection?

    // Latest state of every known R-BUS input. Timestamps are captured as soon
    // as the UDP datagram is parsed, so calibration timing does not depend on UI refresh.
    private var feedbackSamples: [Z21FeedbackAddress: Z21FeedbackSample] = [:]

    func feedbackSample(for address: Z21FeedbackAddress) -> Z21FeedbackSample? {
        feedbackSamples[address]
    }

    private var waiters: [UInt8: CheckedContinuation<UInt8?, Never>] = [:]
    private var writeWaiters: [UInt8: CheckedContinuation<Bool, Never>] = [:]


    func connect(host: String, port: UInt16) {
        disconnect()

        let h = NWEndpoint.Host(host)
        guard let p = NWEndpoint.Port(rawValue: port) else {
            appendLog("Invalid port: \(port)")
            return
        }

        let conn = NWConnection(host: h, port: p, using: .udp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }

        conn.start(queue: .global())
        isRunning = true

        appendLog("Starting UDP connection to \(host):\(port)")
        beginReceiveLoop()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isRunning = false
        
        for (_, cont) in waiters {
            cont.resume(returning: nil)
        }
        waiters.removeAll()
    }

    func clearLog() {
        logText = ""
    }

    func readCV(locoAddress: UInt16?, cv: UInt8) {
        guard let locoAddress else { return }
        guard cv >= 1 else {
            eventsSubject.send(.failure("Invalid CV number"))
            return
        }
        let pkt = Z21Protocol.makePOMReadBytePacket(locoAddress: locoAddress, cvAddress0Based: cv - 1)
        send(pkt)
    }

    func writeCV(locoAddress: UInt16?, cv: UInt8, value: UInt8) {
        guard let locoAddress else { return }
        guard cv >= 1 else {
            eventsSubject.send(.failure("Invalid CV number"))
            return
        }
        let pkt = Z21Protocol.makePOMWriteBytePacket(locoAddress: locoAddress, cvAddress0Based: cv - 1, value: value)
        send(pkt)
    }

    func readCVAsync(locoAddress: UInt16, cv: UInt8, timeoutMs: Int = 800) async -> UInt8? {
        guard cv >= 1 else { return nil }
        let cv1 = cv

        return await withCheckedContinuation { cont in
            Task { @MainActor [weak self] in
                guard let self else {
                    cont.resume(returning: nil)
                    return
                }

                self.waiters[cv1] = cont

                let pkt = Z21Protocol.makePOMReadBytePacket(
                    locoAddress: locoAddress,
                    cvAddress0Based: cv - 1
                )
                self.send(pkt)

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    await MainActor.run {
                        if let c = self?.waiters.removeValue(forKey: cv1) {
                            c.resume(returning: nil)
                        }
                    }
                }
            }
        }
    }

    func writeCVAsync(locoAddress: UInt16, cv: UInt8, value: UInt8, timeoutMs: Int = 1200) async -> Bool {
        guard cv >= 1 else { return false }
        let cv1 = cv

        return await withCheckedContinuation { cont in
            Task { @MainActor [weak self] in
                guard let self else {
                    cont.resume(returning: false)
                    return
                }

                // register waiter first
                self.writeWaiters[cv1] = cont

                // send
                let pkt = Z21Protocol.makePOMWriteBytePacket(
                    locoAddress: locoAddress,
                    cvAddress0Based: cv - 1,
                    value: value
                )
                self.send(pkt, note: "WRITE CV \(cv)=\(value)")

                // timeout
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    await MainActor.run {
                        if let c = self?.writeWaiters.removeValue(forKey: cv1) {
                            c.resume(returning: false)
                        }
                    }
                }
            }
        }
    }

    func sendCalibrationPacket(_ data: Data, note: String? = nil) {
        send(data, note: note)
    }

    private func send(_ data: Data, note: String? = nil) {
        guard let conn = connection else {
            appendLog("Not connected; cannot send.")
            return
        }

        if let note { appendLog("→ \(note)") }
        appendLog("  bytes: \(data.hexString)")

        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if let error { self?.appendLog("Send error: \(error)") }
            }
        })
    }

    private func beginReceiveLoop() {
        guard let conn = connection else { return }

        conn.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor in
                if let error {
                    self?.appendLog("Receive error: \(error)")
                } else if let content, !content.isEmpty {
                    self?.appendLog("← RX bytes: \(content.hexString)")

                    let zEvent = Z21Protocol.parseInbound(content)

                    switch zEvent {
                        case .cvResult(let cv0, let value):
                            // convert 0-based cv -> 1-based for UI
                            let cv1 = UInt8(cv0) + 1
                            self?.eventsSubject.send(.cvReadResult(cv: cv1, value: value))
                            if let cont = self?.waiters.removeValue(forKey: cv1) {
                                cont.resume(returning: value)
                            }
                            // If writing CV desarm waiter
                            if let w = self?.writeWaiters.removeValue(forKey: cv1) {
                                w.resume(returning: true)
                            }

                        case .cvNack:
                            self?.eventsSubject.send(.failure("CV read/write NACK"))

                        case .rBusSnapshot(let groupIndex, let statuses):
                            self?.applyRBusSnapshot(groupIndex: groupIndex, statuses: statuses)

                        case .unknown:
                            break
                    }


                    self?.appendLog("  event: \(zEvent.description)")
                }
                self?.beginReceiveLoop()
            }
        }
    }

    private func applyRBusSnapshot(groupIndex: UInt8, statuses: [UInt8]) {
        let timestamp = MonotonicTimestamp.now()
        let firstModule = Int(groupIndex) * 10 + 1
        for (offset, byte) in statuses.prefix(10).enumerated() {
            let module = firstModule + offset
            for bit in 0..<8 {
                let address = Z21FeedbackAddress(module: module, input: bit + 1)
                let occupied = (byte & (1 << bit)) != 0
                if feedbackSamples[address]?.occupied != occupied {
                    appendLog("R-BUS module \(module), input \(bit + 1): \(occupied ? "occupied" : "free")")
                }
                feedbackSamples[address] = Z21FeedbackSample(occupied: occupied, timestamp: timestamp)
            }
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
            case .ready:
                appendLog("UDP ready.")
            case .failed(let err):
                appendLog("Connection failed: \(err)")
                disconnect()
            case .waiting(let err):
                appendLog("Connection waiting: \(err)")
            case .cancelled:
                appendLog("Connection cancelled.")
            default:
                break
        }
    }

    func appendLog(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let newLine = "[\(ts)] \(line)"

        var lines = logText.split(separator: "\n", omittingEmptySubsequences: true)
        lines.append(Substring(newLine))

        // ✅ Keep only the last N lines
        if lines.count > maxLogLines {
            lines = lines.suffix(maxLogLines)
        }

        logText = lines.joined(separator: "\n") + "\n"
    }

    func appendExternalLog(_ line: String) {
        appendLog(line)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum Z21Event: Equatable {
    case cvResult(cvAddress0Based: UInt8, value: UInt8)
    case cvNack
    case rBusSnapshot(groupIndex: UInt8, statuses: [UInt8])
    case unknown

    var description: String {
        switch self {
            case .cvResult(let cv0, let value):
                return "CV_RESULT cv=\(cv0 + 1) value=\(value)"
            case .cvNack:
                return "CV_NACK"
            case .rBusSnapshot(let groupIndex, let statuses):
                return "R_BUS group=\(groupIndex) status=\(statuses.map { String(format: "%02X", $0) }.joined(separator: " "))"
            case .unknown:
                return "UNKNOWN"
        }
    }
}
