import SwiftUI

struct Roco10819MonitorView: View {
    let groups: [RBusGroupState]
    let programmingService: (any DeviceProgramming)?
    let showModules: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var baseAddress = UInt8(1)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Modules", action: showModules)
                Text(Roco10819Profile.displayName)
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("roco10819.close")
            }

            Picker("R-BUS base address", selection: $baseAddress) {
                ForEach(UInt8(1)...UInt8(19), id: \.self) { address in
                    Text("\(address)").tag(address)
                }
            }
            .frame(maxWidth: 260)
            .accessibilityIdentifier("roco10819.baseAddress")

            Text("Inputs 1–8 use R-BUS address \(baseAddress); inputs 9–16 use address \(baseAddress + 1).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let snapshot {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: 8
                    ),
                    spacing: 12
                ) {
                    ForEach(snapshot.inputs) { input in
                        Roco10819InputView(input: input)
                    }
                }
            }

            if let programmingService,
               let profile = try? Roco10819Profile.makeDeviceProfile() {
                Divider()
                Roco10819ProgrammingView(
                    profile: profile,
                    service: programmingService
                )
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 700, minHeight: 300)
        .accessibilityIdentifier("roco10819.monitor")
    }

    private var snapshot: Roco10819Snapshot? {
        try? Roco10819Snapshot(baseAddress: baseAddress, groups: groups)
    }
}

private struct Roco10819ProgrammingView: View {
    let profile: DeviceProfile
    let service: any DeviceProgramming

    @State private var selectedParameterID: String
    @State private var value: Int
    @State private var isWriting = false
    @State private var resultMessage: String?

    init(profile: DeviceProfile, service: any DeviceProgramming) {
        self.profile = profile
        self.service = service
        let initialParameter = profile.parameters.first
        _selectedParameterID = State(initialValue: initialParameter?.id ?? "")
        _value = State(initialValue: Int(initialParameter?.minimum ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Programming")
                .font(.headline)
            Label(
                "Put the 10819 into programming mode before writing.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)

            Text("Keep R-BUS addresses continuous from 1. The 10819 occupies the selected base address and the following address; make sure neither is already assigned to another module.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let parameter {
                HStack {
                    Picker("Parameter", selection: $selectedParameterID) {
                        ForEach(profile.parameters) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .frame(maxWidth: 300)
                    .onChange(of: selectedParameterID) { _ in
                        value = Int(self.parameter?.minimum ?? 0)
                        resultMessage = nil
                    }

                    Stepper(
                        value: $value,
                        in: Int(parameter.minimum)...Int(parameter.maximum)
                    ) {
                        Text("Value: \(value)\(unitSuffix(for: parameter))")
                    }

                    Button("Write") {
                        write(parameter)
                    }
                    .disabled(isWriting)
                    .accessibilityIdentifier("roco10819.write")
                }

                if let help = parameter.help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !parameter.isReadSupported {
                    Text("Reading this parameter is not supported; a successful send does not confirm the value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .accessibilityIdentifier("roco10819.programmingResult")
            }
        }
    }

    private var parameter: DeviceParameter? {
        try? profile.parameter(id: selectedParameterID)
    }

    private func unitSuffix(for parameter: DeviceParameter) -> String {
        parameter.unit.map { " \($0)" } ?? ""
    }

    private func write(_ parameter: DeviceParameter) {
        isWriting = true
        resultMessage = nil
        Task {
            do {
                try await service.write(
                    parameter: parameter,
                    value: UInt8(value),
                    profile: profile
                )
                resultMessage = String(localized: "Write command sent.")
            } catch {
                resultMessage = error.localizedDescription
            }
            isWriting = false
        }
    }
}

private struct Roco10819InputView: View {
    let input: Roco10819InputState

    var body: some View {
        VStack(spacing: 5) {
            Text("Input \(input.number)")
                .font(.caption)
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
            Text(stateText)
                .font(.caption2)
            if input.isStale {
                Text("Stale")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("roco10819.input.\(input.number)")
    }

    private var symbol: String {
        switch input.state {
            case .free: return "circle"
            case .occupied: return "circle.fill"
            case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch input.state {
            case .free: return .green
            case .occupied: return .red
            case .unknown: return .secondary
        }
    }

    private var stateText: LocalizedStringKey {
        switch input.state {
            case .free: return "Free"
            case .occupied: return "Occupied"
            case .unknown: return "Unknown"
        }
    }

    private var accessibilityText: String {
        let state: String
        switch input.state {
            case .free: state = String(localized: "Free")
            case .occupied: state = String(localized: "Occupied")
            case .unknown: state = String(localized: "Unknown")
        }
        return String(
            localized: "Input \(input.number): \(state)"
        )
    }
}
