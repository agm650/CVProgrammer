import Foundation
import Network
import Combine

@MainActor
final class DCCEXBackend: ObservableObject, CVBackend {


    @Published private(set) var isRunning = false
    @Published private(set) var logText = ""

    // Handling trackBusy
    @Published private(set) var progTrackBusy: Bool = false

    private struct PendingProgOp {
        let id: Int           // callbacknum
        let sub: Int          // callbacksub
        let startedAt: Date
        let kind: Kind
        let cv: UInt8
        enum Kind { case read, write }
    }

    private var pending: PendingProgOp? = nil
    private var timeoutTask: Task<Void, Never>? = nil

    private let eventsSubject = PassthroughSubject<CVEvent, Never>()
    var cvEvents: AnyPublisher<CVEvent, Never> { eventsSubject.eraseToAnyPublisher() }

    private var connection: NWConnection?
    private var rxBuffer = Data()
    private let maxLogLines = 100

    private var writeContinuation: CheckedContinuation<Bool, Never>? = nil

    func connect(host: String, port: UInt16) {
        disconnect()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: .init(host), port: p, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleState(state) }
        }
        conn.start(queue: .global())
        isRunning = true
        appendLog("TCP connect to \(host):\(port) (DCC-EX)")
        receiveLoop()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isRunning = false
        rxBuffer.removeAll()

        pending = nil
        progTrackBusy = false
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func clearLog() { logText = "" }

    
    func readCV(locoAddress: UInt16?, cv: UInt8) {
        guard pending == nil else {
            eventsSubject.send(.failure("Programming track busy"))
            return
        }

        let (id, sub) = nextToken()
        pending = PendingProgOp(id: id, sub: sub, startedAt: Date(), kind: .read, cv: cv)
        progTrackBusy = true

        send("<R \(cv) \(id) \(sub)>", note: "READ CV \(cv)")
        startTimeout()
    }

    func writeCV(locoAddress: UInt16?, cv: UInt8, value: UInt8) {
        guard pending == nil else {
            eventsSubject.send(.failure("Programming track busy"))
            return
        }

        let (id, sub) = nextToken()
        pending = PendingProgOp(id: id, sub: sub, startedAt: Date(), kind: .write, cv: cv)
        progTrackBusy = true

        send("<W \(cv) \(value) \(id) \(sub)>", note: "WRITE CV \(cv)=\(value)")
        startTimeout()
    }

    func writeCVAsync(cv: UInt8, value: UInt8, timeoutMs: Int = 3000) async -> Bool {
        // only one operation at a time
        guard pending == nil else { return false }

        return await withCheckedContinuation { cont in
            Task { @MainActor [weak self] in
                guard let self else { cont.resume(returning: false); return }
                self.writeContinuation = cont
                self.writeCV(locoAddress: nil, cv: cv, value: value)
                // startTimeout() already runs and will clear busy; we should also resume cont on timeout:
                self.startTimeoutAsyncBridge()
            }
        }
    }

    private func startTimeoutAsyncBridge() {
        // If you already call startTimeout() in writeCV(), you can just ensure it resumes cont on timeout.
        // Easiest: modify startTimeout() to resume writeContinuation = false when it fires.
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

    private func send(_ cmd: String, note: String?) {
        guard let conn = connection else { return }
        if let note { appendLog("→ \(note)") }
        appendLog("  tx: \(cmd)")
        conn.send(content: cmd.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let data else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rxBuffer.append(data)
                self.parseBuffer()
                self.receiveLoop()
            }
        }
    }

    private func parseBuffer() {
        while true {
            // Find '<'
            guard let start = rxBuffer.firstIndex(of: UInt8(ascii: "<")) else {
                rxBuffer.removeAll(keepingCapacity: true)
                return
            }

            // Drop anything before '<'
            if start > 0 {
                rxBuffer.removeSubrange(0..<start)
            }

            // Find '>' AFTER '<'
            guard let end = rxBuffer[start...].firstIndex(of: UInt8(ascii: ">")) else {
                return // wait for more data
            }

            // include '>' by using end + 1
            let msgData = rxBuffer.subdata(in: start..<rxBuffer.index(after: end))
            rxBuffer.removeSubrange(0..<rxBuffer.index(after: end))

            let msg = String(decoding: msgData, as: UTF8.self)
            appendLog("← rx: \(msg)")
            handle(msg)
        }
    }



    private func handle(_ msg: String) {
        guard msg.first == "<", msg.last == ">" else { return }

        let inner = msg.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = inner.split(separator: " ").map(String.init)
        guard let head = parts.first else { return }

        switch head {
            case "v":
                // Read response:
                // 1) <v cv value>
                // 2) <v callbacknum|callbacksub|cv value>
                handleReadResponse(parts)

            case "r":
                // Write response:
                // 1) <r cv value>
                // 2) <r callbacknum|callbacksub|cv value>
                handleWriteResponse(parts)

            default:
                break
        }
    }

    private func handleState(_ state: NWConnection.State) {
        if case .ready = state { appendLog("TCP ready") }
    }

    private func nextToken() -> (Int, Int) {
        (Int.random(in: 1...32767), Int.random(in: 0...32767))
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            guard pending != nil else { return }
            appendLog("Programming operation timed out.")
            eventsSubject.send(.failure("Programming operation timed out"))
            pending = nil
            progTrackBusy = false
        }

        self.writeContinuation?.resume(returning: false)
        self.writeContinuation = nil
    }

    private func handleReadResponse(_ parts: [String]) {
        // parts example: ["v", "29", "34"] OR ["v", "123|1|29", "34"]
        guard parts.count >= 3 else { return }

        let (tokenId, tokenSub, cv) = parseTokenOrCV(parts[1])
        guard let cv else { return }

        let valInt = Int(parts[2]) ?? -1
        finishIfMatchesPending(tokenId: tokenId, tokenSub: tokenSub, cv: cv)

        if valInt < 0 {
            eventsSubject.send(.failure("Read CV\(cv) failed"))
            return
        }
        eventsSubject.send(.cvReadResult(cv: cv, value: UInt8(clamping: valInt)))
    }

    private func handleWriteResponse(_ parts: [String]) {
        // parts example: ["r", "29", "34"] OR ["r", "123|1|29", "34"]
        guard parts.count >= 3 else { return }

        let (tokenId, tokenSub, cv) = parseTokenOrCV(parts[1])
        guard let cv else { return }

        let valInt = Int(parts[2]) ?? -1
        finishIfMatchesPending(tokenId: tokenId, tokenSub: tokenSub, cv: cv)

        if valInt < 0 {
            eventsSubject.send(.failure("Write CV\(cv) failed"))
            writeContinuation?.resume(returning: false)
            writeContinuation = nil
            return
        }
        eventsSubject.send(.cvWriteResult(cv: cv, value: UInt8(clamping: valInt)))
        writeContinuation?.resume(returning: true)
        writeContinuation = nil

    }

    /// Parses either:
    /// - "29"                 => (nil, nil, 29)
    /// - "123|1|29"           => (123, 1, 29)
    private func parseTokenOrCV(_ field: String) -> (Int?, Int?, UInt8?) {
        if field.contains("|") {
            let comps = field.split(separator: "|").map(String.init)
            guard comps.count >= 3 else { return (nil, nil, nil) }
            let id = Int(comps[0])
            let sub = Int(comps[1])
            let cv = UInt8(comps[2])
            return (id, sub, cv)
        } else {
            return (nil, nil, UInt8(field))
        }
    }

    private func finishIfMatchesPending(tokenId: Int?, tokenSub: Int?, cv: UInt8) {
        guard let pending else { return }

        // If the response carries a token, require it to match.
        if let tokenId, let tokenSub {
            guard tokenId == pending.id, tokenSub == pending.sub else { return }
        } else {
            // If no token in response, fall back to CV match (best effort).
            guard cv == pending.cv else { return }
        }

        // This response completes our programming op
        self.pending = nil
        progTrackBusy = false
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}


private extension UInt8 {
    init(clamping value: Int) {
        let clamped = UInt8(Swift.max(Int(UInt8.min), Swift.min(Int(UInt8.max), value)))
        self = UInt8(clamped)
    }
}
