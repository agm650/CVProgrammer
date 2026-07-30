import Foundation
import SwiftUI

struct SpeedCurvePoint: Identifiable, Equatable {
    let index: Int
    let cv: UInt8
    let dccStep: UInt8
    var value: UInt8
    var targetKPH: Double
    var measuredKPH: Double?
    var id: Int { index }
}

enum SpeedCurveShape: String, CaseIterable, Identifiable {
    case linear = "Linear"
    case progressive = "Progressive"
    case veryProgressive = "Very progressive"

    var id: String { rawValue }
    var gamma: Double {
        switch self {
        case .linear: return 1.0
        case .progressive: return 1.55
        case .veryProgressive: return 2.0
        }
    }
}

struct SpeedCalibrationConfiguration {
    var locoAddress: UInt16 = 3
    var scale: Double = 87
    var measurementLengthMM: Double = 1000
    var minimumSpeedKPH: Double = 3
    var maximumSpeedKPH: Double = 120
    var shape: SpeedCurveShape = .progressive
    var directionForward = true
    var repetitions = 3
    var stabilizationLaps = 1
    var toleranceKPH = 2.0
    var maximumAdjustmentPasses = 3
    var detectorBaseModule = 1
    var entryInput = 1
    var measurementInput = 2
    var exitInput = 3
    var sensorTimeoutSeconds = 180.0

    var entryAddress: Z21FeedbackAddress {
        Z21FeedbackAddress(detector10819BaseModule: detectorBaseModule, physicalInput: entryInput)
    }
    var measurementAddress: Z21FeedbackAddress {
        Z21FeedbackAddress(detector10819BaseModule: detectorBaseModule, physicalInput: measurementInput)
    }
    var exitAddress: Z21FeedbackAddress {
        Z21FeedbackAddress(detector10819BaseModule: detectorBaseModule, physicalInput: exitInput)
    }
}

enum SpeedCurveGenerator {
    static func generate(_ configuration: SpeedCalibrationConfiguration) -> [SpeedCurvePoint] {
        (0..<28).map { index in
            let x = Double(index) / 27.0
            let shaped = pow(x, configuration.shape.gamma)
            let target = configuration.minimumSpeedKPH
                + (configuration.maximumSpeedKPH - configuration.minimumSpeedKPH) * shaped
            let value = UInt8(clamping: Int((1.0 + shaped * 254.0).rounded()))
            let dccStep = UInt8(clamping: Int((Double(index + 1) * 126.0 / 28.0).rounded()))
            return SpeedCurvePoint(
                index: index + 1,
                cv: UInt8(67 + index),
                dccStep: max(1, dccStep),
                value: value,
                targetKPH: target,
                measuredKPH: nil
            )
        }
    }

    static func scaleSpeedKPH(distanceMM: Double, elapsed: TimeInterval, scale: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        return (distanceMM / 1000.0) / elapsed * 3.6 * scale
    }

    static func adjustedValue(current: UInt8, target: Double, measured: Double) -> UInt8 {
        guard measured > 0 else { return current }
        let ratio = min(1.35, max(0.65, target / measured))
        let proposed = Int((Double(current) * ratio).rounded())
        return UInt8(clamping: max(1, proposed))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2.0
            : sorted[middle]
    }
}

enum SpeedCalibrationState: Equatable {
    case idle
    case checking
    case programming
    case stabilizing(point: Int, lap: Int)
    case measuring(point: Int, repetition: Int)
    case adjusting(point: Int, pass: Int)
    case completed
    case cancelled
    case failed(String)
}

enum SpeedCalibrationError: LocalizedError {
    case invalidConfiguration(String)
    case sensorUnknown(Z21FeedbackAddress)
    case sensorOccupied(Z21FeedbackAddress)
    case sensorTimeout(Z21FeedbackAddress)
    case invalidMeasurement
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .sensorUnknown(let address): return "No R-BUS status received for module \(address.module), input \(address.input)."
        case .sensorOccupied(let address): return "Module \(address.module), input \(address.input) is occupied before calibration starts."
        case .sensorTimeout(let address): return "Timeout waiting for module \(address.module), input \(address.input)."
        case .invalidMeasurement: return "The measured travel time is invalid."
        case .cancelled: return "Calibration cancelled."
        }
    }
}

@MainActor
final class SpeedCalibrationModel: ObservableObject {
    @Published var configuration = SpeedCalibrationConfiguration()
    @Published var points: [SpeedCurvePoint] = []
    @Published var state: SpeedCalibrationState = .idle
    @Published var status = "Ready"
    @Published var acknowledgedBackupWarning = false
    @Published var activateSpeedTable = true

    private weak var z21: Z21Client?
    private var task: Task<Void, Never>?

    init(z21: Z21Client) {
        self.z21 = z21
        self.points = SpeedCurveGenerator.generate(configuration)
    }

    var isRunning: Bool {
        switch state {
        case .checking, .programming, .stabilizing, .measuring, .adjusting: return true
        default: return false
        }
    }

    func regenerate() {
        guard !isRunning else { return }
        points = SpeedCurveGenerator.generate(configuration)
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopLocomotive()
        state = .cancelled
        status = "Calibration cancelled; locomotive stopped."
    }

    func programCurveOnly() {
        startTask(runMeasurements: false)
    }

    func startAutomaticCalibration() {
        startTask(runMeasurements: true)
    }

    private func startTask(runMeasurements: Bool) {
        guard !isRunning else { return }
        guard acknowledgedBackupWarning else {
            state = .failed("Confirm that the decoder configuration has been backed up.")
            return
        }
        guard let z21, z21.isRunning else {
            state = .failed("The z21 is not connected.")
            return
        }
        do {
            try validateConfiguration()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        regenerate()
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.run(runMeasurements: runMeasurements)
            } catch is CancellationError {
                self.stopLocomotive()
                self.state = .cancelled
                self.status = "Calibration cancelled; locomotive stopped."
            } catch {
                self.stopLocomotive()
                self.state = .failed(error.localizedDescription)
                self.status = error.localizedDescription
            }
        }
    }

    private func validateConfiguration() throws {
        guard configuration.detectorBaseModule >= 1, configuration.detectorBaseModule <= 19 else {
            throw SpeedCalibrationError.invalidConfiguration("The 10819 base R-BUS module address must be between 1 and 19.")
        }
        for input in [configuration.entryInput, configuration.measurementInput, configuration.exitInput] {
            guard (1...16).contains(input) else {
                throw SpeedCalibrationError.invalidConfiguration("Each 10819 physical input must be between 1 and 16.")
            }
        }
        let addresses = Set([configuration.entryAddress, configuration.measurementAddress, configuration.exitAddress])
        guard addresses.count == 3 else {
            throw SpeedCalibrationError.invalidConfiguration("Entry, measurement and exit must use three different detector inputs.")
        }
        guard configuration.measurementLengthMM > 0, configuration.scale > 0 else {
            throw SpeedCalibrationError.invalidConfiguration("Scale and measurement length must be greater than zero.")
        }
        guard configuration.maximumSpeedKPH > configuration.minimumSpeedKPH else {
            throw SpeedCalibrationError.invalidConfiguration("Maximum speed must be greater than minimum speed.")
        }
        guard configuration.repetitions >= 1, configuration.stabilizationLaps >= 0 else {
            throw SpeedCalibrationError.invalidConfiguration("Repetitions must be at least 1 and stabilization laps cannot be negative.")
        }
    }

    private func run(runMeasurements: Bool) async throws {
        guard let z21 else { throw SpeedCalibrationError.cancelled }
        state = .checking
        status = "Checking R-BUS detector inputs…"
        z21.subscribeToRBusFeedback()
        try await Task.sleep(nanoseconds: 500_000_000)
        try Task.checkCancellation()
        try ensureSensorsAreKnownAndFree()

        state = .programming
        status = "Programming CV29 and CV67-CV94…"
        try await programInitialCurve()

        guard runMeasurements else {
            state = .completed
            status = "Speed table programmed successfully."
            return
        }

        for index in points.indices {
            try Task.checkCancellation()
            try await calibratePoint(at: index)
        }

        stopLocomotive()
        state = .completed
        status = "Automatic speed calibration completed."
    }

    private func programInitialCurve() async throws {
        guard let z21 else { throw SpeedCalibrationError.cancelled }
        if activateSpeedTable {
            guard let current = await z21.readCVAsync(
                locoAddress: configuration.locoAddress,
                cv: 29,
                timeoutMs: 1800
            ) else {
                throw SpeedCalibrationError.invalidConfiguration(
                    "Unable to read CV29. POM reading/RailCom is required to preserve its other bits."
                )
            }
            let updated = current | 0x10
            if updated != current {
                z21.writeCV(locoAddress: configuration.locoAddress, cv: 29, value: updated)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        for point in points {
            try Task.checkCancellation()
            status = "Programming CV\(point.cv)=\(point.value)…"
            z21.writeCV(locoAddress: configuration.locoAddress, cv: point.cv, value: point.value)
            try await Task.sleep(nanoseconds: 180_000_000)
        }
    }

    private func calibratePoint(at index: Int) async throws {
        guard let z21 else { throw SpeedCalibrationError.cancelled }
        var point = points[index]
        z21.setLocomotiveSpeed(
            address: configuration.locoAddress,
            step: point.dccStep,
            forward: configuration.directionForward
        )

        if configuration.stabilizationLaps > 0 {
            for lap in 1...configuration.stabilizationLaps {
                state = .stabilizing(point: point.index, lap: lap)
                status = "Point \(point.index)/28 — stabilization lap \(lap)/\(configuration.stabilizationLaps)…"
                try await waitForCompletePassage()
            }
        }

        for pass in 1...configuration.maximumAdjustmentPasses {
            var measurements: [Double] = []
            for repetition in 1...configuration.repetitions {
                state = .measuring(point: point.index, repetition: repetition)
                status = "Point \(point.index)/28 — measurement \(repetition)/\(configuration.repetitions)…"
                measurements.append(try await measureOnePassage())
            }

            guard let median = SpeedCurveGenerator.median(measurements) else {
                throw SpeedCalibrationError.invalidMeasurement
            }
            point.measuredKPH = median
            points[index] = point

            let error = abs(point.targetKPH - median)
            if error <= configuration.toleranceKPH { return }

            let adjusted = SpeedCurveGenerator.adjustedValue(
                current: point.value,
                target: point.targetKPH,
                measured: median
            )
            guard adjusted != point.value else { return }

            state = .adjusting(point: point.index, pass: pass)
            status = "Point \(point.index)/28 — adjusting CV\(point.cv) from \(point.value) to \(adjusted)…"
            point.value = adjusted
            points[index] = point
            z21.writeCV(locoAddress: configuration.locoAddress, cv: point.cv, value: adjusted)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitForCompletePassage()
        }
    }

    private func ensureSensorsAreKnownAndFree() throws {
        guard let z21 else { throw SpeedCalibrationError.cancelled }
        for address in [configuration.entryAddress, configuration.measurementAddress, configuration.exitAddress] {
            guard let sample = z21.feedbackSample(for: address) else {
                throw SpeedCalibrationError.sensorUnknown(address)
            }
            if sample.occupied { throw SpeedCalibrationError.sensorOccupied(address) }
        }
    }

    private func waitForCompletePassage() async throws {
        let first = configuration.directionForward ? configuration.entryAddress : configuration.exitAddress
        let last = configuration.directionForward ? configuration.exitAddress : configuration.entryAddress
        _ = try await waitForRisingEdge(first)
        _ = try await waitForRisingEdge(configuration.measurementAddress)
        _ = try await waitForRisingEdge(last)
    }

    private func measureOnePassage() async throws -> Double {
        let last = configuration.directionForward ? configuration.exitAddress : configuration.entryAddress
        let start = try await waitForRisingEdge(configuration.measurementAddress)
        let end = try await waitForRisingEdge(last)
        let seconds = start.duration(to: end)
        guard seconds > 0 else { throw SpeedCalibrationError.invalidMeasurement }
        return SpeedCurveGenerator.scaleSpeedKPH(
            distanceMM: configuration.measurementLengthMM,
            elapsed: seconds,
            scale: configuration.scale
        )
    }

    private func waitForRisingEdge(_ address: Z21FeedbackAddress) async throws -> MonotonicTimestamp {
        guard let z21 else { throw SpeedCalibrationError.cancelled }
        let deadline = MonotonicTimestamp.now().advanced(by: configuration.sensorTimeoutSeconds)

        // First make sure a previous occupation has cleared. The 10819 deliberately
        // delays the free indication, so we wait for the actual R-BUS state.
        while let sample = z21.feedbackSample(for: address), sample.occupied {
            try Task.checkCancellation()
            if MonotonicTimestamp.now() >= deadline { throw SpeedCalibrationError.sensorTimeout(address) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let armedAt = MonotonicTimestamp.now()
        while MonotonicTimestamp.now() < deadline {
            try Task.checkCancellation()
            if let sample = z21.feedbackSample(for: address), sample.occupied, sample.timestamp >= armedAt {
                return sample.timestamp
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw SpeedCalibrationError.sensorTimeout(address)
    }

    private func stopLocomotive() {
        z21?.setLocomotiveSpeed(
            address: configuration.locoAddress,
            step: 0,
            forward: configuration.directionForward
        )
    }
}

struct SpeedCalibrationView: View {
    @StateObject private var model: SpeedCalibrationModel
    @Environment(\.dismiss) private var dismiss

    init(z21: Z21Client, locoAddress: UInt16) {
        let model = SpeedCalibrationModel(z21: z21)
        model.configuration.locoAddress = locoAddress
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed curve calibration").font(.title2).bold()
                Spacer()
                Button("Close") { dismiss() }.disabled(model.isRunning)
            }

            Text("This assistant modifies CV29 and CV67-CV94. Back up the decoder configuration with the existing full-CV export before continuing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("I confirm that I have backed up the decoder configuration", isOn: $model.acknowledgedBackupWarning)

            Form {
                Section("Locomotive and target curve") {
                    HStack {
                        TextField("Locomotive address", value: $model.configuration.locoAddress, format: .number)
                        TextField("Scale", value: $model.configuration.scale, format: .number)
                        TextField("Measurement length (mm)", value: $model.configuration.measurementLengthMM, format: .number)
                    }
                    HStack {
                        TextField("Minimum speed (km/h)", value: $model.configuration.minimumSpeedKPH, format: .number)
                        TextField("Maximum speed (km/h)", value: $model.configuration.maximumSpeedKPH, format: .number)
                        Picker("Curve", selection: $model.configuration.shape) {
                            ForEach(SpeedCurveShape.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    HStack {
                        Toggle("Forward", isOn: $model.configuration.directionForward)
                        TextField("Repetitions", value: $model.configuration.repetitions, format: .number)
                        TextField("Stabilization laps", value: $model.configuration.stabilizationLaps, format: .number)
                        TextField("Tolerance (km/h)", value: $model.configuration.toleranceKPH, format: .number)
                    }
                    Toggle("Activate the 28-point speed table in CV29", isOn: $model.activateSpeedTable)
                }

                Section("Z21 DETECTOR X16 10819 — R-BUS") {
                    HStack {
                        TextField("Base module address", value: $model.configuration.detectorBaseModule, format: .number)
                        TextField("Entry input (1-16)", value: $model.configuration.entryInput, format: .number)
                        TextField("Measurement input (1-16)", value: $model.configuration.measurementInput, format: .number)
                        TextField("Exit input (1-16)", value: $model.configuration.exitInput, format: .number)
                    }
                    Text("A 10819 uses two consecutive R-BUS addresses. Enter only its first module address and the physical inputs printed on the detector.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Generate preview") { model.regenerate() }.disabled(model.isRunning)
                Button("Program CV67-CV94") { model.programCurveOnly() }
                    .disabled(!model.acknowledgedBackupWarning || model.isRunning)
                Button("Start automatic calibration") { model.startAutomaticCalibration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.acknowledgedBackupWarning || model.isRunning)
                Button("Stop") { model.cancel() }.disabled(!model.isRunning)
                Spacer()
                Text(model.status).foregroundStyle(.secondary)
            }

            Table(model.points) {
                TableColumn("Point") { Text("\($0.index)") }
                TableColumn("DCC step") { Text("\($0.dccStep)") }
                TableColumn("CV") { Text("\($0.cv)") }
                TableColumn("Value") { Text("\($0.value)") }
                TableColumn("Target km/h") { Text($0.targetKPH, format: .number.precision(.fractionLength(1))) }
                TableColumn("Measured km/h") { Text($0.measuredKPH.map { String(format: "%.1f", $0) } ?? "—") }
            }
        }
        .padding(16)
        .frame(minWidth: 1050, minHeight: 720)
    }
}
