import Testing
@testable import KosmosCore

/// RustDesk's remote desktop process, an LSUIElement app whose window was read while it was
/// an accessory, before it became regular.
@Test func anAppThatBecomesRegularHasItsWindowsSweptFor() {
    var apps = RegularApps()
    #expect(apps.record(7, regular: false) == .none)
    #expect(apps[7] == false)
    #expect(apps.record(7, regular: true) == .becameRegular)
    #expect(apps[7] == true)
    #expect(apps.record(7, regular: true) == .none)
}

/// No window of a process read regular at its first window was left out.
@Test func anAppFirstReadRegularNeedsNoSweep() {
    var apps = RegularApps()
    #expect(apps[7] == nil)
    #expect(apps.record(7, regular: true) == .none)
    #expect(apps[7] == true)
    #expect(apps.record(7, regular: true) == .none)
}

/// A process that is not regular, such as a prohibited one becoming an accessory as it
/// launches (`kosmos-probe policy`), changes nothing.
@Test func aChangeBetweenPoliciesThatAreNotRegularChangesNothing() {
    var apps = RegularApps()
    #expect(apps.record(7, regular: false) == .none)
    #expect(apps.record(7, regular: false) == .none)
    #expect(apps[7] == false)
}

/// Its new windows are left out while it is not regular, and swept for when it is again.
@Test func anAppThatStopsBeingRegularIsFollowedBack() {
    var apps = RegularApps()
    _ = apps.record(7, regular: true)
    #expect(apps.record(7, regular: false) == .leftRegular)
    #expect(apps[7] == false)
    #expect(apps.record(7, regular: true) == .becameRegular)
}

/// A new process with the pid of one that exited starts with no policy recorded, so the old
/// process's windows left out call for no sweep.
@Test func anExitForgetsThePolicy() {
    var apps = RegularApps()
    _ = apps.record(7, regular: false)
    apps.forget(7)
    #expect(apps[7] == nil)
    #expect(apps.record(7, regular: true) == .none)
}
