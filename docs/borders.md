# Borders

Kosmos draws a border around each tiled and floating window on screen, as Omarchy's
Hyprland does, in place of JankyBorders. JankyBorders runs in a process of its own and
draws from WindowServer's events, so it knows nothing of workspaces, concealment or slides.
In Steve's trial of the slide on 2026-09-25, its border scaled with the sliding window,
whose Space it copies its border into, and near a display's edge the border showed on the
neighbouring display, drawn at the window's frame while the slide showed the window
elsewhere. Kosmos knows each window's frame, focus, workspace, concealment and fullscreen
state, and during a slide the frame the slide shows the window at.

- The config's `borders` key turns borders on and off and sets their width and colors
  ([config.md](config.md)). The focused window's color defaults to the macOS accent,
  `NSColor.controlAccentColor` in sRGB under Kosmos's appearance. Kosmos reads it again
  when AppKit posts `NSColor.systemColorsDidChangeNotification`, which a new accent color
  in System Settings brings, and when its appearance changes between light and dark,
  which show the accent in shades of their own.
- Steve's dotfiles theme the table: their theme build renders it for each theme from the
  accent and border width that render JankyBorders' `bordersrc`, and `theme-set` links the
  current theme's copy to the file the config includes ([config.md](config.md)) and
  reloads the config.
- KosmosCore's `Session.bordered` names the windows that get a border: the tiled and
  floating windows of the shown workspaces, none of them parked (minimized, hidden with its
  app, in native fullscreen, or closed and kept by its app), and no tile of a workspace
  with a Kosmos fullscreen window, the fullscreen window included. A tiled window the user
  holds lifted by its title bar is parked, and keeps its border ([displays.md](displays.md)).
- The window with the focus, `Session.focused`, takes `active`, or the accent color, and
  every other window `inactive`. The color changes with the model's focus: at a command,
  a hover or a key window report Kosmos adopts, before macOS's key change lands. A fully transparent color
  draws no border and makes no window, so with Steve's transparent `inactive` only the
  focused window has one.
- A window whose app refuses its tile takes `warning` for 0.3 s, focused or not, so with
  a transparent `inactive` the flash still shows. `warning` defaults to macOS's system
  red, `NSColor.systemRed` in sRGB under Kosmos's appearance, read again when the accent
  is. A transparent `warning` leaves each window its own color.
  - A plan Kosmos carries out flashes each window whose frame it writes that spills past
    its tile on an axis ([tree.md](tree.md)), where the frame moves along that axis from
    where WindowServer last had it: a resize, a placement or a balance that leaves a
    window's tile shorter than its minimum, or moves the tile it spills from. A width
    resize leaves a window that spills in height alone.
  - Only a plan flashes, and never during a drag, so a modifier drag's writes, a lift's
    reflow and the 100 ms retry after a refusal never do. A window that flashes again
    keeps `warning` until 0.3 s after its last flash.
  - On September 25, 2026, Outlook, held to 1145 pt, covered 290 pt of Helium on Steve's
    main panel, and each resize moved only Helium's edge, with nothing to say why (live
    log).
  - The ceiling: a minimum learned from refusals, where WindowServer holds none
    ([geometry.md](geometry.md)), flashes only where the spill moves the window, as at the
    left edge. At the right edge and between windows the app's refusal has already left
    the window where it spills, so Kosmos has no frame to write. A flash at the refusal
    that records the minimum would cover it.
- A bordered window gets its border only while it is on screen: not concealed, as a
  switch's incoming windows are until the batch that reveals them confirms, and ordered
  in, so the border goes as soon as WindowServer orders a window out, before Kosmos parks
  it. A window that a batch still in flight conceals counts as concealed: after a switch
  to workspace B and straight back to A, A's windows get their borders once the batch
  that conceals them and the one that reveals them have both finished. The outgoing
  workspace's borders go as Kosmos plans the switch, before its batch conceals the
  windows, and the incoming ones come when the batch confirms, after the windows show.
- The shape is what shows of JankyBorders' line (`border.c`, Steve's fork), so `width`
  looks the same in both. JankyBorders strokes `width` points centered on the window's
  edge, clipped 1 point inside it, in a window ordered below its target by default, so
  the target covers the inner half: with `width = 4` Steve saw its outer 2 points. Kosmos
  orders its border above the window, and so draws only that outer half, a ring from the
  window's edge outward by half the width: with `width = 4`, 2 points. Before
  2026-09-25 it drew JankyBorders' point inside the edge too, over the window, and Steve
  found its 3 points thicker. The ring's inner corners are the window's: WindowServer's
  corner radius for the window, read with its row (`SLSWindowIteratorGetCornerRadii`). The
  caller owns the array of radii despite the Get name: 50,000 reads that kept it grew the
  probe by 3.9 MB, and as many that released it by nothing (`kosmos-probe borders`).
  Its outer corners are that radius plus half the width, concentric, as a layer's border
  draws its inner edge at the corner radius less the border's width (an offscreen render
  on macOS 27). Only the inventory's reads take the radius: it took a read of 2
  windows' rows from 0.0138 and 0.0140 ms to 0.0152 and 0.0155 ms at the median in two
  runs of the probe on 2026-09-25, and Slides' poll reads rows every 100 µs while a
  write lands. A titled window's corners are rounded 16 points on macOS 27 (26A428,
  `kosmos-probe borders`), and a square window gets a square border. JankyBorders'
  `style=round` and `hidpi=off` have no key: the corners always follow the window's, and
  Core Animation draws at the display's resolution. Its square style is left out: at a
  16 point radius a square ring either shows the desktop in each corner or covers the
  window's content there.
- Each border is a window of Kosmos's own (`KosmosApp/Borders.swift`): borderless, clear,
  without a shadow, ignoring the mouse, never key or main, hidden in Mission Control and
  out of the window cycle (`.transient` and `.ignoresCycle`, as the empty workspace's
  window), and kept on screen when Hide Others in another app hides Kosmos
  (`canHide = false`). The ring is its layer's border, which Core Animation draws with no
  backing store: a border around 1200 by 800 points added nothing to the probe's memory
  footprint. A border hidden is ordered out and goes to its display's pool, and the next
  window bordered on that display reuses it, so each of Steve's displays keeps one border
  window, which moves from window to window with the focus. A display that goes keeps its
  pool, ordered out, for its return.
- The border is ordered directly above its window with `NSWindow.order(_:relativeTo:)`,
  which takes another app's window: in `kosmos-probe borders`, in each of six runs on
  2026-09-25, the window list showed the border right above the child app's window and
  below the child's other window that covered it, so a window over the target covers its
  border too. When the child raised its window, WindowServer posted 808 (reordered) and
  815 for it and left the border below, under the other window the raise put the target
  over. So at each 808 for a managed window the inventory sends `.reordered`, and Kosmos
  orders that window's border above it again: 0.024 ms at the median over 100 orders.
  Ordering the border posted no event for the target, so the two never feed each other.
  The border's window level is its target's. Setting another level can move the border
  within the stacking order, so when the target's row shows another level, Kosmos orders
  the border above the target again.
- WindowServer's hit test passes through a border: `NSWindow.windowNumber(at:)`, the
  window a mouse down at a point would hit, named the target at a point 1 point outside
  its edge, under the ring and in the target's resize margin. So clicks and resizes by the
  edge reach the window.
- A border is in its window's Space. In the probe, a new border window joined the current
  Space of its display, kept its Space while ordered out and in, and stayed in another
  display's Space after it was ordered above its target again; moving it 10 points put it
  back in its own display's current Space. A display's current Space can be another app's
  native fullscreen Space, so whenever a border window is shown for another window,
  Kosmos reads its Spaces and its target's off the main thread, since a read can wait out
  a Space transition, and moves the border to its target's ordinary Space with
  `SLSMoveWindowsToManagedSpace` when it is in none of them. Ordered in first, a border
  over a fullscreen Space drew on the app until the move landed. Ordered in only after the
  reads and the move, which take a hop to their queue and one back, every border blinked
  as the focus moved, since each focus move takes the border window from its display's pool
  for the newly focused window. So Kosmos orders a border in at once, and holds it ordered
  out until its move is sent only on a display that may show a native fullscreen Space, as
  slides judge it ([geometry.md](geometry.md)): a display that holds a window parked in
  native fullscreen, unless it holds the key window while no fullscreen Space shows. The
  ceiling: a fullscreen Space of an app Kosmos does not manage goes unseen, and a border
  shown on its display draws on the app until the move lands. Reading each display's
  current Space would tell. On such a display the border also gets its frame only after
  the move is sent, as Kosmos orders it in, since a frame set before the move might take
  it back to the Space its display shows, as moving it 10 points took it back from another
  display's Space (above). In `kosmos-probe borders` on 2026-09-25, a border ordered in
  before, then ordered out, moved to another display's Space and ordered above its target,
  was in the Space it was moved to, and the first direct read after the move showed it
  there. A new window framed, moved and then ordered in for the first time was in its
  display's current Space, so its first order-in, or its frame set before the move, took
  it there. So each border window is ordered in and out once as it is made, 1 by 1 point
  at its display's bottom left corner, while it draws nothing. Untested: whether a frame
  set while a border is ordered out takes it back to the Space its display shows.
  `kosmos-probe border-space` settles it with its case "ordered in and out, framed, moved
  to S, ordered above T", and its other cases say whether a frame set after the move does
  too and whether a window needs its first order-in before a move. It needs a second
  ordinary Space on the built-in display or the leftmost one, and Steve keeps one Space on
  each display. A border moved to another display's Space was there when read back. The target's Spaces can include the
  holding Space or a slide's animation Space, whose transform would draw the border too,
  so Kosmos chooses from the ordinary Spaces of the border's own display alone, and leaves
  the border where it is when the target has none there, as during a drag or a slide
  across displays.
- A border window keeps to one display, and a window that moves to another display takes
  a border window of that display's. Before 2026-09-25 one pool served every display, so
  Steve's one border window moved between displays with the focus, and Kosmos moved it to
  the new display's Space. `kosmos-probe border-watch` sampled it every 1.5 ms while Steve
  moved the focus 28 times between Ghostty on the main display and a window on the
  built-in one. In 12 of the 28 hops, 8 of the 20 Steve made while he watched for it, the
  border showed on the new display at the last window's size for 9 to 40 ms. Toward Ghostty it showed at the other window's 1712 by
  1074 points at (8, -2), then at Ghostty's 1904 by 1039 at (8, 33), and Steve saw it
  appear inside Ghostty and stretch to fill it. Toward the built-in display it showed at
  Ghostty's size at (8, 1150), and the built-in display showed it there for 8 to 33 ms.
  Each time the Space move reached WindowServer before AppKit's new frame, and
  WindowServer moved the window onto the Space's display at its old size. In
  `kosmos-probe border-hop`, a hop took 10.4 and 12.4 ms of the main thread at the median
  in two runs of 20 with one border window, against 0.79 and 0.88 ms with a border
  window for each display. The probe's new frame always reached WindowServer before its
  Space move, so it showed no stray frame with one window either.
- The border follows the frame WindowServer last reported for its window: the inventory's
  row, read after each change event, so it follows every move and resize, the user's,
  the app's and Kosmos's own. It trails the window by the event's way to Kosmos and the
  read of the row, as JankyBorders trails it by its event's way.
  The Controller shows the borders again after each change of the model (`publishState`),
  each batch's completion, each change of a window's frame, level or corner radius or of
  whether it is ordered in, and each slide frame; nothing polls. A border that is the
  same as shown costs no AppKit call, and a move at the same size calls `setFrameOrigin`,
  0.014 ms at the median against 0.158 ms for a resize (the probe, 200 of each).
- The border shows on the display that holds the largest part of its window, cut to that
  display, so it never shows on a display the window is not on. At a display's edge it
  is cut there, as the window is.
- During a slide ([geometry.md](geometry.md)), the border follows the frame the slide
  shows the window at, as of the display frame its display's link last stepped
  (`Slides.shown`), at that frame's alpha, so a pop fades it in and scales its frame with
  the window, at the same line width. Its window then covers its display, and each display frame moves only the
  ring's layer, which took a fourth of the main thread's time that moving the window did
  (below). The border stays in the desktop Space, out of the animation Space and its
  transform, so its line keeps its width and its display. The animation Space draws above
  the desktop Space, and the ring lies outside the window's edge, so the window covers
  none of it during the slide. A new window waiting for its write to land, transparent,
  shows no border yet.
- Borders need no recovery: they are Kosmos's own windows, so they go with its process,
  and a border hides by being ordered out, never through the holding Space.
- `kosmos-probe borders-cpu` times four windows of a child app, each moved and resized by
  12 relayouts half a second apart, at the bottom left of the built-in display, with
  JankyBorders running as Steve runs it, whose borders of those windows, never focused,
  are transparent. Two runs on 2026-09-25, CPU per relayout:

  | | Probe | JankyBorders |
  | --- | --- | --- |
  | No border of the probe's | 0.9 and 1.0 ms | 5.9 and 6.0 ms |
  | Four borders following change events | 5.4 and 9.9 ms | 7.1 and 6.4 ms |
  | Four borders slid, the window moved each display frame | 81.8 and 121.7 ms | 6.2 and 5.3 ms |
  | Four borders slid, the layer moved each display frame | 28.9 and 46.2 ms | 7.7 and 5.9 ms |

  During slides, each border step took 0.08 and 0.14 ms of the main thread with the layer
  moved, against 0.32 and 0.49 ms with the window moved. WindowServer took 225 to 288 ms
  each half second, at rest too, so its share is rough: about 42 and 48 ms more a
  relayout with the windows moved at each display frame, 13 and 15 ms more with the
  layers moved, and nothing measurable for borders following change events. Kosmos's
  slide log gives its display link's callback time, which includes the borders.
- Open until the live test:
  - whether a focus move between displays still shows the border at the last window's
    size (`kosmos-probe border-watch` with the border window's id);
  - whether the first focus on a display that comes back shows its border at an old frame
    once, as WindowServer may move a pooled window when its display goes
    (`kosmos-probe border-watch` over an unplug and replug); if it does, Kosmos should
    close a gone display's pool at the display change;
  - whether the ring's inner corners meet the window's: they are circular arcs of the
    window's radius, so corners of another curve would show a sliver of the desktop, or of
    the ring over the window, at each corner, which JankyBorders' line below the window
    hid;
  - whether the border follows a new accent color and a switch between light and dark;
  - whether focus follows mouse and modifier drags, which read WindowServer's hit test
    from each event (`kCGMouseEventWindowUnderMousePointer`), see through a border as
    `NSWindow.windowNumber(at:)` does;
  - whether a border stays hidden in Mission Control and out of Command-backtick, and out
    of launchers' and window switchers' window lists, and leaves with its Space when a
    native fullscreen Space or another desktop shows;
  - whether a border shown for a window while a native fullscreen Space is on its display
    stays off the fullscreen app, now that Kosmos moves it before ordering it in;
  - whether keying the empty workspace's window, which fronts Kosmos, raises its border
    windows over other apps' windows;
  - whether Hide Others in another app leaves the borders on screen;
  - how far the border lags a window dragged by its title bar, whose moves WindowServer
    may not report while the button is down ([displays.md](displays.md));
  - whether a border steps in time with its sliding window, and the CPU of a relayout of
    Steve's windows with borders against JankyBorders (`script/bench-relayout.sh`, whose
    Kosmos log gives the slide frames' time).
