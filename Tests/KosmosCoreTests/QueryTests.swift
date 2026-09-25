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
