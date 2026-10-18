import Foundation

enum FeedbackState: Equatable, Sendable {
    case unknown
    case free
    case occupied
}

struct RBusGroupState: Equatable, Sendable {
    let address: UInt8
    var inputs: [FeedbackState]
    var lastUpdate: Date?

    init(address: UInt8) {
        self.address = address
        inputs = Array(repeating: .unknown, count: 8)
        lastUpdate = nil
    }
}

struct RBusFeedbackInput: Equatable, Sendable {
    let rBusAddress: UInt8
    let input: UInt8
    let state: FeedbackState
}

struct RBusGroupSnapshot: Equatable, Sendable {
    let address: UInt8
    let inputs: [RBusFeedbackInput]

    init(address: UInt8, statusByte: UInt8) {
        self.address = address
        inputs = (0..<8).map { bitIndex in
            RBusFeedbackInput(
                rBusAddress: address,
                input: UInt8(bitIndex + 1),
                state: statusByte & (1 << bitIndex) == 0
                    ? .free
                    : .occupied
            )
        }
    }
}
