import Testing
@testable import KosmosRecovery

private func member(_ id: UInt32, parent: UInt32 = 0, orderedIn: Bool = true) -> Adoption.Member {
    Adoption.Member(id: id, parent: parent, orderedIn: orderedIn)
}

@Suite struct AdoptionTests {
    /// Admission reveals the ones whose workspace shows. 3 was never recorded, so it is none of
    /// Kosmos's windows.
    @Test func keepsEachRecordedWindow() {
        let adoption = Adoption(members: [member(1), member(2), member(3)], recorded: [1, 2])
        #expect(adoption.kept == [1: [], 2: []])
        #expect(adoption.windows == [1, 2])
    }

    /// A minimized window, or one hidden with its app, parks at its admission, which conceals
    /// nothing, so it comes back as any window recovery restores.
    @Test func aWindowOrderedOutComesBack() {
        let adoption = Adoption(members: [member(1, orderedIn: false)], recorded: [1])
        #expect(adoption.kept.isEmpty)
    }

    /// 4 is a sheet of 1 and 5 a sheet of 4, so both stay with 1. 6 is a sheet of 2, which is
    /// ordered out and comes back, and 9 stands on a window that is no member, so both come back.
    @Test func sheetsStayWithTheWindowTheyStandOn() {
        let members = [member(1), member(2, orderedIn: false), member(4, parent: 1), member(5, parent: 4), member(6, parent: 2),
                       member(9, parent: 30)]
        let adoption = Adoption(members: members, recorded: [1, 2])
        #expect(adoption.kept == [1: [4, 5]])
        #expect(adoption.windows == [1, 4, 5])
    }

    @Test func aCycleOfParentsEnds() {
        let adoption = Adoption(members: [member(1), member(10, parent: 11), member(11, parent: 10)], recorded: [1])
        #expect(adoption.windows == [1])
    }

    /// Once admitted, a switch reveals a window with its workspace. One never admitted, as a
    /// hung app's, is revealed with its sheets.
    @Test func onlyTheWindowsNeverAdmittedAreLeft() {
        var adoption = Adoption(members: [member(1), member(4, parent: 1), member(8)], recorded: [1, 8])
        #expect(adoption.unadmitted == [1, 4, 8])
        adoption.admitted(8)
        #expect(adoption.unadmitted == [1, 4])
        adoption.admitted(1)
        #expect(adoption.unadmitted.isEmpty)
    }
}
