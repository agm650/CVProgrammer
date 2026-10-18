//
//  Z21Client.swift
//  CVProgrammer
//
//  Created by Luc Dandoy on 22/12/2025.
//
import Foundation
import Combine

@MainActor
final class Z21Client: ObservableObject, CVBackend {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var logText: String = ""

    private let maxLogLines = 100

    private let eventsSubject = PassthroughSubject<CVEvent, Never>()
    var cvEvents: AnyPublisher<CVEvent, Never> { eventsSubject.eraseToAnyPublisher() }

    private let transportFactory: @MainActor () -> any Z21Transport
    private var transport: (any Z21Transport)?
    private var connectionTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var connectionID = UUID()

    private var waiters: [UInt8: CheckedContinuation<UInt8?, Never>] = [:]
    private var writeWaiters: [UInt8: CheckedContinuation<Bool, Never>] = [:]


    init(
        transportFactory: @escaping @MainActor () -> any Z21Transport = {
            Z21UDPTransport()
        }
    ) {
        self.transportFactory = transportFactory
    }

    func connect(host: String, port: UInt16) {
        disconnect()

        let newTransport = transportFactory()
        let newConnectionID = UUID()
        transport = newTransport
        connectionID = newConnectionID
        isRunning = true

        appendLog("Starting UDP connection to \(host):\(port)")

        receiveTask = Task { [weak self] in
            for await packet in newTransport.incomingPackets {
                guard !Task.isCancelled else { return }
                self?.handleInboundPacket(packet)
            }
        }

        connectionTask = Task { [weak self] in
            do {
                try await newTransport.connect(host: host, port: port)
                guard let self, self.connectionID == newConnectionID else { return }
                self.appendLog("UDP ready.")
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.connectionID == newConnectionID else { return }
                self.appendLog("Connection failed: \(error.localizedDescription)")
                self.disconnect()
            }
        }
    }

    func disconnect() {
        connectionID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        if let transport {
            Task {
                await transport.close()
            }
        }
        transport = nil
        isRunning = false

        for (_, continuation) in waiters {
            continuation.resume(returning: nil)
        }
        waiters.removeAll()

        for (_, continuation) in writeWaiters {
            continuation.resume(returning: false)
        }
        writeWaiters.removeAll()
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

    private func send(_ data: Data, note: String? = nil) {
        guard let transport else {
            appendLog("Not connected; cannot send.")
            return
        }

        if let note { appendLog("→ \(note)") }
        appendLog("  bytes: \(data.hexString)")

        Task { [weak self] in
            do {
                try await transport.send(data)
            } catch {
                self?.appendLog("Send error: \(error.localizedDescription)")
            }
        }
    }

    private func handleInboundPacket(_ content: Data) {
        appendLog("← RX bytes: \(content.hexString)")

        let zEvent = Z21Protocol.parseInbound(content)

        switch zEvent {
            case .cvResult(let cv0, let value):
                // convert 0-based cv -> 1-based for UI
                let cv1 = UInt8(cv0) + 1
                eventsSubject.send(.cvReadResult(cv: cv1, value: value))
                if let continuation = waiters.removeValue(forKey: cv1) {
                    continuation.resume(returning: value)
                }
                // If writing CV desarm waiter
                if let continuation = writeWaiters.removeValue(forKey: cv1) {
                    continuation.resume(returning: true)
                }

            case .cvNack:
                eventsSubject.send(.failure("CV read/write NACK"))

            case .unknown:
                break
        }

        appendLog("  event: \(zEvent.description)")
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
    case unknown

    var description: String {
        switch self {
            case .cvResult(let cv0, let value):
                return "CV_RESULT cv=\(cv0 + 1) value=\(value)"
            case .cvNack:
                return "CV_NACK"
            case .unknown:
                return "UNKNOWN"
        }
    }
}
