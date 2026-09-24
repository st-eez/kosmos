import CoreGraphics
import Foundation
import Testing
@testable import KosmosCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let builtIn = [BarSnapshot.Display(id: 1, name: "Built-in")]

@Test func snapshotListsEveryWorkspaceWithItsWindowsInScreenOrder() {
    var s = Session(names: ["1", "2", "3"], display: display)
    _ = s.add(10); _ = s.add(11)
    _ = s.add(20, to: "2")
    s.adopt(11)
    let apps: [WindowID: String] = [10: "Ghostty", 11: "Helium", 20: "Spotify"]
    let snapshot = s.barSnapshot(profile: "laptop", displays: builtIn, display: 1, app: { apps[$0] }, frame: { _ in nil })

    #expect(snapshot.version == 1)
    #expect(snapshot.profile == "laptop")
    #expect(snapshot.workspaces.map(\.name) == ["1", "2", "3"])
    #expect(snapshot.workspaces[0].shown && snapshot.workspaces[0].focused)
    #expect(!snapshot.workspaces[1].shown)
    #expect(snapshot.workspaces[0].windows.map(\.app) == ["Ghostty", "Helium"])   // left to right
    #expect(snapshot.workspaces[1].windows.map(\.app) == ["Spotify"])
    #expect(snapshot.workspaces[2].windows.isEmpty)
    #expect(snapshot.focused == .init(window: 11, app: "Helium", workspace: "1"))
}

@Test func floatingWindowsUseTheirOwnFrame() {
    var s = Session(names: ["1"], display: display)
    _ = s.add(10); _ = s.add(11)
    s.adopt(11)
    _ = s.perform(.layout(.toggleFloating))
    let snapshot = s.barSnapshot(profile: nil, displays: builtIn, display: 1, app: { _ in "App" },
                                 frame: { $0 == 11 ? CGRect(x: 5, y: 600, width: 100, height: 100) : nil })
    // 10 now fills the display from x = 0; the floating 11 reports its own frame.
    #expect(snapshot.workspaces[0].windows.map(\.id) == [10, 11])
    #expect(snapshot.workspaces[0].windows[1].x == 5 && snapshot.workspaces[0].windows[1].y == 600)
}

@Test func emptyWorkspaceHasNoFocus() {
    let s = Session(names: ["1"], display: display)
    #expect(s.barSnapshot(profile: nil, displays: builtIn, display: 1, app: { _ in nil }, frame: { _ in nil }).focused == nil)
}

/// The JSON a bar parses. Changing a key breaks every bar config, so this pins them.
@Test func snapshotJSONKeysAreStable() throws {
    var s = Session(names: ["1"], display: display)
    _ = s.add(10)
    let snapshot = s.barSnapshot(profile: "home", displays: builtIn, display: 1, app: { _ in "Ghostty" }, frame: { _ in nil })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    #expect(json == #"{"displays":[{"id":1,"name":"Built-in"}],"focused":{"app":"Ghostty","window":10,"workspace":"1"},"profile":"home","version":1,"workspaces":[{"display":1,"focused":true,"name":"1","shown":true,"windows":[{"app":"Ghostty","id":10,"x":0,"y":0}]}]}"#)
}

/// SketchyBar 2.24.0 numbers displays in display_arrangement (src/display.c).
@Test func displaysAreNumberedAsSketchyBarNumbersThem() {
    let managed = ["LEFT-UUID", "BUILTIN-UUID", "MAIN-UUID"]
    // Position in WindowServer's managed list plus one, whatever the active list's order.
    #expect(BarSnapshot.displayNumber(uuid: "BUILTIN-UUID", active: 3, managed: managed) == 2)
    #expect(BarSnapshot.displayNumber(uuid: "MAIN-UUID", active: 3, managed: managed) == 3)
    // A display the list lacks, or one without a UUID, gets SketchyBar's 0.
    #expect(BarSnapshot.displayNumber(uuid: "OTHER-UUID", active: 3, managed: managed) == 0)
    #expect(BarSnapshot.displayNumber(uuid: nil, active: 3, managed: managed) == 0)
    // The only active display is 1, even when the list names it "Main".
    #expect(BarSnapshot.displayNumber(uuid: "BUILTIN-UUID", active: 1, managed: ["Main"]) == 1)
}

@Test func workspacesCarryTheNumberOfTheTiledDisplay() {
    var s = Session(names: ["1", "2"], display: display)
    _ = s.add(10)
    let displays = [BarSnapshot.Display(id: 1, name: "VG279QE5A (2)"), BarSnapshot.Display(id: 2, name: "VG279QE5A (1)")]
    let snapshot = s.barSnapshot(profile: "home", displays: displays, display: 2, app: { _ in "Ghostty" }, frame: { _ in nil })
    #expect(snapshot.displays == displays)
    #expect(snapshot.workspaces.map(\.display) == [2, 2])
}
