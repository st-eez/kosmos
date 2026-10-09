import Testing
@testable import KosmosCore

@Test func aReportSaysWhereWhatAnAgentOpenedLanded() {
    #expect(AgentOpenReport.new(app: "Helium", windows: [7]).sentence == "opened in a new Helium window, 7, on the agent workspace")
    #expect(AgentOpenReport.new(app: "Preview", windows: [7, 9]).sentence == "opened in 2 new Preview windows on the agent workspace: 7, 9")
    #expect(AgentOpenReport.existing(app: "Helium", window: 7, count: 1, workspace: "0").sentence
        == "no new window came, so Helium most likely took it into its window 7 on workspace 0, not the agent workspace")
    #expect(AgentOpenReport.existing(app: "Helium", window: 7, count: 3, workspace: Session.agent).sentence
        == "no new window came, so Helium most likely took it into the last used of its 3 windows, 7, on the agent workspace")
    #expect(AgentOpenReport.unknown(app: "Helium", waited: .seconds(10)).sentence
        == "no Helium window came in 10 s, and it has none, so where it opened is unknown")
}
