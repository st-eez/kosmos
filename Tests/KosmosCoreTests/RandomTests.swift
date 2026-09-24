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
        switch Int.random(in: 0..<34, using: &random) {
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
            let before = workspace.frames(in: screen, gaps: Gaps())
            var moved = false
            attempt {
                moved = $0.move(window, direction)
                return moved
            }
            // A fullscreen frame stays put. Random resizes can leave shares that round to
            // nothing, and passing such a window changes no frame.
            if moved, workspace.fullscreenWindow != window, before.values.allSatisfy({ !$0.isEmpty }) {
                #expect(workspace.frames(in: screen, gaps: Gaps())[window] != before[window], "seed \(seed)")
            }
        case 20, 21: attempt { $0.swap(window, direction) }
        case 22, 23: attempt { $0.joinWith(window, direction) }
        case 24, 25: attempt { $0.toggleLayout(window) }
        case 26..<29:
            let dimension = [ResizeDimension.width, .height, .smart].randomElement(using: &random)!
            let amount = CGFloat(Int.random(in: -300...300, using: &random))
            attempt { $0.resize(window, dimension, by: amount, in: screen, gaps: gaps) }
        case 29: attempt { $0.toggleFullscreen(window) }
        case 30: workspace.balanceSizes()
        case 31: workspace.flattenWorkspaceTree()
        default:
            // Whatever the history, and with stale hints around, windows that leave and
            // come back in any order change nothing.
            let tiled = workspace.root.windows
            guard !tiled.isEmpty, workspace.fullscreenWindow == nil else { break }
            let before = workspace
            let leaving = tiled.shuffled(using: &random).prefix(Int.random(in: 1...min(3, tiled.count), using: &random))
            for window in leaving {
                if Bool.random(using: &random) { workspace.park(window) } else { workspace.float(window) }
            }
            for window in leaving.shuffled(using: &random) {
                if workspace.floating.contains(window) { workspace.tile(window) } else { workspace.unpark([window]) }
            }
            #expect(workspace.sameTree(as: before), "seed \(seed)")
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

/// Shapes random trees, then parks or floats a random set of windows in random order and
/// returns them one at a time in another random order. The tree and every share come back.
@Test(arguments: 1...20 as ClosedRange<UInt64>)
func leavingAndReturningInAnyOrderRestoresTheTree(seed: UInt64) {
    var random = SplitMix64(state: seed)
    var workspace = Workspace()
    var nextWindow: WindowID = 1
    for _ in 0..<40 {
        for _ in 0..<12 {
            let tiled = workspace.root.windows
            let window = tiled.randomElement(using: &random) ?? 0
            let direction = [Direction.left, .right, .up, .down].randomElement(using: &random)!
            switch Int.random(in: 0..<7, using: &random) {
            case 0, 1:
                if tiled.count < 10 {
                    workspace.insert(nextWindow)
                    nextWindow += 1
                }
            case 2: workspace.move(window, direction)
            case 3: workspace.joinWith(window, direction)
            case 4: workspace.toggleLayout(window)
            case 5: workspace.focus(window)
            default:
                let amount = CGFloat(Int.random(in: -200...200, using: &random))
                workspace.resize(window, .smart, by: amount, in: screen, gaps: Gaps())
            }
        }
        let before = workspace
        let tiled = workspace.root.windows
        guard !tiled.isEmpty else { continue }
        let leaving = tiled.shuffled(using: &random).prefix(Int.random(in: 1...tiled.count, using: &random))
        for window in leaving {
            if Bool.random(using: &random) { workspace.park(window) } else { workspace.float(window) }
        }
        for window in leaving.shuffled(using: &random) {
            if workspace.floating.contains(window) { workspace.tile(window) } else { workspace.unpark([window]) }
        }
        #expect(workspace.sameTree(as: before), "seed \(seed)")
    }
}
