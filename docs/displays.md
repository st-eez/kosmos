# Displays

- Each connected display shows one workspace. One display is focused, and its workspace
  holds Kosmos's focus.
- Two orders number the displays, and neither stands in for the other.
  - Commands and the config order displays left to right, then top to bottom, as
    AeroSpace orders monitors: monitor numbers, `next` and `prev`, and the first display a
    monitor matcher matches follow that order.
  - The bar event keeps SketchyBar's numbers (`BarSnapshot.displayNumber`, from
    WindowServer's managed display list, [integrations.md](integrations.md)), so a bar item's `display` value
    names the same display SketchyBar does. At Steve's desk the two can differ.
- The active profile assigns workspaces to displays, as AeroSpace's
  `workspace-to-monitor-force-assignment` does: an assigned workspace shows only on the
  first connected display that its monitor list matches. A workspace whose list matches
  no connected display is free.
- A workspace's display is the one that shows it, else its assigned display, else the
  focused display. Kosmos lays a hidden workspace out on that display's area with that
  display's gaps, so a switch writes no frames. A free workspace shown on a display other
  than the one it was laid out for is laid out as it is shown.
- A new window joins the workspace a rule names, else the focused workspace. A window that
  was there when Kosmos launched joins the workspace shown on the display under its
  center, so each keeps its display. AeroSpace does the same (MacWindow.swift).
- A window a rule floats joins its workspace's floating windows and never the tree, so it
  keeps the frame its app gave it and no tile moves, on a hidden workspace and at launch
  too. Kosmos logs that frame at admission. A new Finder window on the left panel had come
  up at the tile a third window beside Preview and Ghostty would have had, behind
  Ghostty's tile, when Kosmos tiled a ruled window before floating it (live log,
  September 25, 2026).
- Commands use AeroSpace's names.
  - `workspace <name>`, for a workspace another display shows, moves the focus to that
    display with no conceal or reveal. A hidden workspace is shown on its display, which
    becomes focused, and the workspace that display showed is concealed.
  - `workspace next` and `prev` walk the workspaces of the focused display, as AeroSpace's
    do. `workspace-back-and-forth` returns to the workspace focused before.
  - `focus-monitor` and `move-node-to-monitor` take a direction, `next`, `prev` or a
    monitor number, and `--wrap-around`. `move-node-to-monitor` moves the window to the
    workspace the target display shows, at the edge it enters by when the target is a
    direction, and `--focus-follows-window` follows it.
  - Left out until a binding needs them: `move-workspace-to-monitor`, which every
    workspace of Steve's four profiles would refuse, since each is assigned, and
    AeroSpace's monitor patterns by name.
  - `focus` and `move` with `--boundaries all-monitors-outer-frame` cross to the next
    display in the direction at the edge of the workspace. `focus` is at the edge when no
    window, floating or tiled, stands in the direction ([tree.md](tree.md)), and then focuses
    that display's workspace; `move` moves a tiled window there and follows it. A move is
    at the edge when the window has no sibling in the direction and no container above its
    own runs along the direction, where AeroSpace's `moveOut` reaches the workspace and a
    plain `move` wraps the root in a new root along the direction, as AeroSpace and i3 do.
    Past the last display without wrapping, the window stays. With
    `--boundaries-action wrap-around-all-monitors` they go on from the last display to
    the first, and a window with no other display in the direction stays. AeroSpace takes
    that action for `focus` only; Kosmos takes it for `move` too, which is what Steve's
    `move --boundaries-action fail || move-node-to-monitor --wrap-around` binding did.
  - `profile <name>` applies a profile until the displays change or the config reloads,
    as `set-profile.sh` did.
- A key window report of a window on the workspace of any display names a window on
  screen, the user's or macOS's choice. Kosmos adopts it and focuses its display ([focus.md](focus.md)).
  After the key window leaves, macOS can key a window on another display; Kosmos
  adopts that too, as AeroSpace does, and every display keeps its workspace. Holding such
  reports for the departure grace would delay every click on another display by 100 ms.
  TLC passes two displays with every input of the one display configs (tla/README.md,
  change 14). A macOS re-key after a hide, never seen on hardware, would find a window
  on the other display and read as a click there (`displays-fallback`).
- Display changes arrive as `NSApplication.didChangeScreenParametersNotification`.
  AppKit posts it on the main thread once it has rebuilt `NSScreen.screens`, where Kosmos
  reads each display's visible area and name, and it also covers changes to the visible
  area, such as the Dock's. `CGDisplayRegisterReconfigurationCallback`, which yabai,
  SketchyBar and paneru use, runs once per display and phase before AppKit updates, so
  NSScreen could still hold the old displays. Amethyst, alt-tab, FlashSpace, Rectangle and
  glide use the notification, and the AeroSpace fork keeps its monitor snapshot until it
  (commit 1d8c379b).
- A burst of changes gets one response, 0.5 s after the last, as a wake does ([inventory.md](inventory.md)).
  Kosmos reads the displays, resolves the profile again, which ends a forced one, and
  arranges the workspaces:
  - the focused workspace keeps the focus, on its display;
  - every other display keeps its workspace if it may still show it, else shows the one it
    showed before it left, if that may show there, else the first workspace assigned to
    it, else the first free hidden workspace;
  - a display that no workspace can go to shows none, and the log names it.

  Then it resyncs as after an unlock. macOS moves the windows of a display that leaves, so
  each window's frame is written again: when the displays changed, every workspace is
  laid out on its display at once, so that recovery restores no concealed window onto a
  display that is gone; otherwise each workspace is when it is next shown. While
  the session is locked or the displays sleep nothing happens, and the resync after the
  unlock or wake reads the displays. A Mac whose displays sleep can report them gone, and
  the laptop profile would then merge workspaces 6 to 0 into 1 to 5.
- A profile that leaves out workspaces moves their windows to the end of the workspaces
  its `merge-workspaces` names, else of its first workspace. When a profile lists a left
  out workspace again, it comes back as it was, with its tree, shares and focus order,
  and with the windows still merged: those the user closed or moved meanwhile stay out,
  and each returning window takes its state now, parked or not, tiled or floating. Each
  display shows again the workspace it showed before it left, or before its workspace was
  left out. Displays that wake late, as the AeroSpace profile watcher logged, would
  otherwise merge the windows for good.
- A floating window has no frame from the layout. After every change, and after each
  switch reveals its windows, a floating window of a shown workspace whose center is on a
  display showing another workspace goes to its workspace's display, at the same place
  relative to the display areas and inside the area, as AeroSpace's
  `layoutFloatingWindow` moves it. That covers a move to another display, a rule that
  sends a new window to a workspace another display shows, and a display change. Kosmos
  reads the windows' frames from WindowServer when it checks. A window whose center is on
  no display, as a concealed one reads, is left for the check after its reveal. The read
  waits on WindowServer, which is busy committing right after a switch, so it runs only
  while a shown workspace has a floating window, and never between a keypress and its
  batch or its focus request. The log gives each read's time, to measure at the desk.
- A floating window the user drags onto a display showing another workspace joins that
  workspace, with the focus if it had it, as AeroSpace's `moveWithMouse` binds it, so the
  check above leaves it there. Kosmos takes a move of a floating window of a shown
  workspace for a drag when a change event ([geometry.md](geometry.md)) reports it, no frame write of
  its own is in flight for it, the window is key and the left button is down, as
  AeroSpace's `isManipulatedWithMouse` checks. macOS moving the windows of a display that
  leaves is no drag, and the check moves them back. A reveal's Space change reads the
  window's frame again and is no drag either.
- A tiled window the user drags by its title bar is placed where it is dropped, as
  Hyprland's dwindle layout places it (Hyprland 0.56.2, `DwindleAlgorithm::addTarget` and
  `DragController.cpp`; Steve checked the behavior on Omarchy).
  - A change event that finds the key tiled window of a shown workspace moved whole more
    than 10 pt from where it stood when the left button went down lifts the window: it
    leaves the tree, parked where it stood, and the other windows fill its space at once.
    A click that jitters the title bar moves it less. A window whose size changed during
    the press, or with the pointer on a resize border at its first change event
    (`Session.onResizeBorder`), is being resized and never lifts, since WindowServer can
    apply a resize by the left or top edge as a move first. Kosmos writes the lifted
    window no frame while macOS moves it, and a switch the CLI asks for meanwhile leaves
    it in the user's hand.
  - A hotkey pressed during the drag first drops the window where the pointer is, as the
    button coming up would, and its command then runs, as Hyprland 0.56.2's
    `KeybindManager.cpp` ends a drag in `ensureMouseBindState()` before a bind fires. So
    a switch keys the right window, and a move takes the dropped window, which
    `Session.focused` skips while it is lifted. Kosmos moves the pointer for no focus
    change while a window is lifted.
  - When the button comes up, it tiles on the workspace shown on the display under the
    pointer, beside the tiled window under the pointer, else the one whose center is
    closest. The two sit side by side when that window is wider than it is tall
    (`split_width_multiplier` 1), else one above the other, the dropped window first when
    the pointer is in the left or top half, and they share its space equally
    (`default_split_ratio` 1). Omarchy's `force_split = 2` does not apply to a drop, and
    `precise_mouse_move` is off. On an empty workspace the window fills it.
  - The drop's workspace takes the focus, Kosmos keys the window, and the pointer stays
    where the user let go.
  - Off every display, or over one that shows no workspace, the window goes back to where
    it stood, as it does when a lock, a wake or a display change cuts the drag short. A
    window minimized, hidden, closed or put in native fullscreen while dragged parks
    there.
  - A modifier drag with the left button lifts and drops a tiled window the same way
    ([modifier-drags.md](modifier-drags.md)).
- A concealed window keeps its ordinary Space, as on one display, unless its app's most
  recently used window is shown on another display, since macOS prefers an eligible
  window on the current display over the app's key window on another display ([hiding.md](hiding.md),
  and its open item on windows concealed before that window moved).
- Open item: a click on the desktop of another display does not focus that display, as
  when its workspace is empty. AeroSpace watches left mouse up with
  `NSEvent.addGlobalMonitorForEvents` (GlobalObserver.swift), and when the pointer is in
  a display's visible area and that display's workspace is not the focused one, it
  focuses that workspace. Kosmos sees such a click only as Finder becoming front with no
  key window, which names no display. The pointer events of focus follows mouse ([focus-follows-mouse.md](focus-follows-mouse.md))
  could carry the same check.
- Steve's AeroSpace profiles map onto this model, and his config keeps their choices: a
  second office profile, `office-va24e`, takes the ASUS VA24E alone; the laptop profile,
  without `when`, takes the built-in display alone; and displays no profile knows keep
  the profile. These differences stay:
  - Home assigns the twin panels by serial where AeroSpace used monitor numbers, which
    `apply-profile.sh` kept right by placing the panels with BetterDisplay. Kosmos keeps
    workspaces with their panel whatever the arrangement, and places nothing. The twins
    share an EDID UUID, so macOS can swap their places across replugs, and the pointer
    then crosses at the wrong edge until BetterDisplay or System Settings places them.
    Whether macOS keeps them in place is for the desk.
  - `apply-profile.sh` chose home for any two VG279QE5A panels; Kosmos's home needs both
    serials.
  - `set-profile.sh` lasted until the watcher's next check, at most 120 s; `profile`
    lasts until the displays change.
  - The laptop profile left `alt-6` to `alt-0` unbound, so the keys reached the app;
    Kosmos keeps its bindings in every profile, and those commands fail.
  - The migrate script moved windows of 6 to 0 for good; Kosmos moves them back when a
    profile lists their workspace again.
- Open until the desk:
  - whether the twin panels read their own serials, and whether macOS gives them one
    display UUID, which would merge them in Kosmos's Space lookup and the bar numbering
    ([config.md](config.md));
  - whether a concealed window kept in another display's ordinary Space moves with its
    frame when revealed there;
  - how many notifications a hotplug posts, and whether the holding Space survives one;
  - whether WindowServer reports a dragged window's moves while the left button is still
    down, which lifting a dragged tiled window, undoing a tile's resize by its edges and
    rebinding a dragged floating window need;
  - whether macOS keeps the twin panels' left and main places across replugs without
    BetterDisplay, which decides whether a placement step stays;
  - where a concealed window lands when a display leaves and recovery then runs: every
    workspace is laid out on the displays left, and each window should come back on one.
