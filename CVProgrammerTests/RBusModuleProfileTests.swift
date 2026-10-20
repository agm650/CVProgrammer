import Testing
@testable import CVProgrammer

struct RBusModuleProfileTests {
    @Test
    func definesSupportedProfiles() {
        #expect(RBusModuleProfile.allCases == [.roco10819, .roco10808, .roco10787])
        #expect(RBusModuleProfile.roco10819.inputCount == 16)
        #expect(RBusModuleProfile.roco10819.addressCount == 2)
        #expect(!RBusModuleProfile.roco10819.supportsRBusAddressProgramming)
        #expect(RBusModuleProfile.roco10808.inputCount == 8)
        #expect(RBusModuleProfile.roco10787.inputCount == 8)
        #expect(RBusModuleProfile.roco10808.supportsRBusAddressProgramming)
        #expect(RBusModuleProfile.roco10787.supportsRBusAddressProgramming)
    }

    @Test
    func mapsEightInputModuleState() throws {
        var group = RBusGroupState(address: 20)
        group.inputs[0] = FeedbackValue(state: .occupied, isStale: false)
        group.inputs[7] = FeedbackValue(state: .free, isStale: true)

        let snapshot = try RBusModuleSnapshot(address: 20, groups: [group])

        #expect(snapshot.inputs.count == 8)
        #expect(snapshot.inputs[0].state == .occupied)
        #expect(snapshot.inputs[7].state == .unknown)
        #expect(snapshot.inputs[7].isStale)
    }

    @Test(arguments: [UInt8(0), UInt8(21)])
    func rejectsInvalidAddress(_ address: UInt8) {
        #expect(throws: RBusModuleSnapshotError.invalidAddress(address)) {
            try RBusModuleSnapshot(address: address, groups: [])
        }
    }
}
