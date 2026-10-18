import Testing
@testable import CVProgrammer

struct Roco10819ProgrammingTests {
    @Test(
        arguments: [
            (id: "rbus-address", cv: UInt16(99), value: UInt8(19)),
            (id: "threshold", cv: UInt16(100), value: UInt8(70)),
            (id: "response-time", cv: UInt16(101), value: UInt8(16)),
            (id: "release-delay", cv: UInt16(102), value: UInt8(255))
        ]
    )
    func writesEachParameterToPseudoAddress(
        argument: (id: String, cv: UInt16, value: UInt8)
    ) async throws {
        let sender = RecordingZ21CommandSender()
        let service = Z21DeviceProgrammingService(commandSender: sender)
        let profile = try Roco10819Profile.makeDeviceProfile()
        let parameter = try profile.parameter(id: argument.id)

        try await service.write(
            parameter: parameter,
            value: argument.value,
            profile: profile
        )

        #expect(
            await sender.commands == [
                .pomWriteByte(
                    locomotiveAddress: 9_819,
                    cvAddress: argument.cv - 1,
                    value: argument.value
                )
            ]
        )
    }

    @Test
    func thresholdTwoUsesCV100AtAddress9819() async throws {
        let sender = RecordingZ21CommandSender()
        let service = Z21DeviceProgrammingService(commandSender: sender)
        let profile = try Roco10819Profile.makeDeviceProfile()
        let threshold = try profile.parameter(id: "threshold")

        try await service.write(
            parameter: threshold,
            value: 2,
            profile: profile
        )

        #expect(
            await sender.commands == [
                .pomWriteByte(
                    locomotiveAddress: 9_819,
                    cvAddress: 99,
                    value: 2
                )
            ]
        )
    }

    @Test(
        arguments: [
            (id: "rbus-address", value: UInt8(20)),
            (id: "threshold", value: UInt8(71)),
            (id: "response-time", value: UInt8(17))
        ]
    )
    func rejectsInvalidParameterValues(
        argument: (id: String, value: UInt8)
    ) async throws {
        let sender = RecordingZ21CommandSender()
        let service = Z21DeviceProgrammingService(commandSender: sender)
        let profile = try Roco10819Profile.makeDeviceProfile()
        let parameter = try profile.parameter(id: argument.id)

        await #expect(throws: DeviceProfileValidationError.self) {
            try await service.write(
                parameter: parameter,
                value: argument.value,
                profile: profile
            )
        }
        #expect(await sender.commands.isEmpty)
    }

    @Test
    func allParametersAreWriteOnly() throws {
        let profile = try Roco10819Profile.makeDeviceProfile()

        #expect(profile.parameters.count == 4)
        #expect(profile.parameters.allSatisfy { !$0.isReadSupported })
    }
}

private actor RecordingZ21CommandSender: Z21CommandSending {
    private(set) var commands: [Z21Command] = []

    func send(_ command: Z21Command) {
        commands.append(command)
    }
}
