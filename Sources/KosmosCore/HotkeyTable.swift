/// One mode's bindings by the physical key each names on a keyboard layout, one Carbon
/// hotkey per entry (docs/hotkeys.md).
public struct HotkeyTable: Equatable, Sendable {
    public struct Collision: Equatable, Sendable {
        public var kept: Binding
        public var dropped: Binding
    }

    public private(set) var bindings: [PhysicalKey: Binding] = [:]
    /// Bindings an earlier binding of the mode shadows on this layout, as `alt-sectionSign`
    /// shadows `alt-6` on a French layout.
    public private(set) var collisions: [Collision] = []

    public init(_ bindings: [Binding], layout: [Character: UInt16]) {
        for binding in bindings {
            let key = binding.combo.physicalKey(layout: layout)
            if let kept = self.bindings[key] {
                collisions.append(Collision(kept: kept, dropped: binding))
            } else {
                self.bindings[key] = binding
            }
        }
    }

    /// A key in both stays registered even when its command changed: the table supplies the
    /// command when the key is pressed.
    public func changes(from registered: some Sequence<PhysicalKey>) -> (unregister: Set<PhysicalKey>, register: Set<PhysicalKey>) {
        let wanted = Set(bindings.keys)
        let current = Set(registered)
        return (current.subtracting(wanted), wanted.subtracting(current))
    }
}
