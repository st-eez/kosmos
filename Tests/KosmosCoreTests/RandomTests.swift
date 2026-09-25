import CoreGraphics
import Testing
@testable import KosmosCore

/// Runs random operations and checks after each one that the workspace is sound, that a
/// failed operation changed nothing, and that a move moved the window. A third of the
/// windows have minimum sizes. Frames by weight tile the display rectangle without
/// overlapping, and frames with the minimums stay inside it. When the minimums fit, every
/// window gets its minimum and none overlap.
@Test(arguments: 1...8 as ClosedRange<UInt64>)
func randomOperationsKeepTheInvariants(seed: UInt64) {
    var random = SplitMix64(state: seed)
    var workspace = Workspace()
    var nextWindow: WindowID = 1
    let gaps = Gaps(inner: 8, outer: Insets(top: 30, left: 8, bottom: 8, right: 8))
    let area = CGRect(x: 8, y: 30, width: 984, height: 562)
    var minimums: [WindowID: CGSize] = [:]

    func attempt(_ operation: (inout Workspace) -> Bool) {
        let before = workspace.detailed
        if !operation(&workspace) {
            #expect(workspace.detailed == before, "seed \(seed)")
        }
    }

    func returning(_ window: WindowID, _ operation: (inout Workspace) -> Bool) {
        let stale = workspace.hints.contains { $0.window == window && $0.edits != workspace.edits }
        let before = workspace.tileFrames(in: screen, gaps: gaps)
        attempt(operation)
        if stale, workspace.root.windows.contains(window) {
            #expect(keepsOnePoint(before, workspace.tileFrames(in: screen, gaps: gaps), returning: window), "seed \(seed)")
        }
    }

    for _ in 0..<4000 {
        let known = workspace.root.windows + workspace.floating + workspace.parked.map(\.window)
        let window = known.randomElement(using: &random) ?? 0
        let direction = [Direction.left, .right, .up, .down].randomElement(using: &random)!
        switch Int.random(in: 0..<35, using: &random) {
        case 0..<6:
            if known.count < 12 {
                workspace.insert(nextWindow)
                if Int.random(in: 0..<3, using: &random) == 0 {
                    minimums[nextWindow] = CGSize(width: Int.random(in: 0...400, using: &random), height: Int.random(in: 0...300, using: &random))
                }
                nextWindow += 1
            }
        case 6: attempt { $0.remove(window) }
        case 7: attempt { $0.park(window) }
        case 8, 9:
            for parked in workspace.parked.map(\.window).shuffled(using: &random).prefix(2) {
                returning(parked) {
                    $0.unpark([parked], in: screen, gaps: gaps)
                    return true
                }
            }
        case 10: attempt { $0.float(window) }
        case 11: returning(window) { $0.tile(window, in: screen, gaps: gaps) }
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
            attempt { $0.resize(window, dimension, by: amount, in: screen, gaps: gaps, minimums: minimums) }
        case 29: attempt { $0.toggleFullscreen(window) }
        case 30: workspace.balanceSizes()
        case 31: workspace.flattenWorkspaceTree()
        case 32:
            // A tab switch: another window takes this one's place, and every frame stays. The
            // new tab inherits a tiled tab's minimum, as Session.replace gives it.
            let before = workspace.frames(in: screen, gaps: gaps)
            let parked = workspace.parked.contains { $0.window == window }
            attempt { $0.replace(window, with: nextWindow) }
            if workspace.contains(nextWindow) {
                if let minimum = minimums.removeValue(forKey: window), !parked { minimums[nextWindow] = minimum }
                var expected = before
                expected[nextWindow] = expected.removeValue(forKey: window)
                #expect(workspace.frames(in: screen, gaps: gaps) == expected, "seed \(seed)")
                nextWindow += 1
            }
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
        let frames = workspace.frames(in: screen, gaps: gaps, minimums: minimums)
        #expect(Set(frames.keys) == Set(workspace.root.windows), "seed \(seed)")
        guard workspace.fullscreenWindow == nil else { continue }
        #expect(frames.values.allSatisfy { $0.width >= 0 && $0.height >= 0 && area.contains($0) }, "seed \(seed)")
        #expect(tiles(workspace.tileFrames(in: screen, gaps: gaps)), "seed \(seed)")
        let least = leastSize(of: workspace.root, minimums, gap: gaps.inner)
        if least.width <= area.width, least.height <= area.height {
            #expect(tiles(frames), "seed \(seed)")
            for (id, minimum) in minimums {
                guard let frame = frames[id] else { continue }
                #expect(frame.width >= minimum.width && frame.height >= minimum.height, "seed \(seed)")
            }
        }
    }
}

/// Shapes random trees, then parks or floats a random set of windows in random order and
/// returns them one at a time in another random order. With nothing else in between, the
/// tree and every share come back. With other commands in between, the hints are stale,
/// and each return must leave every window that had a point with one.
@Test(arguments: 1...20 as ClosedRange<UInt64>)
func leavingAndReturningInAnyOrder(seed: UInt64) {
    var random = SplitMix64(state: seed)
    var workspace = Workspace()
    var nextWindow: WindowID = 1
    func shape(_ count: Int) {
        for _ in 0..<count {
            let tiled = workspace.root.windows
            let window = tiled.randomElement(using: &random) ?? 0
            let direction = [Direction.left, .right, .up, .down].randomElement(using: &random)!
            let amount = CGFloat(Int.random(in: -200...200, using: &random))
            switch Int.random(in: 0..<12, using: &random) {
            case 0, 1:
                if tiled.count < 10 {
                    workspace.insert(nextWindow)
                    nextWindow += 1
                }
            case 2: workspace.move(window, direction)
            case 3: workspace.joinWith(window, direction)
            case 4: workspace.toggleLayout(window)
            case 5: workspace.focus(window)
            case 6: workspace.resize(window, .smart, by: amount, in: screen, gaps: Gaps())
            case 7: workspace.swap(window, direction)
            case 8: workspace.layout(window, direction.orientation)
            case 9: workspace.moveEdge(window, direction, by: amount, in: screen, gaps: Gaps(), minimums: [:])
            case 10: workspace.balanceSizes()
            default: workspace.flattenWorkspaceTree()
            }
        }
    }
    for _ in 0..<40 {
        shape(12)
        let before = workspace
        let tiled = workspace.root.windows
        guard !tiled.isEmpty else { continue }
        let leaving = tiled.shuffled(using: &random).prefix(Int.random(in: 1...tiled.count, using: &random))
        for window in leaving {
            if Bool.random(using: &random) { workspace.park(window) } else { workspace.float(window) }
        }
        shape(Bool.random(using: &random) ? Int.random(in: 1...4, using: &random) : 0)
        for window in leaving.shuffled(using: &random) {
            let stale = workspace.hints.contains { $0.window == window && $0.edits != workspace.edits }
            let frames = workspace.tileFrames(in: screen, gaps: Gaps())
            if workspace.floating.contains(window) { workspace.tile(window) } else { workspace.unpark([window]) }
            if stale {
                #expect(keepsOnePoint(frames, workspace.tileFrames(in: screen, gaps: Gaps()), returning: window), "seed \(seed)")
            }
        }
        #expect(workspace.validate().isEmpty, "seed \(seed)")
        if workspace.edits == before.edits {
            #expect(workspace.sameTree(as: before), "seed \(seed)")
        }
    }
}

/// Whether every window that had a point along each axis still has one, and the returning
/// window got one.
func keepsOnePoint(_ before: [WindowID: CGRect], _ after: [WindowID: CGRect], returning window: WindowID) -> Bool {
    after.allSatisfy { id, frame in
        let floor = before[id].map { CGSize(width: min(1, $0.width), height: min(1, $0.height)) } ?? CGSize(width: 1, height: 1)
        return frame.width >= floor.width && frame.height >= floor.height
    }
}

/// Whether no two frames overlap.
func tiles(_ frames: [WindowID: CGRect]) -> Bool {
    let values = Array(frames.values)
    return values.indices.allSatisfy { index in
        values[(index + 1)...].allSatisfy { other in
            let overlap = values[index].intersection(other)
            return overlap.isNull || overlap.width * overlap.height == 0
        }
    }
}

/// The least size a container needs for each window in it to get its minimum: its
/// children side by side along its orientation with whole point gaps between them, and
/// the largest of them across.
func leastSize(of container: Container, _ minimums: [WindowID: CGSize], gap: CGFloat) -> CGSize {
    let sizes = container.children.map { child in
        switch child.kind {
        case .window(let id):
            let minimum = minimums[id] ?? .zero
            return CGSize(width: minimum.width.rounded(.up), height: minimum.height.rounded(.up))
        case .container(let nested):
            return leastSize(of: nested, minimums, gap: gap)
        }
    }
    let gaps = gap.rounded(.down) * CGFloat(max(0, sizes.count - 1))
    let widths = sizes.reduce(0) { $0 + $1.width }, heights = sizes.reduce(0) { $0 + $1.height }
    return container.orientation == .horizontal
        ? CGSize(width: widths > 0 ? widths + gaps : 0, height: sizes.map(\.height).max() ?? 0)
        : CGSize(width: sizes.map(\.width).max() ?? 0, height: heights > 0 ? heights + gaps : 0)
}
