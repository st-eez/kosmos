import CoreGraphics
import Foundation
import Testing
@testable import KosmosCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Test func snapshotListsEveryWorkspaceWithItsWindowsInScreenOrder() {
    var s = Session(names: ["1", "2", "3"], display: display)
    _ = s.add(10); _ = s.add(11)
    _ = s.add(20, to: "2")
    s.adopt(11)
    let apps: [WindowID: String] = [10: "Ghostty", 11: "Helium", 20: "Spotify"]
    let snapshot = s.barSnapshot(profile: "laptop", displayName: "Built-in", app: { apps[$0] }, frame: { _ in nil })

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
    let snapshot = s.barSnapshot(profile: nil, displayName: "Built-in", app: { _ in "App" },
                                 frame: { $0 == 11 ? CGRect(x: 5, y: 600, width: 100, height: 100) : nil })
    // 10 now fills the display from x = 0; the floating 11 reports its own frame.
    #expect(snapshot.workspaces[0].windows.map(\.id) == [10, 11])
    #expect(snapshot.workspaces[0].windows[1].x == 5 && snapshot.workspaces[0].windows[1].y == 600)
}

@Test func emptyWorkspaceHasNoFocus() {
    let s = Session(names: ["1"], display: display)
    #expect(s.barSnapshot(profile: nil, displayName: "Built-in", app: { _ in nil }, frame: { _ in nil }).focused == nil)
}

/// The JSON a bar parses. Changing a key breaks every bar config, so this pins them.
@Test func snapshotJSONKeysAreStable() throws {
    var s = Session(names: ["1"], display: display)
    _ = s.add(10)
    let snapshot = s.barSnapshot(profile: "home", displayName: "Built-in", app: { _ in "Ghostty" }, frame: { _ in nil })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    #expect(json == #"{"displays":[{"id":1,"name":"Built-in"}],"focused":{"app":"Ghostty","window":10,"workspace":"1"},"profile":"home","version":1,"workspaces":[{"display":1,"focused":true,"name":"1","shown":true,"windows":[{"app":"Ghostty","id":10,"x":0,"y":0}]}]}"#)
}

/// A bar shows Secure Input from this key, which is absent while Secure Input is off.
@Test func secureInputAppearsOnlyWhileOn() throws {
    var snapshot = Session(names: ["1"], display: display)
        .barSnapshot(profile: nil, displayName: "Built-in", app: { _ in nil }, frame: { _ in nil })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(!String(decoding: try encoder.encode(snapshot), as: UTF8.self).contains("secureInput"))
    snapshot.secureInput = SecureInput(pid: 812, app: "1Password")
    #expect(String(decoding: try encoder.encode(snapshot), as: UTF8.self).contains(#""secureInput":{"app":"1Password","pid":812}"#))
}
