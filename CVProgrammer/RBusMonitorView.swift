import SwiftUI

struct RBusMonitorView: View {
    @StateObject private var model: RBusMonitorViewModel
    @State private var isShowingModules = false
    private let service: any RBusServicing
    private let programmingService: (any DeviceProgramming)?

    init(
        service: any RBusServicing,
        programmingService: (any DeviceProgramming)? = nil
    ) {
        _model = StateObject(
            wrappedValue: RBusMonitorViewModel(service: service)
        )
        self.service = service
        self.programmingService = programmingService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RBusMonitorHeaderView(
                model: model,
                showModules: { isShowingModules = true }
            )
            RBusMonitorLegendView()

            if let errorMessage = model.errorMessage {
                RBusMonitorErrorView(
                    message: errorMessage,
                    dismiss: model.dismissError
                )
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        RBusMonitorGroupRow(row: row)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $isShowingModules) {
            RBusModulesView(
                groups: model.groups,
                rBusService: service,
                programmingService: programmingService
            )
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .accessibilityIdentifier("rbus.monitor")
    }
}

private struct RBusMonitorHeaderView: View {
    @ObservedObject var model: RBusMonitorViewModel
    let showModules: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("R-BUS Monitor")
                    .font(.title2.bold())
                Label(connectionText, systemImage: connectionSymbol)
                    .foregroundStyle(connectionColor)
                    .accessibilityIdentifier("rbus.connection")
                if let latestUpdate {
                    Text("Last update: \(latestUpdate.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No data received")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Modules…", action: showModules)
                .accessibilityIdentifier("rbus.modules.open")

            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.connectionState != .synchronized || model.isRefreshing)
            .accessibilityIdentifier("rbus.refresh")
        }
    }

    private var latestUpdate: Date? {
        model.rows.compactMap(\.lastUpdate).max()
    }

    private var connectionText: LocalizedStringKey {
        switch model.connectionState {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .synchronized: return "Connected"
            case .degraded: return "Connection degraded"
        }
    }

    private var connectionSymbol: String {
        switch model.connectionState {
            case .synchronized: return "checkmark.circle.fill"
            case .connecting: return "ellipsis.circle"
            case .disconnected, .degraded: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
            case .synchronized: return .green
            case .connecting: return .orange
            case .disconnected, .degraded: return .red
        }
    }
}

private struct RBusMonitorLegendView: View {
    var body: some View {
        HStack(spacing: 18) {
            RBusStateLabel(state: .free, text: "Free")
            RBusStateLabel(state: .occupied, text: "Occupied")
            RBusStateLabel(state: .unknown, text: "Unknown")
        }
        .font(.caption)
    }
}

private struct RBusMonitorErrorView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(8)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("rbus.error")
    }
}

private struct RBusMonitorGroupRow: View {
    let row: RBusMonitorRowModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Address \(row.address)")
                    .font(.headline)
                if row.isStale {
                    Label("Stale", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 100, alignment: .leading)

            ForEach(row.inputs) { input in
                VStack(spacing: 3) {
                    Text("\(input.number)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: stateSymbol(input.state))
                        .foregroundStyle(stateColor(input.state))
                    Text(stateText(input.state))
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Address \(row.address), input \(input.number), \(stateAccessibilityText(input.state))")
                .accessibilityIdentifier("rbus.\(row.address).\(input.number)")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stateSymbol(_ state: FeedbackState) -> String {
        switch state {
            case .free: return "circle"
            case .occupied: return "circle.fill"
            case .unknown: return "questionmark.circle"
        }
    }

    private func stateColor(_ state: FeedbackState) -> Color {
        switch state {
            case .free: return .green
            case .occupied: return .red
            case .unknown: return .secondary
        }
    }

    private func stateText(_ state: FeedbackState) -> LocalizedStringKey {
        switch state {
            case .free: return "Free"
            case .occupied: return "Occupied"
            case .unknown: return "Unknown"
        }
    }

    private func stateAccessibilityText(_ state: FeedbackState) -> String {
        switch state {
            case .free: return String(localized: "Free")
            case .occupied: return String(localized: "Occupied")
            case .unknown: return String(localized: "Unknown")
        }
    }
}

private struct RBusStateLabel: View {
    let state: FeedbackState
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(color)
    }

    private var symbol: String {
        switch state {
            case .free: return "circle.fill"
            case .occupied: return "circle.fill"
            case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch state {
            case .free: return Color(red: 0.0, green: 0.55, blue: 0.18)
            case .occupied: return .red
            case .unknown: return .secondary
        }
    }
}
