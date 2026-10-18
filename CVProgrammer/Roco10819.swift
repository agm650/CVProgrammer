import Foundation

enum Roco10819ValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseAddress(UInt8)

    var errorDescription: String? {
        switch self {
            case .invalidBaseAddress(let address):
                return "R-BUS base address \(address) is invalid. Use an address from 1 through 19."
        }
    }
}

struct Roco10819InputState: Identifiable, Equatable, Sendable {
    let number: UInt8
    let state: FeedbackState
    let isStale: Bool

    var id: UInt8 { number }
}

struct Roco10819Snapshot: Equatable, Sendable {
    let baseAddress: UInt8
    let inputs: [Roco10819InputState]

    init(baseAddress: UInt8, groups: [RBusGroupState]) throws {
        guard (1...19).contains(baseAddress) else {
            throw Roco10819ValidationError.invalidBaseAddress(baseAddress)
        }

        self.baseAddress = baseAddress
        let groupsByAddress = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.address, $0) }
        )
        inputs = (0..<16).map { offset in
            let groupAddress = baseAddress + UInt8(offset / 8)
            let inputIndex = offset % 8
            let value = groupsByAddress[groupAddress]?
                .inputs[safe: inputIndex]
                ?? FeedbackValue(state: .unknown, isStale: false)
            return Roco10819InputState(
                number: UInt8(offset + 1),
                state: value.effectiveState,
                isStale: value.isStale
            )
        }
    }
}

enum Roco10819Profile {
    static let displayName = "Roco 10819 Z21 Detector X16"

    static func makeDeviceProfile() throws -> DeviceProfile {
        try DeviceProfile(
            id: "roco-10819",
            manufacturer: "Roco",
            model: "10819 Z21 Detector X16",
            programmingMode: .pomLocomotive,
            pseudoAddress: 9_819,
            parameters: [
                try DeviceParameter(
                    id: "rbus-address",
                    name: "R-BUS Address",
                    cv: 99,
                    minimum: 1,
                    maximum: 19,
                    help: "Base address used for inputs 1 through 8. The next address is used for inputs 9 through 16.",
                    isReadSupported: false
                ),
                try DeviceParameter(
                    id: "threshold",
                    name: "Detection Threshold",
                    cv: 100,
                    minimum: 0,
                    maximum: 70,
                    unit: "mA",
                    help: "0 selects 0.5 mA; values 1 through 70 select the corresponding current in mA.",
                    isReadSupported: false
                ),
                try DeviceParameter(
                    id: "response-time",
                    name: "Response Time",
                    cv: 101,
                    minimum: 0,
                    maximum: 16,
                    unit: "10 ms",
                    help: "0 and 1 select 10 ms; values 2 through 16 select 20 through 160 ms.",
                    isReadSupported: false
                ),
                try DeviceParameter(
                    id: "release-delay",
                    name: "Release Delay",
                    cv: 102,
                    minimum: 0,
                    maximum: 255,
                    unit: "10 ms",
                    help: "Delay before a clear section is reported, from 0 through 2550 ms.",
                    isReadSupported: false
                )
            ]
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
