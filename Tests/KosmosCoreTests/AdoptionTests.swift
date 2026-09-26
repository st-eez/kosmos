import Testing
@testable import KosmosCore

private func member(_ id: WindowID, parent: WindowID = 0, orderedIn: Bool = true) -> Adoption.Member {
    Adoption.Member(id: id, pid: 7, parent: parent, orderedIn: orderedIn)
}

@Suite struct AdoptionTests {
    /// 1 goes to a hidden workspace and 2 to a shown one. 3 would go hidden too, but no batch
    /// recorded it, so it is none of Kosmos's windows.
    @Test func keepsEachRecordedWindowItsAdmissionConceals() {
        let adoption = Adoption(members: [member(1), member(2), member(3)], recorded: [1, 2]) { $0.id != 2 }
        #expect(adoption.kept == [1: []])
        #expect(adoption.windows == [1])
    }

    /// A minimized window, or one hidden with its app, parks at its admission, which conceals
    /// nothing, so it comes back as any window recovery restores.
    @Test func aWindowOrderedOutComesBack() {
        let adoption = Adoption(members: [member(1, orderedIn: false)], recorded: [1]) { _ in true }
        #expect(adoption.kept.isEmpty)
    }

    /// 4 is a sheet of 1 and 5 a sheet of 4, so both stay with 1. 6 is a sheet of 2, which comes
    /// back, and 9 stands on a window that is no member, so both come back.
    @Test func sheetsStayWithTheWindowTheyStandOn() {
        let members = [member(1), member(2), member(4, parent: 1), member(5, parent: 4), member(6, parent: 2), member(9, parent: 30)]
        let adoption = Adoption(members: members, recorded: [1, 2]) { $0.id == 1 }
        #expect(adoption.kept == [1: [4, 5]])
        #expect(adoption.windows == [1, 4, 5])
    }

    @Test func aCycleOfParentsEnds() {
        let adoption = Adoption(members: [member(1), member(10, parent: 11), member(11, parent: 10)], recorded: [1]) { _ in true }
        #expect(adoption.windows == [1])
    }

    /// Once admitted, a switch reveals a window with its workspace. One never admitted, as a
    /// hung app's, is revealed with its sheets.
    @Test func onlyTheWindowsNeverAdmittedAreLeft() {
        var adoption = Adoption(members: [member(1), member(4, parent: 1), member(8)], recorded: [1, 8]) { _ in true }
        #expect(adoption.unadmitted == [1, 4, 8])
        adoption.admitted(8)
        #expect(adoption.unadmitted == [1, 4])
        adoption.admitted(1)
        #expect(adoption.unadmitted.isEmpty)
    }

    /// At the desk the saved layout shows 6, 1 and 8, and ChatGPT (20) waits on hidden 2. A
    /// window the layout lacks goes where its rule says, or to a shown workspace.
    @Test func admissionConcealsTheSavedLayoutsHiddenWindowsAndRuleWindows() {
        let session = SavedLayoutTests.restored(SavedLayoutTests.desk().savedLayout())
        #expect(session.concealsAtAdmission(20, rule: nil))
        #expect(session.concealsAtAdmission(20, rule: "1"))   // the layout wins over the rule
        #expect(!session.concealsAtAdmission(3, rule: nil))
        #expect(!session.concealsAtAdmission(3, rule: "2"))
        #expect(session.concealsAtAdmission(99, rule: "2"))
        #expect(!session.concealsAtAdmission(99, rule: "1"))
        #expect(!session.concealsAtAdmission(99, rule: nil))
        #expect(!session.concealsAtAdmission(99, rule: "no such workspace"))
    }

    /// A switch to 2 before ChatGPT is admitted shows 2 without it, and its admission plans no
    /// reveal, since a window admitted to a shown workspace is on screen already. So the
    /// controller reveals a window it took over concealed that its plan does not hide.
    @Test func aWindowTakenOverOnAWorkspaceShownSinceIsNotRevealedByItsPlan() {
        var session = SavedLayoutTests.restored(SavedLayoutTests.desk().savedLayout())
        #expect(session.perform(.workspace(.named("2")))?.show.contains(20) == false)
        let plan = session.add(20)
        #expect(session.workspace(of: 20) == "2" && session.isShown("2"))
        #expect(plan.show.isEmpty && plan.hide.isEmpty)
    }
}
