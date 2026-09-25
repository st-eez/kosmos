/// When each window was last concealed or revealed, so a focus report can be judged by
/// whether its window was hidden when the report was stamped (DESIGN.md, section 5.4). A
/// switch can reveal the window before the report is classified, which turned a Command-Tab
/// into a click on a window being concealed, and can conceal it, which turns a click into a
/// Command-Tab (tla/README.md, change 19).
///
/// Only the last change of each window is kept: a report is classified within milliseconds
/// of its stamp, and a window concealed and revealed again in that time is judged by the
/// later change alone.
public struct ConcealHistory<Stamp: Comparable & Sendable>: Sendable {
    private var last: [UInt32: (concealed: Bool, at: Stamp)] = [:]

    public init() {}

    public mutating func changed(_ windows: [UInt32], concealed: Bool, at stamp: Stamp) {
        for window in windows { last[window] = (concealed, stamp) }
    }

    /// Forgets every change, as after a recovery restored windows without recording it.
    public mutating func forgetAll() {
        last.removeAll()
    }

    public mutating func forget(_ window: UInt32) {
        last[window] = nil
    }

    /// Whether the window was concealed at `stamp`: as its last change left it if that came
    /// by then, and otherwise as it was before that change. `now` serves a window with no
    /// change recorded.
    public func wasConcealed(_ window: UInt32, at stamp: Stamp, now: Bool) -> Bool {
        guard let change = last[window] else { return now }
        return change.at <= stamp ? change.concealed : !change.concealed
    }
}
