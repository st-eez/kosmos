import CoreGraphics

/// Sent whole on every change. A bar reads `version` first (docs/ipc.md).
public struct BarSnapshot: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        /// SketchyBar's number for the display, the value an item's `display` property takes.
        public var id: Int
        public var name: String
        /// CoreGraphics' UUID for the display, which ZenithBar matches its screens by; nil when
        /// CoreGraphics gives none.
        public var uuid: String?

        public init(id: Int, name: String, uuid: String? = nil) {
            self.id = id
            self.name = name
            self.uuid = uuid
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
        /// The `uuid` of its display, which tells apart displays that share a `display` number
        /// (docs/integrations.md). Nil when `displays` lacks its display or it has no UUID.
        public var displayUUID: String?
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
    /// SketchyBar's number for the display `uuid` among `active` displays, from `managed`,
    /// SLSCopyManagedDisplays's list (docs/integrations.md).
    public static func displayNumber(uuid: String?, active: Int, managed: [String]) -> Int {
        if active == 1 { return 1 }
        return managed.firstIndex { $0 == uuid }.map { $0 + 1 } ?? 0
    }
}

extension Session {
    /// A workspace whose display `displays` lacks gets display 0 (docs/integrations.md).
    /// `frame` gives where a floating window is.
    public func barSnapshot(profile: String?, displays: [DisplayID: BarSnapshot.Display],
                            app: (WindowID) -> String?, frame: (WindowID) -> CGRect?) -> BarSnapshot {
        // The agent workspace shows in the bar only while a display shows it (docs/displays.md).
        let workspaces = names.filter { $0 != Self.agent || isShown($0) }.map { name -> BarSnapshot.Workspace in
            let tiled = frames(of: name)
            let windows = windows(of: name).compactMap { id -> BarSnapshot.Window? in
                guard let origin = (tiled[id] ?? frame(id))?.origin else { return nil }
                return BarSnapshot.Window(id: id, app: app(id) ?? "?", x: Int(origin.x.rounded()), y: Int(origin.y.rounded()))
            }.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) }
            let display = displays[monitor(of: name).id]
            return BarSnapshot.Workspace(name: name, display: display?.id ?? 0, displayUUID: display?.uuid, shown: isShown(name),
                                         focused: name == focusedWorkspace, windows: windows)
        }
        let focus = focused.map { BarSnapshot.Focus(window: $0, app: app($0) ?? "?", workspace: focusedWorkspace) }
        return BarSnapshot(profile: profile, displays: monitors.compactMap { displays[$0.id] }, workspaces: workspaces,
                           focused: focus)
    }
}
