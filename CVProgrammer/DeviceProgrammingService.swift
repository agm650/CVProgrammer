import Foundation

protocol Z21CommandSending: Sendable {
    func send(_ command: Z21Command) async throws
}

extension Z21Session: Z21CommandSending {}

protocol DeviceProgramming: Sendable {
    func write(
        parameter: DeviceParameter,
        value: UInt8,
        profile: DeviceProfile
    ) async throws
}

enum DeviceProgrammingError: Error, Equatable, LocalizedError, Sendable {
    case parameterDoesNotBelongToProfile(String)
    case missingPseudoAddress
    case unsupportedProgrammingMode(ProgrammingMode)

    var errorDescription: String? {
        switch self {
            case .parameterDoesNotBelongToProfile(let id):
                return "Parameter \(id) does not belong to this device profile."
            case .missingPseudoAddress:
                return "This device profile has no POM pseudo-address."
            case .unsupportedProgrammingMode(let mode):
                return "Programming mode \(mode.rawValue) is not supported by this service."
        }
    }
}

struct Z21DeviceProgrammingService: DeviceProgramming {
    private let commandSender: any Z21CommandSending

    init(commandSender: any Z21CommandSending) {
        self.commandSender = commandSender
    }

    func write(
        parameter: DeviceParameter,
        value: UInt8,
        profile: DeviceProfile
    ) async throws {
        let profileParameter: DeviceParameter
        do {
            profileParameter = try profile.parameter(id: parameter.id)
        } catch {
            throw DeviceProgrammingError.parameterDoesNotBelongToProfile(
                parameter.id
            )
        }
        guard profileParameter == parameter else {
            throw DeviceProgrammingError.parameterDoesNotBelongToProfile(
                parameter.id
            )
        }
        try profileParameter.validate(value)

        guard profile.programmingMode == .pomLocomotive else {
            throw DeviceProgrammingError.unsupportedProgrammingMode(
                profile.programmingMode
            )
        }
        guard let pseudoAddress = profile.pseudoAddress else {
            throw DeviceProgrammingError.missingPseudoAddress
        }

        try await commandSender.send(
            .pomWriteByte(
                locomotiveAddress: pseudoAddress,
                cvAddress: profileParameter.cv - 1,
                value: value
            )
        )
    }
}
