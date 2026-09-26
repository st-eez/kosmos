import CoreGraphics
@testable import KosmosCore

extension Workspace {
    /// Builds a workspace from a description such as `h[1 v[2:1 3:3]]`. A number after a
    /// colon is a weight relative to its siblings. Weights default to equal.
    init(_ description: String) {
        self.init(unchecked: description)
        precondition(validate().isEmpty, "\(validate())")
    }

    /// May break the invariants, for tests of `validate` and `normalize`.
    init(unchecked description: String) {
        self.init()
        var characters = Array(description)[...]
        root = parseContainer(&characters)
        precondition(characters.isEmpty, "trailing text in \(description)")
    }

    private mutating func parseContainer(_ text: inout ArraySlice<Character>) -> Container {
        let orientation: Orientation = text.removeFirst() == "h" ? .horizontal : .vertical
        precondition(text.removeFirst() == "[")
        var children: [Node] = []
        while text.first != "]" {
            if text.first == " " {
                text.removeFirst()
                continue
            }
            let kind: Node.Kind = text.first!.isNumber
                ? .window(WindowID(Self.parseNumber(&text))!)
                : .container(parseContainer(&text))
            var weight = 1.0
            if text.first == ":" {
                text.removeFirst()
                weight = Double(Self.parseNumber(&text))!
            }
            children.append(Node(kind: kind, weight: weight))
        }
        text.removeFirst()
        let total = children.reduce(0) { $0 + $1.weight }
        return makeContainer(orientation, children.map { Node(kind: $0.kind, weight: $0.weight / total) })
    }

    private static func parseNumber(_ text: inout ArraySlice<Character>) -> String {
        let digits = text.prefix { $0.isNumber || $0 == "." }
        text.removeFirst(digits.count)
        return String(digits)
    }

    var tree: String { root.description }

    func frames(in rect: CGRect, gaps: Gaps) -> [WindowID: CGRect] {
        frames(in: rect, gaps: gaps, minimums: [:])
    }

    /// `focus` in a direction on `screen` with `deskGaps`, with the floating windows at `frames`.
    mutating func focus(_ direction: Direction, from window: WindowID, frames: [WindowID: CGRect] = [:]) -> WindowID? {
        focus(direction, from: window, frame: { frames[$0] }, in: screen, gaps: deskGaps, minimums: [:])
    }

    /// `enter` on `screen` with `deskGaps`, with the floating windows at `frames`, and the
    /// window it focuses.
    mutating func enter(_ direction: Direction, frames: [WindowID: CGRect] = [:]) -> WindowID? {
        enter(direction, frame: { frames[$0] }, in: screen, gaps: deskGaps, minimums: [:])
        return focusedWindow
    }

    @discardableResult
    mutating func resize(_ window: WindowID, _ dimension: ResizeDimension, by amount: CGFloat, in rect: CGRect, gaps: Gaps) -> Bool {
        resize(window, dimension, by: amount, in: rect, gaps: gaps, minimums: [:])
    }

    /// On `screen` with no gaps, which matter only for stale hints.
    mutating func unpark(_ windows: [WindowID]) {
        unpark(windows, in: screen, gaps: Gaps())
    }

    /// On `screen` with no gaps, which matter only for stale hints.
    @discardableResult
    mutating func tile(_ window: WindowID) -> Bool {
        tile(window, in: screen, gaps: Gaps())
    }

    /// Everything a failed operation must leave alone, with weights at full precision.
    var detailed: String {
        "\(describe(root) { "\($0)" }) floating \(floating) parked \(parked.map(\.window)) fullscreen \(fullscreenWindow ?? 0)"
    }

    /// Whether the trees have the same shape and windows, with weights within a billionth.
    func sameTree(as other: Workspace) -> Bool {
        func same(_ a: Container, _ b: Container) -> Bool {
            a.orientation == b.orientation && a.children.count == b.children.count
                && zip(a.children, b.children).allSatisfy { x, y in
                    guard abs(x.weight - y.weight) < 1e-9 else { return false }
                    switch (x.kind, y.kind) {
                    case (.window(let p), .window(let q)): return p == q
                    case (.container(let p), .container(let q)): return same(p, q)
                    default: return false
                    }
                }
        }
        return same(root, other.root)
    }

    private func describe(_ container: Container, _ weight: (Double) -> String) -> String {
        let items = container.children.map { child in
            switch child.kind {
            case .window(let id): "\(id):\(weight(child.weight))"
            case .container(let nested): "\(describe(nested, weight)):\(weight(child.weight))"
            }
        }
        return (container.orientation == .horizontal ? "h[" : "v[") + items.joined(separator: " ") + "]"
    }

    /// The weights of the root's children, rounded to thousandths.
    var shares: [Double] { root.children.map { ($0.weight * 1000).rounded() / 1000 } }

    /// The weights of the children of the container holding the window, rounded to
    /// thousandths.
    func shares(around window: WindowID) -> [Double] {
        root[root.path(to: window)!.dropLast()].children.map { ($0.weight * 1000).rounded() / 1000 }
    }
}

let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

/// Stamps count from here: `t0 + .milliseconds(10)`.
let t0 = ContinuousClock.now

/// Steve's gaps. On `screen`, `h[1 2]` has tile 1 at x 10 to 495 and tile 2 at x 505 to 990.
let deskGaps = Gaps(inner: 10, outer: Insets(top: 10, left: 10, bottom: 10, right: 10))

/// Steve's desk (docs/displays.md): the left panel, the main panel at the origin, and the
/// built-in display below, with the home profile's workspaces.
enum Desk {
    static let gaps = Gaps(outer: Insets(top: 10, left: 10, bottom: 10, right: 10))
    static let left = Monitor(id: 1, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), gaps: gaps)
    static let main = Monitor(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), gaps: gaps)
    static let builtIn = Monitor(id: 3, frame: CGRect(x: 200, y: 1080, width: 1512, height: 982), gaps: gaps)
    static let names = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    static let home: [String: DisplayID] = ["1": 2, "2": 2, "3": 2, "4": 2, "5": 1, "6": 1, "7": 1, "8": 3, "9": 3, "0": 3]

    static func session(_ assigned: [String: DisplayID] = Self.home, names: [String] = Self.names) -> Session {
        Session(names: names, monitors: [builtIn, main, left], assigned: assigned)
    }
}

func within(_ frames: [WindowID: CGRect], _ monitor: Monitor) -> Bool {
    !frames.isEmpty && frames.values.allSatisfy { monitor.area.insetBy(dx: 9, dy: 9).contains($0) }
}

/// Deterministic, so a failing sequence can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index in
        var rest = items
        let first = rest.remove(at: index)
        return permutations(rest).map { [first] + $0 }
    }
}
