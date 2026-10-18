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

    private let session: Z21Session
    private var connectionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    private var waiters: [UInt8: CheckedContinuation<UInt8?, Never>] = [:]
    private var writeWaiters: [UInt8: CheckedContinuation<Bool, Never>] = [:]


    init(
        transportFactory: @escaping Z21Session.TransportFactory = {
            Z21UDPTransport()
        },
        protocolCodec: any Z21ProtocolCodec = DefaultZ21ProtocolCodec()
    ) {
        session = Z21Session(
            transportFactory: transportFactory,
            codec: protocolCodec
        )
        observeSession()
    }

    func connect(host: String, port: UInt16) {
        connectionTask?.cancel()
        appendLog("Starting UDP connection to \(host):\(port)")

        connectionTask = Task { [weak self, session] in
            do {
                try await session.connect(host: host, port: port)
            } catch is CancellationError {
                return
            } catch {
                self?.appendLog("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        isRunning = false

        Task { [session] in
            await session.disconnect()
        }

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
        send(
            .pomReadByte(
                locomotiveAddress: locoAddress,
                cvAddress: UInt16(cv - 1)
            )
        )
    }

    func writeCV(locoAddress: UInt16?, cv: UInt8, value: UInt8) {
        guard let locoAddress else { return }
        guard cv >= 1 else {
            eventsSubject.send(.failure("Invalid CV number"))
            return
        }
        send(
            .pomWriteByte(
                locomotiveAddress: locoAddress,
                cvAddress: UInt16(cv - 1),
                value: value
            )
        )
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

                self.send(
                    .pomReadByte(
                        locomotiveAddress: locoAddress,
                        cvAddress: UInt16(cv - 1)
                    )
                )

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
                self.send(
                    .pomWriteByte(
                        locomotiveAddress: locoAddress,
                        cvAddress: UInt16(cv - 1),
                        value: value
                    ),
                    note: "WRITE CV \(cv)=\(value)"
                )

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

    func enableBroadcastFlags(_ flags: Z21BroadcastFlags) {
        Task { [weak self, session] in
            do {
                _ = try await session.enableBroadcastFlags(flags)
            } catch {
                self?.appendLog(
                    "Broadcast subscription failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func observeSession() {
        stateTask = Task { [weak self, session] in
            for await state in session.connectionStates {
                guard !Task.isCancelled else { return }
                self?.handleConnectionState(state)
            }
        }

        messageTask = Task { [weak self, session] in
            for await message in session.messages {
                guard !Task.isCancelled else { return }
                self?.handleInboundMessage(message)
            }
        }
    }

    private func send(_ command: Z21Command, note: String? = nil) {
        if let note { appendLog("→ \(note)") }

        Task { [weak self, session] in
            do {
                try await session.send(command)
            } catch {
                self?.appendLog("Send error: \(error.localizedDescription)")
            }
        }
    }

    private func handleConnectionState(_ state: Z21ConnectionState) {
        switch state {
            case .disconnected:
                isRunning = false
                appendLog("UDP disconnected.")
            case .connecting:
                isRunning = false
                appendLog("UDP connecting.")
            case .synchronized:
                isRunning = true
                appendLog("UDP ready.")
            case .degraded:
                isRunning = false
                appendLog("UDP connection degraded.")
        }
    }

    private func handleInboundMessage(_ message: Z21Message) {
        switch message {
            case .cvResult(let cvAddress, let value):
                guard let cv = UInt8(exactly: cvAddress + 1) else {
                    let error = Z21ProtocolCodecError.invalidCVAddress(cvAddress)
                    appendLog("  protocol error: \(error.localizedDescription)")
                    eventsSubject.send(.failure(error.localizedDescription))
                    return
                }
                eventsSubject.send(.cvReadResult(cv: cv, value: value))
                if let continuation = waiters.removeValue(forKey: cv) {
                    continuation.resume(returning: value)
                }
                // If writing CV desarm waiter
                if let continuation = writeWaiters.removeValue(forKey: cv) {
                    continuation.resume(returning: true)
                }
                appendLog("  event: CV_RESULT cv=\(cv) value=\(value)")

            case .cvNack:
                eventsSubject.send(.failure("CV read/write NACK"))
                appendLog("  event: CV_NACK")

            case .unknown(let header, _):
                appendLog(String(format: "  event: UNKNOWN header=0x%04X", header))
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
