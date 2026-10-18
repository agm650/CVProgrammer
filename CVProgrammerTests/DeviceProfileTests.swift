import Foundation
import Testing
@testable import CVProgrammer

struct DeviceProfileTests {
    @Test
    func createsValidProfile() throws {
        let parameter = try makeParameter()
        let profile = try DeviceProfile(
            id: "sample",
            manufacturer: "Example",
            model: "Detector",
            programmingMode: .pomLocomotive,
            pseudoAddress: 9_819,
            parameters: [parameter]
        )

        #expect(profile.id == "sample")
        #expect(profile.parameters == [parameter])
        #expect(profile.pseudoAddress == 9_819)
    }

    @Test(arguments: [UInt16(0), UInt16(1_025)])
    func rejectsCVOutsideSupportedRange(_ cv: UInt16) {
        #expect(throws: DeviceProfileValidationError.invalidCV(cv)) {
            try DeviceParameter(
                id: "invalid-cv",
                name: "Invalid CV",
                cv: cv,
                minimum: 0,
                maximum: 255,
                isReadSupported: false
            )
        }
    }

    @Test
    func rejectsValueOutsideParameterRange() throws {
        let parameter = try makeParameter()

        #expect(
            throws: DeviceProfileValidationError.valueOutOfRange(
                parameterID: parameter.id,
                value: 11,
                minimum: 1,
                maximum: 10
            )
        ) {
            try parameter.validate(11)
        }
    }

    @Test
    func reportsMissingParameter() throws {
        let profile = try makeProfile()

        #expect(
            throws: DeviceProfileValidationError.parameterNotFound("missing")
        ) {
            try profile.parameter(id: "missing")
        }
    }

    @Test
    func exposesReadSupport() throws {
        let readable = try makeParameter(isReadSupported: true)
        let writeOnly = try makeParameter(
            id: "write-only",
            isReadSupported: false
        )

        #expect(readable.isReadSupported)
        #expect(!writeOnly.isReadSupported)
    }

    @Test
    func retainsProgrammingMode() throws {
        let serviceMode = try makeProfile(mode: .serviceMode)
        let locomotivePOM = try makeProfile(mode: .pomLocomotive)
        let accessoryPOM = try makeProfile(mode: .pomAccessory)

        #expect(serviceMode.programmingMode == .serviceMode)
        #expect(locomotivePOM.programmingMode == .pomLocomotive)
        #expect(accessoryPOM.programmingMode == .pomAccessory)
    }

    @Test
    func programmingTargetsUseDistinctAddressTypes() throws {
        let locomotive = ProgrammingTarget.locomotive(
            address: LocomotiveAddress(rawValue: 3)
        )
        let accessory = ProgrammingTarget.accessory(
            address: try AccessoryAddress(3)
        )
        let profile = ProgrammingTarget.deviceProfile(try makeProfile())

        #expect(locomotive != accessory)
        if case .deviceProfile(let storedProfile) = profile {
            #expect(storedProfile.id == "sample")
        } else {
            Issue.record("Expected a device profile target")
        }
    }

    @Test
    func serializesAndDeserializesProfile() throws {
        let profile = try makeProfile()
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(DeviceProfile.self, from: encoded)

        #expect(decoded == profile)
    }

    @Test
    func decodedProfilesAreValidated() throws {
        let invalidJSON = Data(#"""
        {
          "id": "invalid",
          "manufacturer": "Example",
          "model": "Detector",
          "programmingMode": "pomLocomotive",
          "parameters": [{
            "id": "bad",
            "name": "Bad",
            "cv": 0,
            "minimum": 0,
            "maximum": 255,
            "isReadSupported": false
          }]
        }
        """#.utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DeviceProfile.self, from: invalidJSON)
        }
    }

    private func makeProfile(
        mode: ProgrammingMode = .pomLocomotive
    ) throws -> DeviceProfile {
        try DeviceProfile(
            id: "sample",
            manufacturer: "Example",
            model: "Detector",
            programmingMode: mode,
            pseudoAddress: 9_819,
            parameters: [try makeParameter()]
        )
    }

    private func makeParameter(
        id: String = "threshold",
        isReadSupported: Bool = true
    ) throws -> DeviceParameter {
        try DeviceParameter(
            id: id,
            name: "Threshold",
            cv: 100,
            minimum: 1,
            maximum: 10,
            unit: "level",
            help: "Detection threshold.",
            isReadSupported: isReadSupported
        )
    }
}
