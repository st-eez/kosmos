# Tree

- Invariants, checked by `validate()` after every mutation in debug builds and tests:
  - no container except a root is empty or has exactly one child;
  - no `tiles` container nests a `tiles` child with the same orientation (it is spliced
    into the parent at unchanged on-screen sizes);
  - weights are positive fractions;
  - each window has exactly one place;
  - a root holds no lone container: normalizing puts that container in its place, as
    AeroSpace does, so the root's orientation is the one on screen.
- The layout is a pure function of the tree, the display area, the gaps and the sizes
  windows refuse to go below ([geometry.md](geometry.md)). Frames have whole point edges,
  and a fullscreen window gets the whole area. When a container's minimums fit, each
  window gets at least its minimum and the rest goes by weight, as rift's
  `solve_axis_lengths` does. The weights stay as the user set them, so they apply again
  once a minimum stops binding. When the minimums do not fit, the container splits by
  weight alone, and each window with a minimum takes it anyway, moved back inside the
  tiling rectangle over its neighbours. Outer and inner gaps shrink as sway's do, to leave
  each window 100 by 60 pt, sway's `MIN_SANE_W` and `MIN_SANE_H`
  (include/sway/tree/node.h): the outer gaps on an axis in proportion, as
  `workspace_add_gaps` does, and the inner gaps to whole points, as `apply_horiz_layout`
  does (sway/tree/arrange.c).
- First operations: insert, remove, park, unpark, move, swap, join-with, layout, resize,
  balance-sizes, flatten-workspace-tree, fullscreen, floating and tiling, focus direction.
  A workspace with tiled or floating windows always has a focused one, as in i3.
- `move` takes one step, as i3's `tree_move` does (src/move.c). Into a sibling container
  the window lands beside that container's window at the near edge, or its most recently
  focused one when the container runs across the direction, as i3's
  `con_descend_direction` picks it. At the workspace's edge a plain `move` wraps the root
  along the direction, as i3 and AeroSpace do ([displays.md](displays.md)).
- `join-with` is AeroSpace's: the window joins its neighbour in the direction in a new
  container across the neighbour's parent. A neighbour that is a container already runs
  across its parent, so the window joins it.
- `swap` exchanges the window with the tile `focus` reaches in the direction, below, and
  each takes the other's place and share. AeroSpace's `swap` takes the window its `focus`
  reaches too (SwapCommand.swift in aerospace-steez at 40b2b44d). Floating windows do not
  count, since a swap exchanges places in the tree.
- `resize` takes the space from the window's siblings in proportion to their shares. For
  a dimension across the window's container, the nearest ancestor in a container along
  the dimension resizes. It stops where it would take a window below its minimum, or
  below one point without one, counting windows nested in a squeezed sibling, and a
  window under its limit already may stay there. i3 refuses a resize past such a limit.
  Stopping there does as much as the key press can, so repeated presses reach the limit
  exactly, and the weights never ask for less than a window takes.
- `focus` in a direction goes up the tree to the nearest container along the direction
  with a sibling on that side, as i3's `get_tree_next` does, then to the window over there.
  The sibling's windows at its edge facing the focused window are the first or last child
  of each container along the direction and every child of each container across it. Of
  those, the one whose span across the direction overlaps the focused window's most takes
  the focus. Overlaps within a point tie, since frames have whole point edges and the two
  halves of an odd length differ by one, and a tie goes to the most recently focused
  window, or the last one when none of them was focused. So from Ghostty left of Chrome
  over Finder, with Finder used last, `focus right` reaches Finder from a Ghostty at full
  height, and Chrome from a Ghostty in the top half. The workspace's floating windows count
  as tiles, as AeroSpace's `focus` counts them (FocusCommand.swift,
  `makeFloatingWindowsSeenAsTiling`, at 5f08f9c), so the keyboard reaches a floating window
  a tile covers ([focus-follows-mouse.md](focus-follows-mouse.md)).
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
  - A floating window's place in the tree decides only whether it stands at the edge; its
    overlap is its own frame's. A tie goes by each window's own focus order. AeroSpace's
    temporary placement marks each floating window most recently focused, which its source
    calls a bug ("floating windows break mru").
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
  - A focus that crosses to another display ([displays.md](displays.md)) enters the
    workspace there the same way, with that whole workspace as the sibling and the frame
    the focused window has on its own display, so it lands at the edge it crosses. That
    workspace's floating windows count as tiles, as above. A workspace with a fullscreen
    window keeps its focus, since that window covers every edge, and an empty workspace
    takes the focus with no window. From an empty workspace no window overlaps, and the
    windows at the edge tie.
  - Before this, the focus went into the sibling by focus order, the child holding the
    most recently focused window at each level, and into another display's workspace by
    its most recently focused window. On September 25, 2026 the left panel showed Discord
    and the main panel Helium left of Outlook. From Outlook, Command-Tab to Discord and then
    `focus right` reached Outlook, where Helium stood at the edge (live). Steve asked for the
    window over there, within a workspace too.
  - Hyprland's `movefocus` looks at the windows of the workspaces every display shows, and
    takes one whose edge meets the focused window's (within 2 px, or overlapping it by at
    most half the smaller size), with a span across the direction that overlaps it. By default it takes the most recently focused of those, and
    with `binds:focus_preferred_method` 1 the one that overlaps most, the first found on a
    tie (`CWindowQuery::inDirection` at e368c13). Kosmos takes the one that overlaps most,
    and the most recently focused on a tie.
  - AeroSpace goes into the sibling by `findLeafWindowRecursive(snappedTo:
    direction.opposite)` (FocusCommand.swift in aerospace-steez at 40b2b44d, which upstream
    39e51904 matches). It takes the first or last child along the direction, and across it
    the child holding the most recently focused window, whatever its overlap. From a Ghostty
    in the top half it reaches Finder, where Kosmos reaches Chrome. Its most recent child is
    the one holding the most recently focused window anywhere below, where Kosmos compares
    the edge windows' own focus. It enters another display's workspace that way only when
    `wrap-around-all-monitors` wraps to the display at the other end
    (`hitAllMonitorsOuterFrameBoundaries`). Crossing to the next display it focuses the
    workspace's most recently focused window through `focusWorkspace` (focus.swift), so it
    too reached Outlook.
- Returning windows (unminimize, app unhide, leaving native fullscreen) go back to their own
  workspace at their saved position, and Kosmos follows them to that workspace, as it does
  for Command-Tab. For an app that unhides, it follows the window the app keys if that
  window hid with the app. A keyed window that returns on its own, as a minimized one does
  when its Dock thumbnail unhides the app, is followed by its own return. A keyed
  fullscreen window is not followed, because macOS shows its Space, where a switch fails.
  With no managed window keyed, Kosmos follows the app's most recently focused window.
  - Until then the window is parked: switches neither conceal nor reveal it, and it gets
    no frame. Parking asks for no focus, since macOS keys another window itself and a
    request would pull the screen out of a native fullscreen Space. A window already
    minimized, hidden or in fullscreen when Kosmos admits it, as at launch, is parked at
    once on the workspace it joins. At admission native fullscreen comes before a minimize,
    and a minimize before a hide. A parked window keeps the reason it parked for, and only
    a window closed and kept takes a later one (below).
  - A window that leaves the tree to float or park keeps a restore hint that records the
    windows it stood among at each level up to the root, with their shares, since windows
    outlive the containers around them. Its space goes to the windows it shared space
    with, which give it back when it returns. The hint is taken with every window that has
    a fresh hint put back, so windows that leave and return with no other change to the
    tree in between come back to the same places and sizes in any order. A hint is fresh
    while no other change to the tree came after it (`Workspace.edits`).
  - With a stale hint, or none, the window returns beside its old siblings, or after the
    most recently focused tile when none is tiled, only if no window that had a point along
    each axis ends with less, the floor `resize` keeps. Beside the siblings its share halves
    until that holds. Otherwise it takes half of the window with the most room, in a new
    container across that window's container, because adding a child to a container can
    shrink its gaps and move every edge in it, and the new container adds a child to none.
    Each stale return sees the returns before it, so a workspace a profile brings back
    returns its windows in its own saved order.
  - A window its app orders out and keeps, as a closed NSWindowController window, parks
    as a minimized one does, and its focus moves on as [focus.md](focus.md) says for a
    window closed and kept. When the app orders it in again it opens as a new window does
    (`Session.reopen`): it leaves its parked place, joins the focused workspace or its
    rule's, and keeps the minimum size Kosmos learned for it. To the user a closed window
    is closed, and in Omarchy reopening makes a new window on the current workspace.
    Before this, Activity Monitor closed with Command-W on workspace 3 came back there
    when reopened from workspace 5 (live, September 25, 2026). It reopens at its order-in,
    unless another window of its app is ordered in at its frame: only that window's
    order-out can still pair with the order-in as a tab switch, as when the user selects
    the tab of a window Merge All Windows parked, so the reopen then waits the pairing
    window. Before this, every reopen waited the pairing window, and Activity Monitor,
    closed with Command-W on workspace 5 and reopened on workspace 6, showed at its
    workspace 5 tile for about 270 ms after its order-in, where its app ordered it in
    (live log, September 25, 2026). The ceiling: a window that waits and is no tab switch
    stays at its old place for the 250 ms, then slides. A selected tab is already at its
    place. The wait is the pairing window, which the open question below sets. The reopen
    slides the window from where its app showed it to its place
    ([geometry.md](geometry.md)). Kosmos takes a managed
    window ordered out for none of the other reasons as closed and kept, and looks at it
    as soon as the read that saw its order-out is applied with no other read of window
    rows under way or waiting (`ClosedAndKept.Looks`), so the others reflow at once. A
    conceal leaves a window ordered in (`kosmos-probe reveal`). Before this, the look came
    a pairing window, 250 ms, after the order-out, and Activity Monitor's Command-W parked
    257 and 267 ms after it (live log, September 25, 2026).
  - A deselected tab is not one: its switch has paired by the look, and it left the
    session. A switch's two halves came 0.2 ms apart (`kosmos-probe tabs`), and a read took
    about 1.4 ms at the desk ([inventory.md](inventory.md)), so when the halves fall in two
    reads, the second is asked for before the first is applied, and the look waits for
    it. Each WindowServer event reaches the inventory through the main queue, though, and
    a half queued there only after the other half's read came back is neither under way
    nor waiting at the look. The deselected tab would then park as closed and kept, and
    give its place to the new tab when the switch pairs, after one reflow and focus change
    too many. So while the window's app has another window ordered out, which a switch
    could order in, the look waits until a pairing window after the order-out, as a
    destroyed tab's place does. Closing the selected Ghostty or Finder tab is the likely
    case. Activity Monitor, with no other window, parks at once.
  - Open: how far apart Kosmos applies a switch's two halves, which sets the pairing
    window and whether a window whose app has no other window ordered out needs the wait
    too, as the tab that a window's first Command-T deselects might. Kosmos logged order
    changes at debug level, and the live logs of September 23 to 25 kept info level, so
    their five pairings, four Terminal tab switches and a Terminal window leaving
    fullscreen that paired with another's toolbar windows, have no times for their halves.
    Kosmos now logs each candidate window's order change at info level, and says when a
    switch pairs after its deselected tab parked as closed and kept. A day of Ghostty and
    Finder tabs settles it, and the log goes then; until then the pairing window stays
    250 ms.
  - A minimize and a hide have reports of their own, taken to come before the order-out:
    a minimized window was ordered out when its animation ended, 270 ms after miniaturize,
    and a hidden app's window 17 ms after the hide (`kosmos-probe departures`). A minimize
    reported after the look changes the window's reason, and it returns when restored.
    The ceiling: after a hide whose report lands after the look, the app's windows park
    as closed and kept, and when the app unhides they reopen on the focused workspace, or
    their rule's, instead of going back to their places. The log shows it as a "closed
    and kept by its app: parked" line for each window before the app's "hid" line. The
    upgrade path is for the hide to take its app's windows that parked as closed and kept
    within the departure bound.
  - A tab whose place a new tab claims before Kosmos admits it waits for that admission
    until a second after its order-out, then parks, and gives its place back if the new
    tab takes it later. Parking it sooner would request focus for the workspace's next
    window, away from the new tab the user just selected, and reflow twice once the new
    tab takes the place.
  - A native fullscreen transition orders its window out for about 0.53 s: entering, from
    84 ms after toggleFullScreen to 612 ms, and leaving, from 225 ms to 751 ms
    (`kosmos-probe fullscreen`, September 23, 2026). Entering, the window counts as in
    fullscreen only once it joins its fullscreen Space at 574 ms, after the order-out.
    Leaving, it still counts as in fullscreen at the order-out, until it joins the desktop
    Space at 543 ms, and a window in fullscreen never counts as closed and kept. Both
    ways the transition creates Spaces first, 37 to 46 ms before the order-out entering
    and 193 ms before it leaving. A close posts no Space event: a probe panel's close
    posted its order-out, then its leaving its Space, in one millisecond (Kosmos's debug
    log, September 23). So while the last Space event came within a second before the
    order-out, or since, the window waits until a second after its order-out, which
    outlasts the transition.
  - That Space event is the last one on any display: a Space created or destroyed, or
    the active Space changed, anywhere. So a close waits the second after another app's
    fullscreen transition, a new desktop, a display change or Kosmos's own recovery, and
    after a Space switch on any display.
  - A transition that posts no Space event until after the look, as Split View joining a
    Space that exists might, parks its window as closed and kept. When the window then
    counts as in fullscreen it changes reason and stays parked, and it returns when it
    leaves fullscreen. Its departure may have moved the focus meanwhile.
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
    out, in native fullscreen too. Closing the group's last tab is a close. A switch in
    the meantime leaves the closed tab out of its batch ([hiding.md](hiding.md)).
  - A hidden member ordered in with no tab leaving is back after the pairing window if it
    is still ordered in. A hidden member dragged out of its group takes a place of its own,
    parked at once when it is minimized, in native fullscreen or hidden with its app. It
    floats when a rule floats its app, and the workspace a rule names does not apply to it.
    It shows for the pairing window before it takes its place, so it slides from there as
    a reopened window does ([geometry.md](geometry.md)). A window its app had closed and
    kept opens again as a new window, 250 ms late only while another window of its app is
    ordered in at its frame (above). Merge All Windows parks the merged windows that way,
    and selecting one's tab brings it to the group's place.
  - Kosmos does not read the AXTabGroup of the selected tab. Frames tell the cases seen
    so far apart at no cost, and a false switch now needs two windows of one app with one
    frame, one leaving and one arriving within 250 ms. The AXTabs of the incoming window
    name tabs by title, not by window, so they cannot say which window left, and the read
    costs a round trip on every switch, on the worker that private focus waits on.
    Whether a fullscreen group's tab bar is in the tab's AX tree or its toolbar window's
    is unmeasured. If a false switch between windows with one frame shows up, that read
    is the next step.
