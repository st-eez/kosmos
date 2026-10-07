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
  center, so each keeps its display. AeroSpace does the same (MacWindow.swift). A window
  the saved layout has goes back to its saved workspace instead of either, and at launch
  each display shows the workspace it showed at the save, where the profile lets it
  ([tree.md](tree.md)).
- When the front app keyed the new window, as when the user launched or activated the app,
  and the rule's workspace is hidden, Kosmos shows that workspace on its display and
  focuses the window, as for a Command-Tab to a concealed window ([focus.md](focus.md)).
  When that report came before Kosmos placed the window, one switch places and shows it,
  and the window is never concealed. Hyprland's `workspace` window rule does the same: the
  window opens on that workspace and Hyprland switches to it, unless the rule adds
  `silent` (Hyprland wiki, Window Rules).
  With `mouse-follows-focus` the pointer comes along
  ([focus-follows-mouse.md](focus-follows-mouse.md)). A window its app opens in the
  background changes no workspace, and neither does one an agent, a script or `open -a`
  opened: with no input of the user's before it, it stays concealed on its workspace and
  Kosmos keys its focus again ([focus.md](focus.md)). A `silent` rule option, as
  Hyprland's `workspace N silent`, would keep the user's own launches from switching too,
  and waits for a real case.
  Kosmos's launch sweep follows no window. The key window it finds becomes the focus if
  its workspace is shown, and a follow during the sweep would change the workspace a
  display shows while the sweep still places windows by the display under them, so where
  a window lands would depend on the order apps answer Accessibility. The cost: after a
  relaunch, a key window that a rule or the saved layout puts on a hidden workspace is
  concealed, and Kosmos keys the focused workspace's window.
- A window a rule floats, an Open or Save panel, or a dialog ([inventory.md](inventory.md))
  joins its workspace's floating windows and never the tree, so it keeps the frame its app
  gave it and no tile moves, on a hidden workspace and at launch too. Kosmos logs that frame
  and why it floats at admission. A new Finder window on the left panel had come up at the
  tile a third window beside Preview and Ghostty would have had, behind Ghostty's tile,
  when Kosmos tiled a ruled window before floating it (live log, September 25, 2026).
- The agent workspace, `agent`, holds agents' windows, out of the user's way (Steve's
  design of 2026-10-05 and 2026-10-07; `Session+Agent.swift`). Every session has it, after
  the profile's workspaces, so no profile lists it, and the config refuses a `workspaces`
  list that does, while a rule can send windows there ([config.md](config.md)). No
  display keeps it:
  - `workspace agent`, which Steve binds to alt-`, shows it on the focused display in
    place of the workspace there, and focuses it. Pressed with the agent workspace on
    another display, it moves here and that display gets back the workspace it showed
    before, else its first hidden workspace that can go there. Pressed on the agent
    workspace, it goes and gives its display back the same way. With no hidden workspace
    to give back the press does nothing.
  - No display takes it unasked: a display left with no workspace at a display change or
    a profile takes another, and `workspace next` and `prev` leave it out. The pointer
    entering its empty desktop focuses it where it is. Its window unminimized with no input
    of the user's stays on it, concealed while it is hidden, and the focus goes back, as for
    an app's unhide ([tree.md](tree.md)).
  - The bar has it only while a display shows it, so a bar shows which display holds it
    and lists only the user's workspaces otherwise. `list-workspaces` and `list-windows`
    always list it.
  - Its windows float, so each keeps its size and an agent's screenshots and pixel
    coordinates stay put when it moves between displays, one dragged there by its title
    bar too. A window that leaves it tiles, unless its app holds it off level 0
    ([tree.md](tree.md)); one a modifier drag carries out follows the pointer to the release,
    then takes its tile. A floating window comes to
    the display that shows it at the floating check after the switch, as any floating
    window does (below).
  - While no display shows it, its windows stay drawn under the desktop
    ([hiding.md](hiding.md)), so agents can capture and click them with no peek.
  - Agents' windows reach it three ways: `kosmos open` claims the new windows of the app
    it opens for 10 s ([ipc.md](ipc.md)), a rule's `workspace = 'agent'`, and `kosmos
    move-node-to-workspace --window-id <id> agent`, which shows the window first. A
    claim covers a window its app closed and kept and orders in again, which opens as a new
    one does ([tree.md](tree.md)). A claim goes by app, so a window the user opens in that app within the 10 s goes there
    too, and so do the windows an app restores as it launches.
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
  - A direction takes a display that lies past the edge of the one the command starts
    from, on that side (`Monitor.resolve`). When some of those overlap it across the
    direction, only those count, and of them the nearest wins, then the one that overlaps
    most. When none overlaps, the nearest wins, then the one closest across the
    direction. Ties go to the lower monitor number. With no display that way, a wrap takes
    the farthest display the other way by the same preference, and with none there either
    there is no display.
    - A display that meets the current one only at a corner, or along the same line past
      its end, or lies past a gap without overlapping it, counts when nothing that way
      overlaps. The ceiling is that such a display loses to any display that way that
      overlaps, however far that one is, and is then reached from a display it overlaps,
      by monitor number, `next`, `prev` or the pointer. The upgrade path, when an
      arrangement shows the need, is to rank every display that way by the distance
      between the two frames.
    - Hyprland's `movefocus`, with `binds:window_direction_monitor_fallback`, and
      `focusmonitor` with a direction take the display whose edge meets the current
      display's on that side, within 2 px, with the longest overlap across the direction
      (`CMonitorQueryCore::directionLookup` in src/state/MonitorQueryCore.cpp, called from
      `Actions::moveFocus` in src/config/shared/actions/ConfigActions.cpp, Hyprland main at
      e368c13). It clamps a negative overlap to zero and starts the longest at -1, so a
      display whose edge lies on the same line counts however far past the current
      display's end, as the built-in display does from the office ASUS, 393 pt to its
      left. Where Hyprland's display overlaps, Kosmos takes the same one. Kosmos also
      reaches a display past a gap, which Hyprland never does, since macOS keeps each
      display against another one but not always against the current one. Hyprland wraps
      to no other display. With no window and no display in the direction, `movefocus`
      focuses the window in the direction from the far side of the current display, on
      its workspace, unless `general:no_focus_fallback` is set (ConfigActions.cpp:422-467).
      Its dwindle `movewindow` takes the display under a point 1 px past the window's edge
      instead (`CDwindleAlgorithm::moveTargetInDirection`); Kosmos's `move` takes the
      display `focus` does.
    - AeroSpace's `findRelativeMonitor` (FocusMonitorCommand.swift in aerospace-steez at
      40b2b44d) takes, for left and right, every display that shares some of the current
      display's height, and for up and down every display that shares none of it, and
      steps one place along its monitor order, left to right. Kosmos did the same,
      ordering a column top to bottom, until September 28, 2026, when at the office, with
      the ultrawide at the origin, the ASUS VA24E right of it and the built-in display below
      the ultrawide from x 439, up from the built-in display reached the ASUS. AeroSpace's
      order reaches the ultrawide there, and down from the built-in display it reaches the
      ASUS.
    - On September 28, 2026 these directions changed in the arrangements of Steve's
      profiles, the office with the ultrawide at (0, 0, 2560, 1080), the built-in display
      at (439, 1080, 1728, 1117) and the ASUS VA24E at (2560, 0, 1920, 1080), and home with
      the left panel at (-1920, 0, 1920, 1080), the main panel at (0, 0, 1920, 1080) and
      the built-in display at (0, 1080, 1728, 1117). Every other direction, with or without
      a wrap, and every direction of single, office-va24e and laptop, gives the display it
      gave before.

      | Layout | From | Direction | Before | After |
      |---|---|---|---|---|
      | office | built-in | up, with or without a wrap | ASUS | ultrawide |
      | office | built-in | right, with or without a wrap | none | ASUS |
      | office | built-in | left with a wrap | none | ASUS |
      | home | built-in | left, with or without a wrap | none | left panel |
      | home | built-in | right with a wrap | none | left panel |
      | home | built-in | down with a wrap | left panel | main panel |
  - Left out until a binding needs them: `move-workspace-to-monitor`, which every
    workspace of Steve's four profiles would refuse, since each is assigned, and
    AeroSpace's monitor patterns by name.
  - `focus` and `move` with `--boundaries all-monitors-outer-frame` cross to the display
    in the direction at the edge of the workspace. `focus` is at the edge when no
    window, floating or tiled, stands in the direction, or on a workspace with a fullscreen
    window, none of it and its floating windows by their centers ([tree.md](tree.md)), and
    then focuses
    the window over there on that display's workspace, as tree.md says; `move` moves the
    window there and follows it. A floating window is always at the edge, as it has no
    place in the tree. It stays floating where the floating check below puts it, and one
    in fullscreen leaves fullscreen at its frame from before, taken to the new display
    ([tree.md](tree.md)). A tiled window's move is at the edge when the window has no
    sibling in the direction and no container above its own runs along the direction,
    where AeroSpace's `moveOut` reaches the workspace and a plain `move` wraps the root in
    a new root along the direction, as AeroSpace and i3 do. With no display in the
    direction, the window stays. With
    `--boundaries-action wrap-around-all-monitors` they go on to the display the wrap
    above takes, and a window with no such display stays. AeroSpace takes
    that action for `focus` only; Kosmos takes it for `move` too, which is what Steve's
    `move --boundaries-action fail || move-node-to-monitor --wrap-around` binding did,
    except from the built-in display. There down wraps to the display above that overlaps
    it, where AeroSpace's went to the ASUS at the office, the next display in its left to
    right order, and wrapped to the left panel at home, and left and right reach the ASUS
    at the office and the left panel at home, where AeroSpace's did nothing.
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
  No measurement chose the 0.5 s. The live log of September 24 to 26, 2026 had 64
  notifications. Of the 39 gaps under 5 s between one and the next, 10 were under 0.5 s
  and coalesced, and 29 were 533 to 4,918 ms, so each of those notifications got a
  response of its own, with the resync below. Each notification logs the gap since the
  one before, and each response whether the display set, the display frames or only the
  visible area changed. Hotplug bursts in that log set the wait, or show that a change of
  the visible area alone needs no resync of every frame.
  Slides end at each change, before the wait ([geometry.md](geometry.md)). Kosmos reads
  the displays, resolves the profile again, which ends a forced one, and arranges the
  workspaces:
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
- A floating window has no frame from the layout, except while it covers its display in
  fullscreen and as it leaves fullscreen ([tree.md](tree.md)). After every change, and after
  each switch reveals its windows, a floating window of a shown workspace whose center is on a
  display showing another workspace goes to its workspace's display, at the same place
  relative to the display areas and inside the area, as AeroSpace's
  `layoutFloatingWindow` moves it. That covers a move to another display, a rule that
  sends a new window to a workspace another display shows, and a display change. Kosmos
  reads the windows' frames from WindowServer when it checks. A window whose center is on
  no display comes inside its own workspace's display, keeping its size, as AeroSpace takes
  the nearest monitor. On 2026-10-05 Calculator, killed while a `kosmos peek` held it past
  the built-in display's right edge, restored that frame at its next launch, one column on
  screen, and the old rule left it there. A concealed window's row gives the frame it has, as a shown window's
  does ([hiding.md](hiding.md)), so one still concealed on a shown workspace, as while its
  switch waits for a write, goes home as a revealed one would. The read waits on
  WindowServer, which is busy committing right after a switch, so it runs only while a
  shown workspace has a floating window, and never between a keypress and its batch or its
  focus request. The log gives each read's time, to measure at the desk. A window with a
  write of Kosmos's that no row shows yet, as one leaving fullscreen onto another display,
  goes from where that write puts it: the target in flight, then the read back that
  confirmed it, until a move that was not Kosmos's replaces it (`FrameLedger.newestWrite`,
  `Session.floatingFrames`), since WindowServer can still have the window where it was.
  Such a window needs no read. Skipping it instead, as the check once did, left a
  floating window on the display it had just left when a second `move` came before a row
  showed the first check's write. The pointer goes from the same frame
  ([focus-follows-mouse.md](focus-follows-mouse.md)).
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
    than 10 pt (`TitleBarDrag.dragThreshold`) from where it stood when the left button went
    down lifts the window: it leaves the tree, parked where it stood, and the other windows
    fill its space at once. A click that jitters the title bar moves it less. A window
    whose size changed during the press, or with the pointer on a resize border at its
    first change event (`TitleBarDrag.onResizeBorder`), is being resized and never lifts,
    since WindowServer can apply a resize by the left or top edge as a move first
    (`TitleBarDrag.change`). Kosmos
    writes the lifted window no frame while macOS moves it, and a switch the CLI asks for
    meanwhile leaves it in the user's hand.
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
- A click on the desktop of another display focuses that display's workspace, as when its
  workspace is empty, so alt-` and a free workspace's key then show there
  (`Session.clickedDesktop`). It keys nothing: the app clicked keeps the keyboard, as Finder
  for a desktop icon, whose Quick Look or rename key would otherwise reach the workspace's
  window. macOS reports such a click only as Finder becoming front with
  no key window, which names no display, so Kosmos reads the left mouse up, as AeroSpace
  does with `NSEvent.addGlobalMonitorForEvents` (GlobalObserver.swift). It acts only on the
  user's click, source pid 0, pressed and released where the hit test names no window or
  one at or under the desktop icons' level. So a click on a window is left to that window's
  key report, and a click on a bar or a panel (ZenithBar's sits at level -20), a drag out of
  a window on another display and a click another process posts change nothing. Before this, Steve's alt-` on an empty built-in display showed the agent
  workspace on the main one (2026-10-07).
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
