import Foundation

enum RBusModuleProfile: String, CaseIterable, Identifiable, Sendable {
    case roco10819
    case roco10808
    case roco10787

    var id: String { rawValue }

    var displayName: String {
        switch self {
            case .roco10819: return Roco10819Profile.displayName
            case .roco10808: return "Roco 10808 Z21 Detector"
            case .roco10787: return "Roco 10787 Feedback Module"
        }
    }

    var inputCount: Int {
        switch self {
            case .roco10819: return 16
            case .roco10808, .roco10787: return 8
        }
    }

    var addressCount: Int {
        switch self {
            case .roco10819: return 2
            case .roco10808, .roco10787: return 1
        }
    }

    var supportsRBusAddressProgramming: Bool {
        self != .roco10819
    }
}

struct RBusModuleInputState: Identifiable, Equatable, Sendable {
    let number: UInt8
    let state: FeedbackState
    let isStale: Bool

    var id: UInt8 { number }
}

enum RBusModuleSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress(UInt8)

    var errorDescription: String? {
        switch self {
            case .invalidAddress(let address):
                return "R-BUS address \(address) is invalid. Use an address from 1 through 20."
        }
    }
}

struct RBusModuleSnapshot: Equatable, Sendable {
    let address: UInt8
    let inputs: [RBusModuleInputState]

    init(address: UInt8, groups: [RBusGroupState]) throws {
        guard (1...20).contains(address) else {
            throw RBusModuleSnapshotError.invalidAddress(address)
        }

        self.address = address
        let group = groups.first { $0.address == address }
        inputs = (0..<8).map { offset in
            let value = group?.inputs[safe: offset]
                ?? FeedbackValue(state: .unknown, isStale: false)
            return RBusModuleInputState(
                number: UInt8(offset + 1),
                state: value.effectiveState,
                isStale: value.isStale
            )
        }
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
