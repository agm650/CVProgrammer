//
//  ContentView.swift
//  CVProgrammer
//
//  Created by Luc Dandoy on 22/12/2025.
//

import SwiftUI

enum CommandStationType: String, CaseIterable, Identifiable {
    case z21 = "z21"
    case dccEx = "dccEx"
    var id: String { rawValue }

    var displayName: String {
        switch self {
            case .z21: return "Roco z21"
            case .dccEx: return "DCC-EX"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var meta: CVMetadataStore
    @StateObject var z21 = Z21Client()
    @StateObject var dcc = DCCEXBackend()
    @AppStorage(PreferencesKeys.preferredProtocol)
    private var preferredProtocolRaw: String = CommandStationType.z21.rawValue
    @State private var type: CommandStationType = .z21
    @State private var isShowingRBusMonitor = false

    @AppStorage(PreferencesKeys.remoteIP) private var remoteIPStored: String = "192.168.0.111"
    private var host: String {
        remoteIPStored
    }
    @AppStorage(PreferencesKeys.remotePort) private var remotePortStored: Int = 21105
    private var port: UInt16 {
        UInt16(Swift.max(1, Swift.min(65535, remotePortStored)))
    }

    @State private var locoAddress: UInt16 = 3
    @State private var cvNumber1Based: UInt8 = 1
    @State private var cvValue: UInt8 = 3
    // Max CV to parse
    @AppStorage(PreferencesKeys.maxCvValue) private var maxCvValueStored: Int = 255
    private var maxCvValue: UInt8 {
        UInt8(Swift.max(1, Swift.min(Int(UInt8.max), maxCvValueStored)))
    }


    // for DCCEX Busy mode
    @State private var nextRangeCV: UInt8? = nil

    // CV results stored by CV number (1-based for display)
    @State private var cvResults: [UInt8: UInt8] = [:]

    // Range read task
    @State private var rangeTask: Task<Void, Never>?

    // Load CV value
    @State private var selectedCV: UInt8? = nil

    // Metadata
    @EnvironmentObject private var metaStore: CVMetadataStore

    // export support
    @State private var isExporting = false
    @State private var exportFormat: CVExportFormat = .csv
    @State private var exportDocument = CVExportDocument(data: Data())
    @State private var exportFilename = "cv_export.csv"
    // import support
    @State private var isImporting = false
    @State private var importError: String?
    // Bulk write
    @State private var bulkWriteTask: Task<Void, Never>? = nil

    // autoscroll
    @AppStorage(PreferencesKeys.logAutoScroll) private var logAutoScroll: Bool = true

    private var client: any CVBackend { type == .z21 ? z21 : dcc }

    // DCC EX busy indicator
    private var isBusy: Bool {
        type == .dccEx && dcc.progTrackBusy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("CV Programming Tool")
                    .font(.title2)
                    .bold()
                Picker("Protocol", selection: $type) {
                    ForEach(CommandStationType.allCases) { t in
                        Text(t.displayName).tag(t) }
                }
                GroupBox("Connection") {
                    HStack {
                        TextField("IP / Host", text: $remoteIPStored)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)

                        TextField("Port", value: $remotePortStored, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)

                        Button(client.isRunning ? "Disconnect" : "Connect") {
                            if client.isRunning {
                                client.disconnect()
                            } else {
                                client.connect(host: host, port: port)
                            }
                        }
                    }

                    HStack {
                        Circle()
                            .fill(client.isRunning ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(client.isRunning ? "Ready" : "Not connected")
                            .foregroundStyle(.secondary)

                        Spacer()

                        if type == .z21 {
                            Button("R-BUS Monitor…") {
                                isShowingRBusMonitor = true
                            }
                            .accessibilityIdentifier("rbus.open")
                        }
                    }
                }

                GroupBox(type == .z21 ? "POM (Programming on the Main)" : "Programming Track (Service Mode)") {
                    VStack(alignment: .leading, spacing: 10) {

                        metadataErrorView

                        // DCC-EX programming track busy indicator
                        if type == .dccEx {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(dcc.progTrackBusy ? .orange : .green)
                                    .frame(width: 10, height: 10)

                                Text(dcc.progTrackBusy ? "Programming track busy…" : "Programming track ready")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if type == .z21 {
                            Text("Note: POM read needs RailCom enabled in the Z21 and in the decoder.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Locomotive Address")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", value: $locoAddress, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                                    .disabled(type == .dccEx)
                            }

                            VStack(alignment: .leading) {
                                Text("CV (1–\(maxCvValue))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", value: $cvNumber1Based, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                    .onChange(of: cvNumber1Based) {
                                        v in
                                        if v < 1 { cvNumber1Based = 1 }
                                        if v > maxCvValue { cvNumber1Based = maxCvValue }
                                    }
                                    .onChange(of: cvValue) { v in
                                        // UInt8 is already 0..255, so no clamp needed unless you use Int input.
                                    }
                            }

                            VStack(alignment: .leading) {
                                Text("Value (0–255)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", value: $cvValue, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                    .disabled(isCurrentReadOnly)
                            }

                            Spacer()

                            Button("Write CV") { client.writeCV(locoAddress: type == .z21 ? locoAddress : nil, cv: cvNumber1Based, value: cvValue) }
                                .disabled(!client.isRunning || isCurrentReadOnly || isBusy )

                            Button("Read CV") {
                                // readCV(single: cvNumber1Based)
                                client.readCV(
                                    locoAddress: type == .z21 ? locoAddress : nil, cv: cvNumber1Based)
                            }.disabled(!client.isRunning || isBusy )
                        }

                        if let meta = currentMeta {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("CV\(meta.number): \(meta.name)")
                                    .font(.headline)
                                Text(meta.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                if isCurrentReadOnly {
                                    Text("This CV is marked read-only and cannot be written.")
                                        .font(.footnote).foregroundColor(.red)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 6)
                        }
                        BitEditorView(
                            value: $cvValue,
                            bitLabels: currentMeta?.bitLabels ?? [:]
                        )
                        .disabled(isCurrentReadOnly)
                        .opacity(isCurrentReadOnly ? 0.6 : 1.0)
                        .padding(.top, 8)
                        Divider()

                        HStack {
                            Button("Read CV 1–\(maxCvValue)") {
                                startReadRange()
                            }
                            .disabled(!client.isRunning || rangeTask != nil)

                            Button("Stop") {
                                rangeTask?.cancel()
                                rangeTask = nil
                                nextRangeCV = nil
                            }
                            .disabled(rangeTask == nil)

                            Button("Clear Results") {
                                cvResults.removeAll()
                            }

                            Picker("Export", selection: $exportFormat) {
                                ForEach(CVExportFormat.allCases) { f in
                                    Text(f.rawValue).tag(f)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            Button("Bulk Write Results") {
                                startBulkWrite()
                            }
                            .disabled(!client.isRunning || cvResults.isEmpty || bulkWriteTask != nil || isBusy)

                            Button("Stop Write") {
                                bulkWriteTask?.cancel()
                                bulkWriteTask = nil
                            }
                            .disabled(bulkWriteTask == nil)

                            Button("Export…") {
                                prepareExport()
                            }
                            .disabled(cvResults.isEmpty)
                            Button("Import…") {
                                isImporting = true
                                rangeTask?.cancel()
                                rangeTask = nil
                                nextRangeCV = nil
                            }

                            Spacer()

                            Text("Read: \(cvResults.count)/\(maxCvValue)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("CV Results") {
                    Table(rows, selection: $selectedCV) {
                        TableColumn("CV") { row in
                            Text("\(row.cv)").monospacedDigit()
                        }
                        TableColumn("Value") { row in
                            Text("\(row.value)").monospacedDigit()
                        }
                    }
                    .onChange(of: selectedCV) { newValue in
                        guard let cv = newValue else { return }
                        cvNumber1Based = cv
                        if let v = cvResults[cv] {
                            cvValue = v
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 220)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Log")
                                .font(.headline)

                            Spacer()

                            Button("Clear Log") {
                                client.clearLog()
                            }
                            .disabled(client.logText.isEmpty)
                        }

                        Divider()

                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(client.logText)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 4)

                                // Anchor at bottom for scrolling
                                Color.clear
                                    .frame(height: 1)
                                    .id("LOG_BOTTOM")
                            }
                            .frame(minHeight: 160)
                            .onChange(of: client.logText) { _ in
                                guard logAutoScroll else { return }
                                // Auto-scroll to bottom whenever new log arrives
                                withAnimation(nil) {
                                    proxy.scrollTo("LOG_BOTTOM", anchor: .bottom)
                                }
                            }
                            .onAppear {
                                // Ensure it starts scrolled to bottom
                                proxy.scrollTo("LOG_BOTTOM", anchor: .bottom)
                            }
                        }
                    }
                } // no "Log" title here because we made our own header row


                Spacer()
            }
            .padding(16)
            .frame(minWidth: 820, minHeight: 620)
            .onAppear {
                if let saved = CommandStationType(rawValue: preferredProtocolRaw) {
                    type = saved
                }
            }
            .onReceive(client.cvEvents) { event in
                switch event {
                    case .cvReadResult(let cv, let value):
                        if (1...maxCvValue).contains(cv) {
                            cvResults[cv] = value
                        }
                        if cv == cvNumber1Based { cvValue = value }

                    case .cvWriteResult(let cv, let value):
                        if (1...maxCvValue).contains(cv) {
                            cvResults[cv] = value
                        }
                        if cv == cvNumber1Based { cvValue = value }

                    case .failure(let message):
                        client.appendExternalLog("Error: \(message)")
                    case .nack:
                        client.appendExternalLog("NACK received")
                    case .info(let msg):
                        client.appendExternalLog("Info: \(msg)")
                }
            }
            .onChange(of: type) {
                newType in preferredProtocolRaw = newType.rawValue
            }
            .onChange(of: preferredProtocolRaw) { raw in
                guard let saved = CommandStationType(rawValue: raw) else { return }
                type = saved
            }
            .onChange(of: dcc.progTrackBusy) { busy in
                // When an operation completes, busy becomes false → send next CV
                guard type == .dccEx else { return }
                if rangeTask != nil, busy == false {
                    advanceRangeAfterReadCompletion()
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.commaSeparatedText, .json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        Task { @MainActor in
                            importCVResults(from: url)
                        }
                    case .failure(let error):
                        importError = error.localizedDescription
                        client.appendExternalLog("Import failed: \(error.localizedDescription)")
                }
            }
            .alert("Import Error", isPresented: Binding(
                get: { importError != nil },
                set: { _ in importError = nil }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $isShowingRBusMonitor) {
                RBusMonitorView(
                    service: z21.rBusService,
                    programmingService: z21.deviceProgrammingService
                )
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: exportFormat.utType,
                defaultFilename: exportFilename
            ) { result in
                // Optional: log success/failure
                switch result {
                    case .success(let url):
                        client.appendExternalLog("Exported to \(url.lastPathComponent)")
                    case .failure(let error):
                        client.appendExternalLog("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private var rows: [CVRow] {
        cvResults
            .map { CVRow(cv: $0.key, value: Int($0.value)) }
            .sorted { $0.cv < $1.cv }
    }

    private func startReadRange() {
        rangeTask?.cancel()
        cvResults.removeAll()

        if type == .z21 {
            rangeTask = Task { @MainActor in
                for cv in 1...Int(maxCvValue) {
                    if Task.isCancelled { break }

                    var value: UInt8? = nil
                    var attempts = 0

                    while value == nil && attempts < 3 && !Task.isCancelled {
                        value = await z21.readCVAsync(
                            locoAddress: locoAddress,
                            cv: UInt8(cv),
                            timeoutMs: 1200
                        )
                        attempts += 1
                    }

                    if value == nil {
                        client.appendExternalLog("CV \(cv) timed out after 3 attempts")
                    }

                    // Small pacing even after success
                    try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
                }

                rangeTask = nil
            }
        } else {
            // DCC-EX path unchanged
            rangeTask = Task { @MainActor in
                nextRangeCV = 1
                sendNextRangeReadIfPossible()
            }
        }
    }



    @MainActor
    private func sendNextRangeReadIfPossible() {
        guard rangeTask != nil else { return }
        guard let cv = nextRangeCV else { return }
        guard cv >= 1 && cv <= maxCvValue else {
            // Done
            rangeTask = nil
            nextRangeCV = nil
            return
        }

        // In DCC-EX mode, only send when not busy
        if type == .dccEx && isBusy {
            return
        }

        client.readCV(
            locoAddress: type == .z21 ? locoAddress : nil,
            cv: cv
        )
    }

    @MainActor
    private func advanceRangeAfterReadCompletion() {
        guard rangeTask != nil else { return }
        guard let cv = nextRangeCV else { return }

        let next = cv + 1
        nextRangeCV = next
        sendNextRangeReadIfPossible()
    }


    private var currentMeta: CVMeta? {
       return   metaStore.meta(for: cvNumber1Based)
    }

    @ViewBuilder
    private var metadataErrorView: some View {
        if let err = metaStore.loadError {
            Text("Metadata load error: \(err)")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func prepareExport() {
        let data: Data
        switch exportFormat {
            case .csv:
                data = makeCSVExport(
                    locoAddress: locoAddress,
                    cvResults: cvResults,
                    metaStore: metaStore
                )
                exportFilename = exportFormat.defaultFilename

            case .json:
                data = makeJSONExport(
                    locoAddress: locoAddress,
                    cvResults: cvResults,
                    metaStore: metaStore
                )
                exportFilename = exportFormat.defaultFilename
        }

        exportDocument = CVExportDocument(data: data)
        isExporting = true
    }

    private func appendUILog(_ line: String) {
        // piggyback on the existing client.logText without changing client
        client.appendExternalLog(line)
    }

    private var isCurrentReadOnly: Bool {
        currentMeta?.readOnly == true
    }

    private func importCSV(_ data: Data) throws -> [UInt8: UInt8] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidEncoding
        }

        var result: [UInt8: UInt8] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let parts = line.split(separator: ",", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let a = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let b = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            guard let cv = UInt8(a), let value = UInt8(b), cv >= 1 else { continue }
            result[cv] = value
        }

        return result
    }


    private func importJSON(_ data: Data) throws -> [UInt8: UInt8] {
        let decoded = try JSONDecoder().decode([String: UInt8].self, from: data)

        var result: [UInt8: UInt8] = [:]
        for (k, v) in decoded {
            if let cv = UInt8(k), cv >= 1 {
                result[cv] = v
            }
        }
        return result
    }

    private func importCVResults(from url: URL) {
        do {
            let data = try Data(contentsOf: url)

            let imported: [UInt8: UInt8]
            switch url.pathExtension.lowercased() {
                case "csv":
                    imported = try importCSV(data)
                case "json":
                    imported = try importJSON(data)
                default:
                    throw ImportError.unsupportedFormat
            }

            // ✅ Replace mode + clamp to configured max CV
            let filtered = imported.filter { (cv, _) in
                cv >= 1 && cv <= maxCvValue
            }

            cvResults = filtered

            // ✅ Keep selection/editor consistent
            if let sel = selectedCV, cvResults[sel] == nil {
                selectedCV = nil
            }
            if let v = cvResults[cvNumber1Based] {
                cvValue = v
            }

            client.appendExternalLog("Imported \(filtered.count) CVs (replaced) from \(url.lastPathComponent)")

        } catch {
            importError = error.localizedDescription
            client.appendExternalLog("Import failed: \(error.localizedDescription)")
        }
    }


    enum ImportError: LocalizedError {
        case invalidEncoding
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
                case .invalidEncoding:
                    return "File encoding is not UTF-8."
                case .unsupportedFormat:
                    return "Unsupported file format."
            }
        }
    }

    private func startBulkWrite() {
        bulkWriteTask?.cancel()

        let items = cvResults
            .map { (cv: $0.key, value: $0.value) }
            .sorted { $0.cv < $1.cv }

        bulkWriteTask = Task { @MainActor in
            client.appendExternalLog("Starting bulk write of \(items.count) CVs…")

            for item in items {
                if Task.isCancelled { break }

                // Skip read-only CVs from metadata
                if metaStore.meta(for: item.cv)?.readOnly == true {
                    client.appendExternalLog("Skipping CV\(item.cv) (read-only)")
                    continue
                }

                let ok: Bool

                if type == .z21 {
                    // Z21 needs a loco address for POM
                    ok = await z21.writeCVAsync(
                        locoAddress: locoAddress,
                        cv: item.cv,
                        value: item.value,
                        timeoutMs: 1200
                    )
                } else {
                    // DCC-EX uses programming track, no loco address
                    ok = await dcc.writeCVAsync(
                        cv: item.cv,
                        value: item.value,
                        timeoutMs: 3000
                    )
                }

                if ok {
                    client.appendExternalLog("Wrote CV\(item.cv)=\(item.value)")
                } else {
                    client.appendExternalLog("Write failed CV\(item.cv)=\(item.value)")
                }

                // pacing: protect command station/decoder
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            }

            client.appendExternalLog("Bulk write finished.")
            bulkWriteTask = nil
        }
    }

}

struct CVRow: Identifiable {
    var id: UInt8 { cv }
    let cv: UInt8
    let value: Int
}

