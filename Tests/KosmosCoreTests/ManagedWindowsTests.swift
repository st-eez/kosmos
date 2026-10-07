import Testing
@testable import KosmosCore

/// An app's "float on top" moves its window off level 0, and the window then closes: its tile
/// would stay as an empty gap without the report.
@Test func aManagedWindowThatLeftLevelZeroIsReportedAtItsRemoval() {
    var managed = ManagedWindows()
    let admitted = managed.read(7, standard: true, candidate: true)
    let floated = managed.read(7, standard: true, candidate: false)
    let removed = managed.removed(7)
    let again = managed.removed(7)
    #expect(admitted == true)
    #expect(floated == nil)
    #expect(removed)
    #expect(!again)
}

/// Back at level 0 it is still managed, so it is not admitted a second time.
@Test func aManagedWindowBackAtLevelZeroIsNotReportedAgain() {
    var managed = ManagedWindows()
    _ = managed.read(7, standard: true, candidate: true)
    let floated = managed.read(7, standard: true, candidate: false)
    let back = managed.read(7, standard: true, candidate: true)
    #expect(floated == nil)
    #expect(back == nil)
}

/// A read that lands after the window left level 0 waits for the read at its return.
@Test func aStandardWindowIsManagedOnlyOnceItIsACandidate() {
    var managed = ManagedWindows()
    let floating = managed.read(7, standard: true, candidate: false)
    let back = managed.read(7, standard: true, candidate: true)
    #expect(floating == nil)
    #expect(back == true)
}

/// A window that reports another subrole, as a dialog, stops being managed once.
@Test func aWindowThatStopsBeingStandardIsReportedOnce() {
    var managed = ManagedWindows()
    let dialog = managed.read(7, standard: false, candidate: true)
    _ = managed.read(7, standard: true, candidate: true)
    let left = managed.read(7, standard: false, candidate: true)
    let again = managed.read(7, standard: false, candidate: true)
    let removed = managed.removed(7)
    #expect(dialog == nil)
    #expect(left == false)
    #expect(again == nil)
    #expect(!removed)
}
