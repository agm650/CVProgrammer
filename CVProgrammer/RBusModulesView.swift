import SwiftUI

struct RBusModulesView: View {
    let groups: [RBusGroupState]
    let rBusService: any RBusServicing
    let programmingService: (any DeviceProgramming)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfile: RBusModuleProfile?

    var body: some View {
        Group {
            if let selectedProfile {
                moduleView(for: selectedProfile)
            } else {
                modulePicker
            }
        }
        .frame(minWidth: 700, minHeight: 340)
    }

    private var modulePicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("R-BUS Modules")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text("Choose the module to monitor or program.")
                .foregroundStyle(.secondary)

            ForEach(RBusModuleProfile.allCases) { profile in
                Button {
                    selectedProfile = profile
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(.headline)
                            Text("\(profile.inputCount) inputs · \(profile.addressCount) R-BUS address(es)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("rbus.module.\(profile.id)")
            }

            Spacer()
        }
        .padding()
        .accessibilityIdentifier("rbus.modules")
    }

    @ViewBuilder
    private func moduleView(for profile: RBusModuleProfile) -> some View {
        switch profile {
            case .roco10819:
                Roco10819MonitorView(
                    groups: groups,
                    programmingService: programmingService,
                    showModules: { selectedProfile = nil }
                )
            case .roco10808, .roco10787:
                RBusEightInputModuleView(
                    profile: profile,
                    groups: groups,
                    service: rBusService,
                    showModules: { selectedProfile = nil }
                )
        }
    }
}

private struct RBusEightInputModuleView: View {
    let profile: RBusModuleProfile
    let groups: [RBusGroupState]
    let service: any RBusServicing
    let showModules: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = UInt8(1)
    @State private var isProgramming = false
    @State private var isSending = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Modules", action: showModules)
                Text(profile.displayName)
                    .font(.title2.bold())
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }

            Picker("R-BUS address", selection: $address) {
                ForEach(UInt8(1)...UInt8(20), id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .frame(maxWidth: 260)
            .disabled(isProgramming)

            if let snapshot {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: 8
                    ),
                    spacing: 12
                ) {
                    ForEach(snapshot.inputs) { input in
                        RBusModuleInputView(input: input, profile: profile)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Address Programming")
                    .font(.headline)
                Label(
                    "Connect only the module being programmed to the R-BUS.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)

                HStack {
                    Button("Start Address Programming") { startProgramming() }
                        .disabled(isProgramming || isSending)
                    Button("Stop Programming") { stopProgramming() }
                        .disabled(!isProgramming || isSending)
                }

                Text("The Z21 keeps sending the programming command until you stop it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let resultMessage {
                    Text(resultMessage)
                        .font(.caption)
                }
            }

            Spacer()
        }
        .padding()
        .onDisappear {
            guard isProgramming else { return }
            Task { try? await service.stopModuleAddressProgramming() }
        }
        .accessibilityIdentifier("rbus.module.\(profile.id).monitor")
    }

    private var snapshot: RBusModuleSnapshot? {
        try? RBusModuleSnapshot(address: address, groups: groups)
    }

    private func startProgramming() {
        isSending = true
        resultMessage = nil
        Task {
            do {
                try await service.startModuleAddressProgramming(address: address)
                isProgramming = true
                resultMessage = String(localized: "Address programming started for R-BUS address \(address).")
            } catch {
                resultMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private func stopProgramming() {
        isSending = true
        Task {
            do {
                try await service.stopModuleAddressProgramming()
                isProgramming = false
                resultMessage = String(localized: "Address programming stopped.")
            } catch {
                resultMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private func close() {
        guard isProgramming else {
            dismiss()
            return
        }

        isSending = true
        Task {
            try? await service.stopModuleAddressProgramming()
            isProgramming = false
            dismiss()
        }
    }
}

private struct RBusModuleInputView: View {
    let input: RBusModuleInputState
    let profile: RBusModuleProfile

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
        .accessibilityIdentifier("rbus.module.\(profile.id).input.\(input.number)")
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
        String(localized: "Input \(input.number): \(localizedState)")
    }

    private var localizedState: String {
        switch input.state {
            case .free: return String(localized: "Free")
            case .occupied: return String(localized: "Occupied")
            case .unknown: return String(localized: "Unknown")
        }
    }
}
