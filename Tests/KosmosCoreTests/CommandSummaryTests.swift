import Testing
@testable import KosmosCore

/// The forms SampleConfigTests.describesEveryCommand leaves out.
@Test func describesCommandFormsTheSampleLeavesOut() throws {
    let commands = [
        "focus left",
        "focus --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors up",
        "move right",
        "move --boundaries all-monitors-outer-frame down",
        "swap left",
        "swap down",
        "move-node-to-workspace 3",
        "move-node-to-workspace --window-id 42 next",
        "layout horizontal",
        "layout tiles vertical",
        "resize width +10",
        "resize height -1",
        "resize smart +12.5",
        "balance-sizes",
        "mode resize",
        "focus-monitor left",
        "focus-monitor --wrap-around next",
        "focus-monitor prev",
        "focus-monitor 2",
        "move-node-to-monitor right",
        "move-node-to-monitor --window-id 7 --wrap-around prev",
    ]
    let described = try commands.map { line in
        let command = try Command.parse(line.split(separator: " ").map(String.init)).get()
        return "\(command.summary) [\(command.category.rawValue)]"
    }
    #expect(described == [
        "Focus left [Focus]",
        "Focus up, across monitors, wrapping around [Focus]",
        "Move window right [Move]",
        "Move window down, across monitors [Move]",
        "Swap window with the window to the left [Move]",
        "Swap window with the window below [Move]",
        "Move window to workspace 3 [Workspace]",
        "Move window 42 to the next workspace on the focused monitor [Workspace]",
        "Set the layout to horizontal [Layout]",
        "Set the layout to vertical [Layout]",
        "Grow window width by 10 points [Resize]",
        "Shrink window height by 1 point [Resize]",
        "Grow window by 12.5 points [Resize]",
        "Balance window sizes [Resize]",
        "Switch to mode resize [Other]",
        "Focus the monitor to the left [Monitor]",
        "Focus the next monitor, wrapping around [Monitor]",
        "Focus the previous monitor [Monitor]",
        "Focus monitor 2 [Monitor]",
        "Move window to the monitor to the right [Monitor]",
        "Move window 7 to the previous monitor, wrapping around [Monitor]",
    ])
}
