import CoreGraphics

/// Everything a status bar draws, sent whole on every change so the bar never queries
/// (DESIGN.md, sections 5.7 and 5.12). A bar reads `version` first; a new version may
/// rename or remove fields, while new fields can appear in any version.
public struct BarSnapshot: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        /// 1-based, in the order macOS arranges displays, as SketchyBar numbers them.
        public var id: Int
        public var name: String
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

extension Session {
    /// The bar's view of this session, on one display for now.
    /// - Parameters:
    ///   - app: the name of the app that owns a window.
    ///   - frame: where a window is, for windows the layout does not place (floating).
    public func barSnapshot(profile: String?, displayName: String,
                            app: (WindowID) -> String?, frame: (WindowID) -> CGRect?) -> BarSnapshot {
        let workspaces = names.map { name -> BarSnapshot.Workspace in
            let tiled = frames(of: name)
            let windows = windows(of: name).compactMap { id -> BarSnapshot.Window? in
                guard let origin = (tiled[id] ?? frame(id))?.origin else { return nil }
                return BarSnapshot.Window(id: id, app: app(id) ?? "?", x: Int(origin.x.rounded()), y: Int(origin.y.rounded()))
            }.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) }
            return BarSnapshot.Workspace(name: name, display: 1, shown: name == visible, focused: name == visible, windows: windows)
        }
        let focus = focused.map { BarSnapshot.Focus(window: $0, app: app($0) ?? "?", workspace: visible) }
        return BarSnapshot(profile: profile, displays: [.init(id: 1, name: displayName)], workspaces: workspaces, focused: focus)
    }
}
