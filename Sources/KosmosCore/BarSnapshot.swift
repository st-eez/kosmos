import CoreGraphics

/// Everything a status bar draws, sent whole on every change so the bar never queries
/// (DESIGN.md, sections 5.7 and 5.12). A bar reads `version` first; a new version may
/// rename or remove fields, while new fields can appear in any version.
public struct BarSnapshot: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        /// SketchyBar's number for the display (`BarSnapshot.displayNumber`), the value an item's
        /// `display` property takes.
        public var id: Int
        public var name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var id: WindowID
        public var app: String
        /// The window's origin, for ordering app icons as they sit on screen.
        public var x: Int
        public var y: Int
    }

    public struct Workspace: Codable, Equatable, Sendable {
        public var name: String
        /// The `id` of its display.
        public var display: Int
        /// On screen on its display.
        public var shown: Bool
        /// Shown on the display that has focus.
        public var focused: Bool
        /// Tiled and floating windows, left to right, then top to bottom.
        public var windows: [Window]
    }

    public struct Focus: Codable, Equatable, Sendable {
        public var window: WindowID
        public var app: String
        public var workspace: String
    }

    public var version = 1
    public var profile: String?
    public var displays: [Display]
    public var workspaces: [Workspace]
    /// Nil on an empty workspace.
    public var focused: Focus?
}

extension BarSnapshot {
    /// SketchyBar's number for a display, as `display_arrangement` in its src/display.c
    /// computes it (SketchyBar 2.24.0): 1 when it is the only active display, otherwise one more
    /// than its position in WindowServer's managed display list, and 0 when the list lacks it.
    /// Kosmos reads the same list, so its numbers equal SketchyBar's in whatever order
    /// WindowServer keeps it.
    /// - Parameters:
    ///   - uuid: the display's UUID (CGDisplayCreateUUIDFromDisplayID).
    ///   - active: how many displays are active (CGGetActiveDisplayList).
    ///   - managed: the display UUIDs from SLSCopyManagedDisplays, in its order.
    public static func displayNumber(uuid: String?, active: Int, managed: [String]) -> Int {
        if active == 1 { return 1 }
        return managed.firstIndex { $0 == uuid }.map { $0 + 1 } ?? 0
    }
}

extension Session {
    /// The bar's view of this session, whose workspaces are all on one display for now.
    /// - Parameters:
    ///   - displays: the connected displays.
    ///   - display: the `id` of the display the session tiles.
    ///   - app: the name of the app that owns a window.
    ///   - frame: where a window is, for windows the layout does not place (floating).
    public func barSnapshot(profile: String?, displays: [BarSnapshot.Display], display: Int,
                            app: (WindowID) -> String?, frame: (WindowID) -> CGRect?) -> BarSnapshot {
        let workspaces = names.map { name -> BarSnapshot.Workspace in
            let tiled = frames(of: name)
            let windows = windows(of: name).compactMap { id -> BarSnapshot.Window? in
                guard let origin = (tiled[id] ?? frame(id))?.origin else { return nil }
                return BarSnapshot.Window(id: id, app: app(id) ?? "?", x: Int(origin.x.rounded()), y: Int(origin.y.rounded()))
            }.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) }
            return BarSnapshot.Workspace(name: name, display: display, shown: name == visible, focused: name == visible, windows: windows)
        }
        let focus = focused.map { BarSnapshot.Focus(window: $0, app: app($0) ?? "?", workspace: visible) }
        return BarSnapshot(profile: profile, displays: displays, workspaces: workspaces, focused: focus)
    }
}
