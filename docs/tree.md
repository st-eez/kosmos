# Tree

- Invariants, checked by `validate()` after every mutation in debug builds and tests:
  - no container except a root is empty or has exactly one child;
  - no `tiles` container nests a `tiles` child with the same orientation (it is spliced
    into the parent at unchanged on-screen sizes);
  - weights are positive fractions;
  - each window has exactly one place.
- First operations: insert, remove, park, unpark, move, swap, join-with, layout, resize,
  balance-sizes, flatten-workspace-tree, fullscreen, floating and tiling, focus direction.
- `focus` in a direction goes up the tree to the nearest container along the direction
  with a sibling on that side, then into that sibling by focus order, as i3's does. The
  workspace's floating windows count as tiles, as AeroSpace's `focus` counts them
  (FocusCommand.swift, `makeFloatingWindowsSeenAsTiling`, at 5f08f9c), so the keyboard
  reaches a floating window a tile covers ([focus-follows-mouse.md](focus-follows-mouse.md)).
  - Each floating window stands in the container of the tile under its center, just
    before that tile, or just after it when its center is at or past the tile's center
    along the container. The tile under a center is the one whose share of the tiling
    rectangle, with no gaps, holds it, as AeroSpace's virtual rectangles do, and a center
    off that rectangle counts at its nearest point there. A floating window centered
    between two side by side tiles therefore stands between them: from the left tile,
    `focus right` reaches it, and again reaches the right tile. Windows at one place go in
    the order of their centers along the container, and stacking plays no part.
  - With no tiles, the floating windows stand in the root in the order of their centers,
    so the arrows walk between them, as on Steve's workspace 4, which holds only floating
    Chrome windows. AeroSpace does the same (FocusCommandTest.swift,
    `testFocusOverFloatingWindows`).
  - The frames are the ones the inventory last heard from WindowServer, which the
    pointer's center uses too ([focus-follows-mouse.md](focus-follows-mouse.md)), so the command waits on no read. Only the
    focused workspace's floating windows count, and parked windows never do: minimized,
    hidden with their app or in native fullscreen.
  - Into a container, Kosmos goes by each window's own focus order. AeroSpace's temporary
    placement marks each floating window most recently focused, which its source calls a
    bug ("floating windows break mru").
  - Focusing a floating window raises it and centers the pointer on it as any focus does
    ([focus.md](focus.md) and [focus-follows-mouse.md](focus-follows-mouse.md)).
  - Hyprland's `movefocus` looks among windows of the focused window's kind first: from a
    tile, the tiles beside it on that side, and the floating windows only when no tile is
    there; from a floating window, the floating windows by angle and distance
    (`CWindowQuery::inDirection` in src/desktop/state/WindowQuery.cpp, Hyprland main at
    e368c13). From either of two side by side tiles the other tile is there, so a floating
    window centered between them is never reached from a tile. Kosmos follows AeroSpace
    here, where [overview.md, section 1](overview.md#1-goal-and-constraints) would follow Omarchy, because only AeroSpace's rule reaches that
    window. Steve chose it.
- Returning windows (unminimize, app unhide, leaving native fullscreen) go back to their own
  workspace at their saved position, and Kosmos follows them to that workspace, as it does
  for Command-Tab. For an app that unhides, it follows the window the app keys if that
  window hid with the app. A keyed window that returns on its own, as a minimized one does
  when its Dock thumbnail unhides the app, is followed by its own return. A keyed
  fullscreen window is not followed, because macOS shows its Space, where a switch fails.
  With no managed window keyed, Kosmos follows the app's most recently focused window.
  - Until then the window is parked: switches neither conceal nor reveal it, and it gets
    no frame. A window already minimized, hidden or in fullscreen when Kosmos admits it,
    as at launch, is parked at once on the workspace it joins.
  - A window its app orders out and keeps, as a closed NSWindowController window, parks
    as a minimized one does, its focus moves on as [focus.md](focus.md) says for a window
    closed and kept, and it returns when the app orders it in again. Kosmos takes
    a window still ordered out after the pairing window, 250 ms, for none of the other
    reasons as one, so the others reflow about 0.25 s after a Command-W. Until September
    25, 2026 it waited a second, and Helium stayed at half width for that second after
    Activity Monitor's window closed beside it (live log). A conceal leaves a window
    ordered in (`kosmos-probe reveal`). A deselected tab is not one: its switch paired
    within the pairing window, and it left the session. A tab whose place a new tab claims
    before Kosmos admits it waits for that admission until a second after its order-out,
    then parks, and gives its place back if the new tab takes it later.
  - A native fullscreen transition orders its window out for about 0.53 s: entering, from
    84 ms after toggleFullScreen to 612 ms, and leaving, from 225 ms to 751 ms
    (`kosmos-probe fullscreen`, September 23, 2026). Entering, the window counts as in
    fullscreen only once it joins its fullscreen Space at 574 ms, after the order-out.
    Leaving, it still counts as in fullscreen at the order-out, until it joins the desktop
    Space at 543 ms. Both ways the transition creates Spaces first, 37 to 46 ms before
    the order-out entering and 193 ms before it leaving. A close posts no Space event: a
    probe panel's close posted its order-out, then its leaving its Space, in one
    millisecond (Kosmos's debug log, September 23). So a window in fullscreen, or ordered
    out within a second of a Space event, is judged after a second, which outlasts the
    transition. A Command-W within a second of a Space switch waits the second too.
  - While the session is locked, and until the sweep after the unlock, no window counts
    as closed and kept, as none is removed then: whether the lock screen orders windows
    out is unmeasured. That sweep checks every managed window still ordered out again.
  - A return received before the latest command is stale, as a Command-Tab is ([focus.md](focus.md)). The
    window goes back, Kosmos stays where the command took it, and it requests the
    command's focus again. A return from fullscreen is stamped at the window's first
    Space event, not at the 1325 that ends the transition.
  - A window in native fullscreen moves to a Space of its own, and Accessibility has no
    notification for it. SkyLight reports 1326 as it leaves its Space and 1325 about 0.5 s
    later as it joins one of type 4 (the fullscreen probe in `kosmos-probe`).
  - A `summon` command brings a window to the current workspace on purpose.
- Native tabs share one place. AppKit orders a deselected tab's window out: it keeps its
  id and leaves every Space (`kosmos-probe tabs`), and WindowServer tags it as it tags a
  window its app ordered out (alt-tab's measurements on macOS 26). A switch posts 1325
  for the incoming tab, 816 and 1326 for the outgoing, then 815 for the incoming, all
  within 0.2 ms (`kosmos-probe tabs`, macOS 27). Closing a tab can destroy it instead.
  - Kosmos pairs the two within 250 ms, in either order, as the yabai forks that follow
    tabs do, and only when they have one frame. Tabs share theirs: a tab that joined its
    group at another size took the group's, and a frame set on the selected tab alone,
    0.3 s before a switch or in the same turn, was the incoming tab's at every event of
    the switch (`kosmos-probe tabs`, macOS 27). A
    native fullscreen window's toolbar window, a window leaving fullscreen and a new
    window cascaded from one closing have frames of their own. Before frames counted, a
    Terminal window leaving fullscreen paired with another Terminal window's order change
    as its toolbar windows went, and took the other fullscreen window's parked place
    (live log, September 24, 2026). Changes of other frames between a switch's two halves
    do not part them.
  - The incoming tab takes the outgoing tab's place, share, focus and workspace, with no
    reflow and no follow, and gets that place's frame. The outgoing tab leaves the
    session, a hidden member of the place.
  - A deselected tab leaves every Space, the holding Space too, whether Kosmos stripped
    its ordinary Space or kept it, and selected again it lands on its ordinary Space
    (`kosmos-probe tabs strip` and `keep`). A switch forgets the deselected tab in the
    concealment ledger and the recovery record, and conceals the selected tab again when
    its place is on a hidden workspace.
  - A switch inside a native fullscreen group swaps the parked tab: the new tab is the one
    in fullscreen, and returns to the place when the group leaves fullscreen. A claim
    passes a place on only to a holder with the switch's frame, so no window takes a
    fullscreen tab's parked place without its fullscreen frame.
  - A tab inherits the minimum of the tab it replaces, since tabs share a size, so a
    switch in a tight layout does not reflow to learn it again. A fullscreen tab's would
    fill the display, so a fullscreen switch passes none.
  - macOS can report the new tab key before the switch pairs, when the tab has no place.
    Kosmos decides that report again once the tab takes its place, as a report of a placed
    window, with any miss found when it came: the kill switch counts it, and it can answer
    a public request. It follows the tab to a place on a hidden workspace. The window key
    before it is the deselected tab, which did not depart. A report that comes after the
    tab took a place on a hidden workspace, before its conceal completed, is followed at
    once the same way. That lasts only until the conceal completes, the workspace is
    shown, or another tab replaces it, so a later re-key of the tab mid-switch still loses
    to the switch.
  - Only an admitted window takes a place. A new tab, and a tab selected for the first
    time, which Accessibility reports created then, take the place once Kosmos admits
    them, and a tab deselected before that stays a hidden member and passes its claim on,
    as when Finder opens several tabs or Command-T is pressed twice.
  - Closing the selected tab is a switch. When the destroy comes before the next tab, the
    closed tab's place waits the pairing window for it, if the app has windows ordered
    out, in native fullscreen too. Closing the group's last tab is a close.
  - A window ordered in with no tab leaving is back after the pairing window if it is
    still ordered in. A hidden member dragged out of its group takes a place of its own,
    parked at once when it is minimized, in native fullscreen or hidden with its app. It
    floats when a rule floats its app, and the workspace a rule names does not apply to it.
    A window its app had closed and kept returns to its place, and Kosmos follows it, so
    a reopened Settings window returns 250 ms late. Merge All Windows parks the merged
    windows that way, and selecting one's tab brings it to the group's place.
  - Kosmos does not read the AXTabGroup of the selected tab. Frames tell the cases seen
    so far apart at no cost, and a false switch now needs two windows of one app with one
    frame, one leaving and one arriving within 250 ms. The AXTabs of the incoming window
    name tabs by title, not by window, so they cannot say which window left, and the read
    costs a round trip on every switch, on the worker that private focus waits on.
    Whether a fullscreen group's tab bar is in the tab's AX tree or its toolbar window's
    is unmeasured. If a false switch between windows with one frame shows up, that read
    is the next step.
