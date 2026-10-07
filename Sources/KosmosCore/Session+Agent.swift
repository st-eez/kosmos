import CoreGraphics

extension Session {
    /// Kosmos's own workspace for agents' windows, which no display keeps (docs/displays.md).
    /// Every session has it, after the profile's workspaces, and its windows float.
    public static let agent = "agent"

    /// `workspace agent`, as alt-`: shows the agent workspace on the focused display in place
    /// of the workspace there; from another display it moves here and gives that display its
    /// workspace back; focused, it goes and gives its display back (docs/displays.md). Nil
    /// when no hidden workspace can take its display.
    mutating func toggleAgent() -> Plan? {
        guard let there = displayShowing(Self.agent) else { return show(Self.agent) }
        guard var plan = giveBack(there) else { return nil }
        guard there != focusedDisplay else { return plan }
        let summon = show(Self.agent)
        // On screen before and after, so neither batch takes them: a floating one comes to its
        // new display at the floating check after the switch (Controller.bringFloatingHome).
        let moving = Set(windows(of: Self.agent))
        plan.hide = plan.hide.filter { !moving.contains($0) } + summon.hide
        plan.show += summon.show.filter { !moving.contains($0) }
        plan.frames.merge(summon.frames) { $1 }
        plan.focus = summon.focus
        return plan
    }

    /// Shows on `display`, which shows the agent workspace, the workspace it showed before,
    /// else the first hidden one that can go there.
    private mutating func giveBack(_ display: DisplayID) -> Plan? {
        // The workspace displaced can since have left with its profile.
        func fits(_ name: String) -> Bool {
            name != Self.agent && workspaces[name] != nil && !isShown(name) && (assigned[name] ?? display) == display
        }
        guard let back = agentDisplaced.flatMap({ fits($0) ? $0 : nil })
            ?? names.first(where: { fits($0) && assigned[$0] == display }) ?? names.first(where: fits)
        else { return nil }
        agentDisplaced = nil
        shown[display] = back
        var plan = Plan(frames: frames(of: back))
        plan.hide = windows(of: Self.agent)
        plan.show = windows(of: back)
        if focusedWorkspace == Self.agent {
            previous = Self.agent
            focusedWorkspace = back
            if focused == nil, let first = plan.show.first { workspaces[back]!.focus(first) }
            plan.focus = intent
        }
        return plan
    }
}
