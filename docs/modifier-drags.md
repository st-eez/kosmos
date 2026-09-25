# Modifier drags

With the modifier held, Option by default, the left button moves the window under the
pointer and the right button resizes it, as Omarchy binds Super with Hyprland's
`mouse:272` and `mouse:273` (Hyprland 0.56.2, `DragController.cpp`). The app under the
pointer gets none of the drag's events.

- The events come from an active event tap on its own thread, for the left and right
  buttons' down, dragged and up events, at the annotated session location. WindowServer
  has named the window under the pointer there with its own hit test
  (`kCGMouseEventWindowUnderMousePointer`, as for focus follows mouse, [focus-follows-mouse.md](focus-follows-mouse.md)), so
  deciding a press reads no window list. KosmosCore's DragGate decides each event on the
  tap's thread, under a lock the main actor holds only to hand it the modifiers, the
  windows and the displays and to end a drag whose press is over, so no event waits on
  the main actor. Section 3 of [overview.md](overview.md#3-primitive-decisions) turns down a keyboard tap because every keystroke would wait
  on the manager. This tap costs each button event one round trip to its thread, which
  answers at once, and it takes no movement without a button down.
- A press is taken when its modifiers are exactly the configured ones, Caps Lock and Fn
  aside, it is on a display, and the window under it is a tiled or floating window of a
  shown workspace (`DragGate.windows`, renewed with each published state). Every other
  press passes untouched: on the Dock, where Option and the right button give Force Quit,
  the menu bar, SketchyBar, the desktop, a dialog or panel, a native fullscreen window or
  a window of Kosmos's own. The log names each modifier press passed on for its window.
  The focus path's key record, a left down far off every display with no mouse up
  ([overview.md, section 3](overview.md#3-primitive-decisions)), passes and changes nothing, during a drag too: a drag that focuses a window
  of an app in the background posts one, as does a focus hotkey during a drag.
- Kosmos takes the press, every movement until its mouse up, whichever button macOS
  names with both down, and the mouse up, whatever the modifiers are by then. The mouse
  up is the one with the press's event number (`kCGMouseEventNumber`, which a press and
  its mouse up share): a mouse up of the drag's button with another number belongs to a
  press that passed while the tap was off, so it passes to the app, which has that press,
  and ends the drag. A press of the other button during the drag passes to the app with
  its mouse up.
- The drag ends at its mouse up. WindowServer turns off a tap that falls behind, passes
  on the event it waited for, and passes every event until Kosmos turns the tap on again.
  When the event it passed was the drag's press, the app has the press, so the drag ends
  and the rest of the press passes too (`DragGate.timedOut`); this rests on WindowServer
  handing the tap one event at a time and reporting the timeout right after the event it
  gave up on, which no live test can provoke. A drag whose press is over by other means
  ends where the pointer is (`DragGate.endIfReleased`): HID's state reads its button up,
  or counts a press of it newer than the drag's (`CGEventSourceCounterForEventType`, read
  as the tap saw the drag's press). The tap asks as it turns on again and at the other
  button's press, and Kosmos at a hotkey, lock, resync or config load. HID reads ahead of
  the tap, so the drag's mouse up can still come after such an end, and the tap takes it
  if it comes before the button's next press. A press of the drag's own button ends the
  drag too, where the pointer last moved. A hotkey during a drag whose press goes on ends
  Kosmos's drag at once, and the tap takes the rest of the press, which changes nothing.
- HID's state (`kCGEventSourceStateHIDSystemState`) holds the presses of the mouse and
  trackpad. The combined session state holds those other processes post as well, which
  would read as presses newer than the drag's, and on Steve's Mac on 2026-09-25 it
  counted 15019 left downs and 15141 left ups, where HID counted 15059 of each. A drag
  begun by a press another process posts into the session reads as over at the first
  check. A press HID counted before the tap saw the drag's own counts as the drag's. The
  tap sees that press next and it ends the drag, unless WindowServer turns the tap off
  first; then the drag takes the press's movements until its mouse up, which passes. No
  public call says which press HID counted when.
- Each movement goes to the main actor in order, and AppWorker merges the frame writes an
  app has not taken yet. The debug log gives each movement's lag from the tap; if a fast
  drag lags, coalescing the movements comes back with that measurement.
- The press focuses the window, as a command stamped when the tap saw it, as Hyprland's
  `dragBegin` focuses the window it grabs. Nothing moves until the pointer is more than
  10 pt from the press, as for the title-bar lift (`TitleBarDrag.liftDistance`); from then on
  the window catches up with the pointer and follows it. Omarchy leaves
  `binds:drag_threshold` at 0, so Hyprland lifts at the press.
- The left button lifts a tiled window as a title-bar drag does ([displays.md](displays.md)): the other
  windows fill its space, it drops at the mouse up by the same dwindle rule, and a hotkey
  drops it first. Kosmos writes the lifted window's position at each movement, keeping
  the point the press grabbed under the pointer, where Hyprland centers a lifted tile on
  the pointer. A floating window moves freely, and one whose center crosses onto a
  display showing another workspace joins that workspace, as in a title-bar drag.
- The right button on a tiled window moves the tile's edges on the sides of the window's
  center the press was on, left or right and top or bottom, as Hyprland's DragController
  picks the grabbed corner. A tile with no neighbour on that side moves its edge on the
  other side, as Hyprland's dwindle `resizeTarget` does with `smart_resizing` on
  (Omarchy's setting) for a window at the display's edge, and an axis with neighbours on
  neither side moves nothing. Each edge goes where the pointer takes it from the tile's
  edge at the press, through `Workspace.moveEdge`, which takes the space from the
  neighbour across the edge alone, as i3's resize with the mouse and Hyprland's two node
  splits do, and stops at the minimums `resize` keeps. An edge stopped at a limit follows
  the pointer back.
- The right button on a floating window moves the edges at the corner nearest the press
  and keeps the others, never below the window's recorded minimum or 20 pt, Hyprland's
  `MIN_WINDOW_SIZE`.
- Each movement writes frames and does nothing else. A plan carried out per movement
  would read every shown floating window's frame from WindowServer ([displays.md](displays.md)), and
  that check leaves the dragged window where the drag puts it. The bar hears of a resize
  at the mouse up.
- `mouse-modifier` names the modifiers as bindings do, joined by `-`, and `off` turns
  modifier drags off. Kosmos makes the tap when they first turn on while it manages
  windows. Turned off at a reload, the tap stays and begins no drag, so each button event
  still visits it until Kosmos quits; stopping the tap once no press is held would end
  that.
- An active tap filters events, which macOS allows a process with Accessibility
  (`CGPreflightPostEventAccess`); yabai, skhd and Rectangle make theirs with
  Accessibility alone. Kosmos makes the tap only after the Accessibility grant and logs
  both grants as it does. A refused tap is logged, and modifier drags stay off until the
  next config load makes it again.
- The `NSEvent` global monitors of the left button ([geometry.md](geometry.md)) leave out a press and a
  mouse up they hear during a left modifier drag, whose own end drops its window, and the
  log says when they hear one. During a right drag the left button's press and mouse up
  pass to the app, and the monitors handle them as at any other time.
- Open until the live test:
  - whether macOS asks for Input Monitoring. It gates listen-only taps ([focus-follows-mouse.md](focus-follows-mouse.md)), so
    Kosmos does not expect it here, but macOS 27 asked a process with neither grant for
    it at a listen-only mouse tap;
  - whether the global monitors hear the events the tap takes;
  - whether WindowServer takes an active tap at the annotated location and fills in the
    window under the pointer for button events there. If not, a tap at the session
    location with a hit test per modifier press (`SLSFindWindowAndOwner`, as yabai's
    `window_manager_find_window_at_point`) stands in for the field;
  - whether a taken press still activates its app; Kosmos focuses the window either way;
  - whether a press and its mouse up carry the same event number at the annotated
    location, and whether two presses carry different ones. The log gives each drag's
    press number, and says when a mouse up with another number ends a drag, which should
    not happen without a timeout. Numbers that repeat from press to press would let a
    drag ended at the tap's turn-on take a later plain press's mouse up;
  - whether the focus path's key record counts as a press in HID's state. If it did, a
    drag of a window of an app in the background would end at the other button's press
    and as the tap turns on again;
  - how smoothly apps follow a position write per movement, and whether a fast drag lags.
- Left out:
  - Snapping, which Omarchy leaves off, `general:resize_corner` and keeping a floating
    window's aspect ratio, until a config asks for them.
  - Resizing tiles on a workspace with a fullscreen window, which resizes nothing: the
    fullscreen window covers them. Hyprland ends fullscreen once a drag passes its
    threshold; `toggleFullscreen` at the lift distance would do the same.
  - A floating window's minimum before its app shows one. Shrunk past it by its left or
    top edge, the window's right or bottom edge moves out, since the app keeps its size
    and the position was written for the size asked. A minimum the ledger records clamps
    it from then on.
  - Omarchy's Super and scroll wheel bindings, which switch workspaces.
