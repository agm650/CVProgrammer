import Testing
@testable import CVProgrammer

struct Roco10819Tests {
    @Test
    func mapsInputOneFromBaseAddressBitZero() throws {
        let snapshot = try makeSnapshot(
            baseAddress: 1,
            firstStatuses: [FeedbackValue(state: .occupied, isStale: false)]
        )

        #expect(snapshot.inputs[0].number == 1)
        #expect(snapshot.inputs[0].state == .occupied)
    }

    @Test
    func mapsInputEightFromBaseAddressBitSeven() throws {
        var first = unknownInputs
        first[7] = FeedbackValue(state: .free, isStale: false)
        let snapshot = try makeSnapshot(baseAddress: 1, firstStatuses: first)

        #expect(snapshot.inputs[7].number == 8)
        #expect(snapshot.inputs[7].state == .free)
    }

    @Test
    func mapsInputNineFromSecondAddressBitZero() throws {
        let snapshot = try makeSnapshot(
            baseAddress: 1,
            secondStatuses: [FeedbackValue(state: .occupied, isStale: false)]
        )

        #expect(snapshot.inputs[8].number == 9)
        #expect(snapshot.inputs[8].state == .occupied)
    }

    @Test
    func mapsInputSixteenFromSecondAddressBitSeven() throws {
        var second = unknownInputs
        second[7] = FeedbackValue(state: .free, isStale: false)
        let snapshot = try makeSnapshot(baseAddress: 1, secondStatuses: second)

        #expect(snapshot.inputs[15].number == 16)
        #expect(snapshot.inputs[15].state == .free)
    }

    @Test(arguments: [UInt8(1), UInt8(19)])
    func acceptsValidBaseAddresses(_ baseAddress: UInt8) throws {
        let snapshot = try Roco10819Snapshot(
            baseAddress: baseAddress,
            groups: makeGroups(baseAddress: baseAddress)
        )

        #expect(snapshot.baseAddress == baseAddress)
        #expect(snapshot.inputs.count == 16)
    }

    @Test
    func rejectsBaseAddressTwenty() {
        #expect(
            throws: Roco10819ValidationError.invalidBaseAddress(20)
        ) {
            try Roco10819Snapshot(baseAddress: 20, groups: [])
        }
    }

    @Test
    func propagatesUnknownState() throws {
        let snapshot = try makeSnapshot(baseAddress: 1)
        #expect(snapshot.inputs[0].state == .unknown)
    }

    @Test
    func propagatesStaleStateAsUnknown() throws {
        let snapshot = try makeSnapshot(
            baseAddress: 1,
            firstStatuses: [
                FeedbackValue(state: .occupied, isStale: true)
            ]
        )

        #expect(snapshot.inputs[0].state == .unknown)
        #expect(snapshot.inputs[0].isStale)
    }

    @Test
    func definesRoco10819Profile() throws {
        let profile = try Roco10819Profile.makeDeviceProfile()

        #expect(profile.id == "roco-10819")
        #expect(profile.manufacturer == "Roco")
        #expect(profile.model == "10819 Z21 Detector X16")
        #expect(profile.programmingMode == .pomLocomotive)
        #expect(profile.pseudoAddress == 9_819)
    }

    private var unknownInputs: [FeedbackValue] {
        Array(
            repeating: FeedbackValue(state: .unknown, isStale: false),
            count: 8
        )
    }

    private func makeSnapshot(
        baseAddress: UInt8,
        firstStatuses: [FeedbackValue] = [],
        secondStatuses: [FeedbackValue] = []
    ) throws -> Roco10819Snapshot {
        try Roco10819Snapshot(
            baseAddress: baseAddress,
            groups: makeGroups(
                baseAddress: baseAddress,
                firstStatuses: firstStatuses,
                secondStatuses: secondStatuses
            )
        )
    }

    private func makeGroups(
        baseAddress: UInt8,
        firstStatuses: [FeedbackValue] = [],
        secondStatuses: [FeedbackValue] = []
    ) -> [RBusGroupState] {
        var first = RBusGroupState(address: baseAddress)
        for (index, value) in firstStatuses.enumerated()
            where first.inputs.indices.contains(index) {
            first.inputs[index] = value
        }

        var second = RBusGroupState(address: baseAddress + 1)
        for (index, value) in secondStatuses.enumerated()
            where second.inputs.indices.contains(index) {
            second.inputs[index] = value
        }
        return [first, second]
    }
}
