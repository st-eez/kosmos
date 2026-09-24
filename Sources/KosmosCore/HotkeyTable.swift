/// One mode's bindings keyed by the physical key each names on a keyboard layout. Kosmos
/// registers one Carbon hotkey per entry.
public struct HotkeyTable: Equatable, Sendable {
    public struct Collision: Equatable, Sendable {
        public var kept: Binding
        public var dropped: Binding
    }

    public private(set) var bindings: [PhysicalKey: Binding] = [:]
    /// Bindings left out because an earlier binding of the mode names the same physical key on
    /// this layout. On a French layout, for example, `alt-sectionSign` and `alt-6` are one key:
    /// 6 needs Shift there, so `alt-6` takes the key a US keyboard has 6 on, which types §.
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

    /// The hotkeys to unregister and register when this table replaces the hotkeys in
    /// `registered`. A key in both stays registered, so a mode switch or a reload touches only
    /// the keys that differ. A key whose command changed stays registered too; the table
    /// supplies the command when the key is pressed.
    public func changes(from registered: some Sequence<PhysicalKey>) -> (unregister: Set<PhysicalKey>, register: Set<PhysicalKey>) {
        let wanted = Set(bindings.keys)
        let current = Set(registered)
        return (current.subtracting(wanted), wanted.subtracting(current))
    }
}
