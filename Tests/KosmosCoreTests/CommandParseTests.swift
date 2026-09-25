import Testing
@testable import KosmosCore

@Test func parsesSteveBindings() {
    let cases: [([String], Command)] = [
        (["workspace", "2"], .workspace(.named("2"))),
        (["workspace", "next"], .workspace(.next)),
        (["workspace-back-and-forth"], .workspaceBackAndForth),
        (["focus", "left"], .focus(.left)),
        (["move", "down"], .move(.down)),
        (["join-with", "up"], .joinWith(.up)),
        (["move-node-to-workspace", "--focus-follows-window", "prev"], .moveNodeToWorkspace(.previous, focusFollowsWindow: true)),
        (["move-node-to-workspace", "3"], .moveNodeToWorkspace(.named("3"), focusFollowsWindow: false)),
        (["move-node-to-workspace", "--window-id", "42", "5"], .moveNodeToWorkspace(.named("5"), focusFollowsWindow: false, window: 42)),
        (["layout", "tiles", "horizontal", "vertical"], .layout(.toggleOrientation)),
        (["layout", "floating", "tiling"], .layout(.toggleFloating)),
        (["fullscreen"], .fullscreen),
        (["resize", "smart", "+100"], .resize(.smart, by: 100)),
        (["resize", "width", "-50"], .resize(.width, by: -50)),
        (["flatten-workspace-tree"], .flattenWorkspaceTree),
        (["reload-config"], .reloadConfig),
        (["mode", "resize"], .mode("resize")),
        (["focus-follows-mouse", "on"], .focusFollowsMouse(.on)),
        (["focus-follows-mouse", "off"], .focusFollowsMouse(.off)),
        (["focus-follows-mouse", "toggle"], .focusFollowsMouse(.toggle)),
    ]
    for (arguments, command) in cases {
        #expect(Command.parse(arguments) == .success(command), "\(arguments)")
    }
}

@Test func rejectsWhatItDoesNotKnow() {
    for arguments in [[], ["focus"], ["focus", "sideways"], ["resize", "smart", "100"], ["resize", "smart", "+0"],
                      ["fullscreen", "--no-outer-gaps"], ["layout", "accordion"], ["move-node-to-workspace"],
                      ["workspace", "1", "2"], ["exec-and-forget", "true"], ["mode"], ["mode", "a", "b"],
                      ["move-node-to-workspace", "--window-id", "x", "2"], ["move-node-to-workspace", "--window-id"],
                      ["move-node-to-workspace", "--wrap-around", "2"],
                      ["focus-follows-mouse"], ["focus-follows-mouse", "true"], ["focus-follows-mouse", "on", "off"]] {
        guard case .failure = Command.parse(arguments) else {
            Issue.record("accepted \(arguments)")
            continue
        }
    }
}

@Test func resizeAmountsAreFiniteAndAtMost100000Points() {
    #expect(Command.parse(["resize", "smart", "+100000"]) == .success(.resize(.smart, by: 100_000)))
    #expect(Command.parse(["resize", "width", "-0.5"]) == .success(.resize(.width, by: -0.5)))
    for amount in ["+inf", "-inf", "+nan", "+1e20", "-1e19", "+100000.5", "-100001"] {
        guard case .failure = Command.parse(["resize", "smart", amount]) else {
            Issue.record("accepted \(amount)")
            continue
        }
    }
}

@Test func parsesTheMonitorCommands() {
    let cases: [([String], Command)] = [
        (["focus", "left", "--boundaries", "all-monitors-outer-frame"], .focus(.left, boundaries: .allMonitors)),
        (["focus", "--boundaries", "workspace", "up"], .focus(.up)),
        (["move", "--boundaries", "all-monitors-outer-frame", "down"], .move(.down, boundaries: .allMonitors)),
        (["move", "--boundaries", "all-monitors-outer-frame", "--boundaries-action", "wrap-around-all-monitors", "left"],
         .move(.left, boundaries: .allMonitorsWrapping)),
        (["focus", "right", "--boundaries-action", "stop", "--boundaries", "all-monitors-outer-frame"],
         .focus(.right, boundaries: .allMonitors)),
        (["focus-monitor", "left"], .focusMonitor(.direction(.left), wrapAround: false)),
        (["focus-monitor", "--wrap-around", "next"], .focusMonitor(.next, wrapAround: true)),
        (["focus-monitor", "2"], .focusMonitor(.number(2), wrapAround: false)),
        (["move-node-to-monitor", "--wrap-around", "--focus-follows-window", "up"],
         .moveNodeToMonitor(.direction(.up), focusFollowsWindow: true, wrapAround: true)),
        (["move-node-to-monitor", "--window-id", "42", "prev"],
         .moveNodeToMonitor(.previous, focusFollowsWindow: false, wrapAround: false, window: 42)),
        (["profile", "home"], .profile("home")),
    ]
    for (arguments, command) in cases {
        #expect(Command.parse(arguments) == .success(command), "\(arguments)")
    }
}

@Test func rejectsWhatTheMonitorCommandsDoNotTake() {
    for arguments in [["focus", "left", "--boundaries"], ["focus", "left", "--boundaries", "all-monitors"],
                      ["move", "left", "--boundaries-action", "wrap-around-all-monitors"],
                      ["move", "left", "--boundaries", "all-monitors-outer-frame", "--boundaries-action", "fail"],
                      ["move", "left", "--boundaries", "all-monitors-outer-frame", "--boundaries-action", "stop"],
                      ["focus-monitor"], ["focus-monitor", "left", "right"], ["focus-monitor", "--wrap-around", "2"],
                      ["focus-monitor", "asus-main"], ["focus-monitor", "0"], ["move-workspace-to-monitor", "left"], ["focus-monitor", "--focus-follows-window", "left"],
                      ["focus-monitor", "--window-id", "4", "left"], ["move-node-to-monitor", "--window-id"],
                      ["profile"], ["profile", "a", "b"], ["profile", "--help"]] {
        guard case .failure = Command.parse(arguments) else {
            Issue.record("accepted \(arguments)")
            continue
        }
    }
}
