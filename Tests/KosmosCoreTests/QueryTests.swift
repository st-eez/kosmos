import CoreGraphics
import Testing
@testable import KosmosCore

@Test func eachQueryIsItsNameAloneAndNoCommand() {
    let names = ["ping", "version", "state", "list-workspaces", "list-windows", "list-bindings"]
    #expect(names.map { Query([$0]) } == [.ping, .version, .state, .listWorkspaces, .listWindows, .listBindings])
    for name in names {
        #expect(Query([name, "extra"]) == nil, "\(name)")
        guard case .failure = Command.parse([name]) else {
            Issue.record("\(name) is also a command")
            continue
        }
    }
    #expect(Query([]) == nil)
    #expect(Query(["reload-config"]) == nil)
}

@Test func theListsMarkTheFocusedWorkspaceAndWindow() {
    var s = Session(names: ["1", "2", "3"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(10); _ = s.add(11)
    s.adopt(11)
    _ = s.add(12, to: "3")
    #expect(s.workspaceList == "1 *\n2\n3")
    #expect(s.windowList { $0 == 12 ? nil : "App \($0)" } == "10 1 App 10\n11 1 App 11 *\n12 3 ?")
}

@Test func listedBindingsPutMainFirstThenModesByName() throws {
    let result = Config.load("""
        config-version = 1
        workspaces = ['1']
        [mode.resize.binding]
        alt-h = 'resize width -50'
        esc = 'mode main'
        [mode.main.binding]
        alt-l = 'focus right'
        alt-r = 'mode resize'
        [mode.apps.binding]
        esc = 'mode main'
        """)
    #expect(result.diagnostics.isEmpty)
    let listed = ListedBinding.list(try #require(result.config).modes)
    #expect(listed.map { "\($0.mode) \($0.key): \($0.description) [\($0.category)]" } == [
        "main alt-l: Focus right [Focus]",
        "main alt-r: Switch to mode resize [Other]",
        "apps esc: Switch to mode main [Other]",
        "resize alt-h: Shrink window width by 50 points [Resize]",
        "resize esc: Switch to mode main [Other]",
    ])
}
