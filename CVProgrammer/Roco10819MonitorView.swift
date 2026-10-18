import SwiftUI

struct Roco10819MonitorView: View {
    let groups: [RBusGroupState]
    @State private var baseAddress = UInt8(1)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Roco10819Profile.displayName)
                .font(.title2.bold())

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
