# Borders

Kosmos draws a border around each tiled and floating window on screen, as Omarchy's
Hyprland does, in place of JankyBorders. JankyBorders runs in a process
of its own and draws from WindowServer's events, so it knows nothing of workspaces,
concealment or slides. In Steve's trial of the slide on 2026-09-25, its border scaled with
the sliding window, whose Space it copies its border into, and near a display's edge the
border showed on the neighbouring display, drawn at the window's frame while the slide
showed the window elsewhere. Kosmos knows each
window's frame, focus, workspace, concealment and fullscreen state, and during a slide the
frame the slide shows the window at.

- Borders are on by default ([config.md](config.md)): a 4 point line around the focused window in
  the macOS accent color, and none around the others. `borders = false` turns them off, as
  `animations = false` turns off slides, and a `[borders]` table sets `width`, `active` and
  `inactive`. The accent is `NSColor.controlAccentColor` in sRGB under Kosmos's
  appearance. Kosmos reads it again when AppKit posts
  `NSColor.systemColorsDidChangeNotification`, which a new accent color in System
  Settings brings, and when its appearance changes between light and dark, which show the
  accent in shades of their own.
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
  every other window `inactive`. The color changes with the model's focus: at a command, a hover or a key
  window report Kosmos adopts, before macOS's key change lands. A fully transparent color
  draws no border and makes no window, so with Steve's transparent `inactive` only the
  focused window has one.
- A bordered window gets its border only while it is on screen: not concealed, as a
  switch's incoming windows are until the batch that reveals them confirms, and ordered
  in, so the border goes as soon as WindowServer orders a window out, before Kosmos parks
  it. A window that a batch still in flight conceals counts as concealed: after a switch
  to workspace B and straight back to A, A's windows get their borders once the batch
  that conceals them and the one that reveals them have both finished. A window on no display, as a concealed one reads, gets none. So the border hides at
  a conceal and a switch, a minimize, a hide, native fullscreen and Kosmos's fullscreen,
  and shows again at the reveal, the return or the toggle back. The outgoing workspace's
  borders go as Kosmos plans the switch, before its batch conceals the windows, and the
  incoming ones come when the batch confirms, after the windows show.
- The shape is JankyBorders' line (`border.c`, Steve's fork): `width` points wide and
  centered on the window's edge, so its outer half lies outside the window, and of its
  inner half only the point next to the edge shows, over the window's own edge. With
  width 4 that is 2 points outside and 1 inside. The corners are concentric with the
  window's: WindowServer's corner radius for the window, read with its row
  (`SLSWindowIteratorGetCornerRadii`), plus half the width outside, and the radius less
  1 point inside. A titled window's corners are rounded 16 points on macOS 27 (26A428,
  `kosmos-probe borders`), and a square window gets a square border. JankyBorders'
  `style=round` and `hidpi=off` have no key: the corners always follow the window's, and
  Core Animation draws at the display's resolution. Its square style is left out: at a
  16 point radius a square ring either shows the desktop in each corner or covers the
  window's content there.
- Each border is a window of Kosmos's own (`KosmosApp/Borders.swift`): borderless, clear,
  without a shadow, ignoring the mouse, never key or main, hidden in Mission Control and
  out of the window cycle (`.transient` and `.ignoresCycle`, as the empty workspace's
  window), and kept on screen when Hide Others in another app hides Kosmos
  (`canHide = false`). The ring is its layer's border, which Core Animation draws with no backing
  store: a border around 1200 by 800 points added nothing to the probe's memory
  footprint. A border hidden is ordered out and goes to a pool, and the next window
  bordered reuses it, so Steve's one border window moves from window to window with the
  focus.
- The border is ordered directly above its window with `NSWindow.order(_:relativeTo:)`,
  which takes another app's window: in `kosmos-probe borders`, in each of six runs on
  2026-09-25, the window list showed the border right above the child app's window and
  below the child's other window that covered it, so a window over the target covers its
  border too. When the child raised its window, WindowServer posted 808 (reordered) and
  815 for it and left the border below, under the other window the raise put the target
  over. So at each 808 for a managed window the inventory calls `onReordered`, and Kosmos
  orders that window's border above it again: 0.024 ms at the median over 100 orders.
  Ordering the border posted no event for the target, so the two never feed each other.
  The border's window level is its target's. Setting another level can move the border
  within the stacking order, so when the target's row shows another level, Kosmos orders
  the border above the target again.
- WindowServer's hit test passes through a border: `NSWindow.windowNumber(at:)`, the
  window a mouse down at a point would hit, named the target at a point 0.5 points inside
  its edge under the ring, and at a point 1 point outside it, in the target's resize
  margin. So clicks and resizes by the edge reach the window.
- A border is in its window's Space. In the probe, a new border window joined the current
  Space of its display, kept its Space while ordered out and in, and stayed in another
  display's Space after it was ordered above its target again; moving it 10 points put it
  back in its own display's current Space. A display's current Space can be another app's
  native fullscreen Space, so whenever a border is shown for another window or its
  display changes, Kosmos reads its Spaces and its target's off the main thread, since a
  read can wait out a Space transition, and moves the border to its target's ordinary
  Space with `SLSMoveWindowsToManagedSpace` when it is in none of them. A border moved to
  another display's Space was there when read back. The target's Spaces can include the
  holding Space or a slide's animation Space, whose transform would draw the border too,
  so Kosmos chooses from the displays' ordinary Spaces alone.
- The border follows the frame WindowServer last reported for its window: the inventory's
  row, read after each change event, so it follows every move and resize, the user's,
  the app's and Kosmos's own. It trails the window by the event's way to Kosmos and the
  read of the row, as JankyBorders trails it by its event's way.
  The Controller shows the borders again after each change of the model (`publishState`),
  each batch's completion, each change of a window's frame, level or corner radius or of
  whether it is ordered in, and each slide frame; nothing polls. A border that is the same as shown costs no
  AppKit call, and a move at the same size calls `setFrameOrigin`, 0.014 ms at the median
  against 0.158 ms for a resize (the probe, 200 of each).
- The border shows on the display that holds the largest part of its window, cut to that
  display, so it never shows on a display the window is not on. At a display's edge it
  is cut there, as the window is.
- During a slide ([geometry.md](geometry.md)), the border follows the frame the slide shows the window at,
  as of the display frame its display's link last stepped (`Slides.shown`), at that frame's
  alpha, so a pop fades it in and scales its frame with the window, at the same line
  width. Its window then covers its display, and each display frame moves only the
  ring's layer, which took a fourth of the main thread's time that moving the window did
  (below). The border stays in the desktop Space, out of the animation Space and its
  transform, so its line keeps its width and its display. The animation Space draws above
  the desktop Space, so during the slide the window covers the border's point inside its
  edge, and the line shows 1 point narrower until the slide ends. A new window waiting for
  its write to land, transparent, shows no border yet.
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

  Following four visible borders cost the probe 4.5 and 8.9 ms a relayout, and the main
  thread 2.9 and 5.5 ms, against 5.9 to 7.1 ms for JankyBorders following the same
  windows. During slides, each border step took 0.08 and 0.14 ms of the main thread with
  the layer moved, against 0.32 and 0.49 ms with the window moved. WindowServer took 225
  to 288 ms each half second, at rest too, so its share is rough: about 42 and 48 ms more
  a relayout with the windows moved at each display frame, 13 and 15 ms more with the
  layers moved, and nothing measurable for borders following change events. Kosmos's
  slide log gives its display link's callback time, which includes the borders.
- Open until the live test:
  - whether the border follows a new accent color and a switch between light and dark;
  - whether focus follows mouse and modifier drags, which read WindowServer's hit test
    from each event (`kCGMouseEventWindowUnderMousePointer`), see through a border as
    `NSWindow.windowNumber(at:)` does;
  - whether a border stays hidden in Mission Control and out of Command-backtick, and out
    of launchers' and window switchers' window lists, and leaves with its Space when a
    native fullscreen Space or another desktop shows;
  - whether a border created or moved while a native fullscreen Space is on its display
    lands in the fullscreen Space before Kosmos moves it, and for how long;
  - whether keying the empty workspace's window, which fronts Kosmos, raises its border
    windows over other apps' windows;
  - whether Hide Others in another app leaves the borders on screen;
  - how far the border lags a window dragged by its title bar, whose moves WindowServer
    may not report while the button is down ([displays.md](displays.md));
  - whether a border steps in time with its sliding window, and the CPU of a relayout of
    Steve's windows with borders against JankyBorders (`script/bench-relayout.sh`, whose
    Kosmos log gives the slide frames' time).
