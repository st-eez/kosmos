import CoreGraphics
@testable import KosmosCore

extension Workspace {
    /// Builds a workspace from a description such as `h[1 v[2:1 3:3]]`. A number after a
    /// colon is a weight relative to its siblings. Weights default to equal.
    init(_ description: String) {
        self.init(unchecked: description)
        precondition(validate().isEmpty, "\(validate())")
    }

    /// Builds a workspace that may break the invariants, for tests of `validate` and
    /// `normalize`.
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

    /// Everything a failed operation must leave alone, with weights at full precision.
    var detailed: String {
        func describe(_ container: Container) -> String {
            let items = container.children.map { child in
                switch child.kind {
                case .window(let id): "\(id):\(child.weight)"
                case .container(let nested): "\(describe(nested)):\(child.weight)"
                }
            }
            return (container.orientation == .horizontal ? "h[" : "v[") + items.joined(separator: " ") + "]"
        }
        return "\(describe(root)) floating \(floating) parked \(parked.map(\.window)) fullscreen \(fullscreenWindow ?? 0)"
    }

    /// The weights of the root's children, rounded to thousandths.
    var shares: [Double] { root.children.map { ($0.weight * 1000).rounded() / 1000 } }

    /// The weights of the children of the container holding the window.
    func shares(around window: WindowID) -> [Double] {
        root[root.path(to: window)!.dropLast()].children.map { ($0.weight * 1000).rounded() / 1000 }
    }
}

let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

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
