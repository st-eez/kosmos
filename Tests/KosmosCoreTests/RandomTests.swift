import CoreGraphics
import Testing
@testable import KosmosCore

/// Runs random operations and checks after each one that the workspace is sound, that a
/// failed operation changed nothing, that a move moved the window, and that the frames
/// tile the display rectangle without overlapping.
@Test(arguments: 1...8 as ClosedRange<UInt64>)
func randomOperationsKeepTheInvariants(seed: UInt64) {
    var random = SplitMix64(state: seed)
    var workspace = Workspace()
    var nextWindow: WindowID = 1
    let gaps = Gaps(inner: 8, outer: Insets(top: 30, left: 8, bottom: 8, right: 8))
    let area = CGRect(x: 8, y: 30, width: 984, height: 562)

    func attempt(_ operation: (inout Workspace) -> Bool) {
        let before = workspace.detailed
        if !operation(&workspace) {
            #expect(workspace.detailed == before, "seed \(seed)")
        }
    }

    for _ in 0..<4000 {
        let known = workspace.root.windows + workspace.floating + workspace.parked.map(\.window)
        let window = known.randomElement(using: &random) ?? 0
        let direction = [Direction.left, .right, .up, .down].randomElement(using: &random)!
        switch Int.random(in: 0..<32, using: &random) {
        case 0..<6:
            if known.count < 12 {
                workspace.insert(nextWindow)
                nextWindow += 1
            }
        case 6: attempt { $0.remove(window) }
        case 7: attempt { $0.park(window) }
        case 8, 9: workspace.unpark(Array(workspace.parked.map(\.window).shuffled(using: &random).prefix(2)))
        case 10: attempt { $0.float(window) }
        case 11: attempt { $0.tile(window) }
        case 12: workspace.focus(window)
        case 13, 14: attempt { $0.focus(direction, from: window) != nil }
        case 15..<20:
            let before = workspace.frames(in: screen, gaps: Gaps())[window]
            var moved = false
            attempt {
                moved = $0.move(window, direction)
                return moved
            }
            // A fullscreen frame stays put, and random resizes can leave shares that round
            // to nothing.
            if moved, workspace.fullscreenWindow != window, let before, !before.isEmpty {
                #expect(workspace.frames(in: screen, gaps: Gaps())[window] != before, "seed \(seed)")
            }
        case 20, 21: attempt { $0.swap(window, direction) }
        case 22, 23: attempt { $0.joinWith(window, direction) }
        case 24, 25: attempt { $0.toggleLayout(window) }
        case 26..<29:
            let dimension = [ResizeDimension.width, .height, .smart].randomElement(using: &random)!
            let amount = CGFloat(Int.random(in: -300...300, using: &random))
            attempt { $0.resize(window, dimension, by: amount, in: screen, gaps: gaps) }
        case 29: attempt { $0.fullscreen(window, Bool.random(using: &random)) }
        case 30: workspace.balanceSizes()
        default: workspace.flattenWorkspaceTree()
        }

        #expect(workspace.validate().isEmpty, "seed \(seed)")
        let frames = workspace.frames(in: screen, gaps: gaps)
        #expect(Set(frames.keys) == Set(workspace.root.windows), "seed \(seed)")
        guard workspace.fullscreenWindow == nil else { continue }
        let values = Array(frames.values)
        for (index, frame) in values.enumerated() {
            #expect(frame.width >= 0 && frame.height >= 0 && (area.contains(frame) || frame.isEmpty), "seed \(seed)")
            for other in values[(index + 1)...] {
                let overlap = frame.intersection(other)
                #expect(overlap.isNull || overlap.width * overlap.height == 0, "seed \(seed)")
            }
        }
    }
}
