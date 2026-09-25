# Focus follows mouse

Kosmos replaces AutoRaise for hover focus. AutoRaise needed a local patch to key the
hovered window instead of the app's most recent one; Kosmos's focus path already does.

- The window under the pointer takes focus as soon as the pointer enters it, through the
  same exact-window focus request as a focus command, as Hyprland's `follow_mouse = 1`
  does.
- That request raises the window, as every private focus request does, inside the front
  app and after the key record for another app ([focus.md](focus.md)). A floating window the
  pointer enters comes up over the tiled windows it overlaps, whichever app was front. The
  pointer is over a part of the window that was on top already, and the raise brings up
  the rest.
- Focusing another app's window activates the app, which costs macOS about 94 ms of CPU
  outside Kosmos ([overview.md, section 2](overview.md#2-what-the-fork-measured)), so a pointer swept across windows of several apps activates
  each of them. Steve accepted that cost, since in a tiling layout the pointer crosses
  few windows on its way. AutoRaise waited for the pointer to rest in a window (`delay=2`
  at `pollMillis=50`, 50 to 100 ms). The delay is one constant, `Controller.dwell`, set
  to zero; at 50 ms a window takes focus only once the pointer has stayed in it that long.
- Pointer movement arrives through a listen-only event tap on its own thread, at the
  annotated session location, for mouse moved events only. A pointer at rest costs
  nothing, and the tap is off while focus follows mouse is. AutoRaise polls 20 times a
  second.
- Each event names the window under the pointer as WindowServer's own hit test found it
  (`kCGMouseEventWindowUnderMousePointer`, filled in at the annotated location), so moving
  the pointer queries no window list, and the stacking of overlapping floating windows is
  WindowServer's answer. A hit test of the model's frames would need a stacking order the
  model does not keep. The tap's callback passes a movement on to the main actor only when
  it enters another window or another display than the last movement passed on, with
  Control up (KosmosCore's PointerGate). The gate tells the display from the event's
  location and the session's displays, which the main actor gives it at each change.
- The main actor focuses the window only when all of these hold (KosmosCore's
  `FocusFollowsMouse.skip`, whose reason for skipping is logged):
  - It is a tiled or floating window of a workspace a display shows, or a native
    fullscreen window. Menus, the bar, panels and dialogs, the Dock, Mission Control's
    windows, Kosmos's own windows and the windows of a workspace a switch is hiding leave
    focus where it is.
  - Its app is not ignored.
  - It is not the focus intent and key already. When a panel or dialog took key from the
    focus intent, the pointer coming back into the intent keys it again.
  - No command was received after the movement.
  - No process other than the front one and Kosmos holds the key window
    (`Controller.keyHolderApartFromFront`). With Raycast, Spotlight (whose process is
    "Siri", an accessory app), Notification Center or Control Center open, the front
    process stayed Ghostty and only the process holding the key window changed
    (`kosmos-probe key-holder`, 90 s at the desk on 2026-09-24). Focusing a window would
    take the key window from such a panel and close it. AutoRaise left the front apps its
    `stayFocusedBundleIds` listed alone. An app that is front with its own window keeps
    hover focus on, even an accessory app's, as Raycast's settings, a menu bar app's
    settings or Hammerspoon's. The front process comes from LaunchServices, 54 us
    at the median, and the key focus process from WindowServer (`SLPSGetKeyFocusProcess`),
    120 us at the median and 42 ms at most, so both are read last, only when the window or
    an empty workspace would take focus. A window the pointer entered while a panel held
    the key window takes focus only when the pointer enters it again, so what a launcher
    opened keeps the focus.
- The pointer focuses a native fullscreen window it enters, as Omarchy's `follow_mouse`
  does, and never focuses anything over one, display by display. On a display that shows
  a fullscreen Space, the windows under the pointer are the fullscreen window and its
  app's panels, which stay skipped, and WindowServer's hit test never names a window
  behind them. AeroSpace's focus follows mouse raised tiled windows over fullscreen video.
  The fullscreen window stays parked and the session's focus stays where it was, as when
  the user clicks it; its report, which Kosmos otherwise leaves unclassified, consumes the
  request's echo. A fullscreen window key on another display leaves this display's
  windows free: the window under the pointer is on screen, so keying it takes no display
  out of a fullscreen Space, and a hover focus passes the fullscreen gate of [focus.md](focus.md)
  as a command does. Live on 2026-09-24, the pointer entering Moonlight in native
  fullscreen on the built-in display skipped it as untiled, which this replaced.
- When the pointer enters the desktop of a display whose shown workspace has no windows,
  that workspace takes the focus as `workspace` gives it: Kosmos keys its empty workspace
  window on that display, with no switch and no pointer move, as Hyprland's
  `follow_mouse` moves the monitor focus (`FocusFollowsMouse.emptyWorkspace`). Over a gap
  or the desktop of a display whose workspace has windows, focus stays where it is, as in
  Hyprland. The hit test names no managed window there, which is why the gate passes on a
  movement onto another display. The desktop is no window, or one at the desktop icon
  level or below: Finder's desktop window, the wallpaper and the display's backstop
  (`FocusFollowsMouse.isDesktop`), whose level is read from WindowServer only on this
  path. A window Kosmos does not manage over that display keeps the key window: a
  slideshow, a game, the menu bar, or a panel over a native fullscreen window, where the
  empty workspace's focus would also pass the fullscreen gate as a command. Live on
  2026-09-24, moving from workspace 1 on the main panel onto the left panel, which showed
  empty workspace 7, did nothing before this.
- A hover focus counts as a command stamped when the tap saw the movement: reports of the
  user's activations before it are stale, and its request's echo is consumed like any
  other. The spec models it so, and its `hover` and `hover-settles` configs pass, as does
  `split-hover` with its `settles` and `notice` configs for as long as they ran
  (tla/README.md). With the hover unstamped, TLC found a click made before the hover but
  reported after it adopted, and focus left the window the pointer was in.
- Holding Control pauses focus follows mouse, as AutoRaise's `disableKey` did. Control is
  read from each movement's flags, so the tap takes no keyboard events. A movement with
  Control held changes nothing, so after Control is released the next movement focuses
  the window under the pointer. Nothing is focused while a mouse button is down, because a
  movement with a button down is a drag event, which the tap does not receive, nor while
  a tiled window is lifted ([displays.md](displays.md)) or a modifier drag is on ([modifier-drags.md](modifier-drags.md)): the
  pointer is the user's during a drag.
- The pointer follows focus the other way too, with `mouse-follows-focus`, when the
  keyboard moves focus to another window or moves the focused window. A workspace switch
  command moves it only when the focus is on another display than the pointer
  (KosmosCore's `Command.movesPointer`), and a keyboard activation of a window always
  does. Omarchy on the development Mac centers the pointer only when focus moves between
  windows of one workspace, and Steve's AeroSpace config chained
  `move-mouse window-lazy-center` onto hotkey bindings only.
  - A hotkey's `focus` or `focus-monitor`, within the workspace or across to the workspace
    another display shows, centers the pointer on the window it focuses.
  - A hotkey's `move`, `swap` or `move-node-to-monitor` brings the pointer along with the
    focused window, and `move-node-to-workspace` without `--focus-follows-window` centers
    it on the window focused next. With focus follows mouse, a pointer left behind would
    focus the neighbour on the next bump.
  - Command-Tab, or a launcher's hotkey that activates an app, centers the pointer on the
    window it activates, on a shown workspace or one Kosmos follows it into, on the
    pointer's display too: it names a window, as `focus` does, where a workspace switch
    names a workspace. Live on 2026-09-24, Opt-Shift-S activated Spotify on workspace 6,
    which the left panel then showed in place of empty workspace 7, and the pointer stayed
    on the main panel; and Command-Tab from workspace 7 to Spotify on workspace 6, both on
    the left panel, left the pointer where it was, before this. Kosmos tells Command-Tab
    from a click when it handles the activation: a key went down within the last second,
    and after the last left or right mouse down and the last pointer movement
    (`CGEventSource.secondsSinceLastEventType` in the combined session state). With focus
    follows mouse the user seldom clicks, so a key press long ago would otherwise pass for
    Command-Tab when an app activates itself. The read takes no event tap, and the log
    gives the times. A Command-Tab switcher held open for over a second reads as a click.
  - A new window its app keyed brings the pointer whatever input came before, as a
    keyboard focus change does, when Kosmos follows it to its rule's hidden workspace
    ([displays.md](displays.md)) or it becomes the focus on a shown workspace of another
    display than the pointer. An app can open its first window seconds after the
    launcher's hotkey, past the second the Command-Tab test allows. Live on 2026-09-25,
    Chrome launched from Raycast on workspace 8 on the built-in display keyed its window
    5.2 s after the hotkey, Kosmos followed it to workspace 4 on the main panel, and the
    pointer stayed on the built-in display, before this. On the pointer's display the
    pointer stays, as it does for a new window with no rule. A window that was there when
    Kosmos launched leaves it too, so the pointer stays where it is at startup. A window
    its app keys only after Kosmos admitted it on a shown workspace is judged as a
    Command-Tab. A launch by an agent or a script that brings the app front brings the
    pointer too, as it brings the follow.
  - A click on the Dock picks an app as Command-Tab does, and the pointer goes to the
    window it activates the same way. Left on the Dock, the pointer would focus every
    window it crossed on the way up. Steve clicked Teams in the Dock on 2026-09-25, and
    the pointer stayed there. The activation counts as a Dock click when the last left
    mouse down came within the last second, after the last key and right mouse down, and
    landed on the Dock's window at the Dock's level (`ActivationInput.bringsPointer`). The
    pointer may have moved since. With autohide on, the Dock's one window spans the whole
    built-in display at level 20 (`CGWindowListCopyWindowInfo` on 2026-09-25), so its
    frame says nothing. So as each left mouse down lands, Kosmos asks WindowServer's hit
    test for the window under it (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`),
    and reads that window's row at each activation it handles. A press off every display,
    as the focus path's synthesized one, names no window. The hit test runs at the press
    because the Dock starts to hide once the pointer leaves it, which can be before the
    app reports its window key. With the Dock hidden, the hit test passed through its
    window and named the windows beneath, Finder's desktop at the display's bottom edge; a
    click on a shown Dock's icon is unmeasured. A click on the Dock's menus, Mission
    Control or Launchpad is left out, at other levels.
  - A window Kosmos follows back to its place ([tree.md](tree.md)) brings the pointer by the
    same test, read as Kosmos handles the return: a Dock click that unhides its app or
    restores it from the Dock, and Command-Tab to a hidden app. macOS keys such a window
    while it is still parked, so its key report is no activation Kosmos handles, and the
    pointer stayed on the Dock before this. A key that takes a window out of native
    fullscreen, or makes an app order a closed window in again, brings it too. Whether a
    window restored from the Dock reports its return within the second is unmeasured.
  - A workspace switch command on the pointer's display leaves the pointer where it is:
    `workspace` by name, `next` or `prev`, `workspace-back-and-forth` and
    `move-node-to-workspace --focus-follows-window`.
  - A keyboard focus change that lands on another display than the pointer brings the
    pointer, whether or not that display's workspace switched: alt-N, alt-shift-N and
    `workspace-back-and-forth` to a workspace another display shows or hides. Left behind,
    the pointer sits over a tile of its own display that the next bump would focus. The
    focus is on the display of the focused workspace (`Session.focusIsOnAnotherDisplay`).
    When that workspace is empty, the pointer goes to the display's center, as Hyprland's
    `focusmonitor` puts it.
  - Every command carries its source, a hotkey or the CLI, and a command from the CLI
    leaves the pointer, so a click on the bar's workspaces, a script or a launcher running
    `kosmos` never moves it. Neither does a click Kosmos follows or adopts, other than on
    the Dock, a hover focus, nor a layout, resize or `join-with` command.
  - As with AeroSpace's `window-lazy-center`, the pointer moves only when it is outside the
    window, or the empty workspace's display. A tile's frame is the layout's after the
    change, the one Kosmos is writing, which the app's worker may not have applied yet;
    AeroSpace's binding slept 50 ms before it read the frame. A floating window's is the
    last frame the inventory heard. So the move reads nothing from WindowServer and runs on
    the main actor. While a window is lifted or a modifier drag is on, the pointer stays
    ([displays.md](displays.md) and [modifier-drags.md](modifier-drags.md)).
- Focus follows mouse leaves Kosmos's own pointer moves alone. After a move, the gate takes
  the next movement as the place the pointer landed and passes nothing on, whether or not
  the move posts an event of its own. A movement the tap passed on before a command is
  stale. The ceiling: a movement made before the move that reaches the tap after it is
  taken as the landing place, and the movement after it then enters the window Kosmos
  focused, which at most requests that window again.
- On macOS 27, creating a listen-only tap for mouse moved events alone made macOS ask a
  process with neither Accessibility nor Input Monitoring for Input Monitoring ("would
  like to receive keystrokes from any application"), and that tap received nothing, while
  the same tap under the terminal's grants received about 5,800 movements in the same
  minutes. Apps with Accessibility alone run listen-only taps: AltTab at the annotated
  location (`src/events/WindowAttentionEvents.swift`, whose tap creation fails without
  Accessibility) and Loop for mouse movement (`PassiveEventMonitor.swift`). Whether
  Kosmos's grant is enough is open until a live test settles it. The tap is created only
  when focus follows mouse is first turned on, and Kosmos logs whether Input Monitoring is
  granted when it creates the tap, whether the tap is enabled when it turns on, and when
  the first event arrives. When macOS refuses the tap, Kosmos logs an error, and
  `focus-follows-mouse on` exits 1 and says to allow Input Monitoring.
- Whenever focus follows mouse turns on without Input Monitoring
  (`CGPreflightListenEventAccess`), at a config load or a command, the setup window lists
  Input Monitoring ([onboarding.md](onboarding.md)), whether the tap was created or not: a created tap may
  hear nothing, as above. Once it is granted, Kosmos makes the tap again if the last one
  predates the grant, a grant after a revoke included, at the window's next check or the next turn on or config load. If
  macOS offers to quit and reopen Kosmos after the grant, the quit reaches NSApplication's
  terminate as Quit Kosmos does, by Apple event or SIGTERM, so hidden windows come back in
  process; the guardian covers a kill.
- Open: if the live test asks Kosmos for Input Monitoring, pointer movement comes from
  `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` instead, and only PointerTap's
  event source changes; the gate and everything after it stay. AeroSpace's and Amethyst's
  focus follows mouse and Rectangle's drag snapping use such monitors, and their code asks
  only for Accessibility. AppKit installs the monitor as a handler on HIToolbox's event
  monitor target (AppKit's imports and disassembly on macOS 27), which Carbon's
  documentation of `GetEventMonitorTarget` describes as WindowServer copying user input
  events sent to other processes into this one's event queue, so it is no event tap.
  NSEvent's header requires Accessibility for key events and names nothing for mouse
  events. Against the tap it gives up two things:
  - Delivery is on the main thread, so every movement wakes the main actor and queues with
    hotkey events. The gate still runs first, and only a movement into another window does
    more.
  - The event may not name the window under the pointer; whether its `cgEvent` carries the
    annotated field is for the live test. If not, `NSWindow.windowNumber(at:
    belowWindowWithWindowNumber: 0)` returns WindowServer's hit test for a point, including
    other apps' windows, at one WindowServer call per movement. It takes the event's
    location as the monitor gives it, in screen coordinates. Branch `ffm-monitor` holds this
    variant.

  The mask stays mouse moved, so a drag still sends nothing (AeroSpace notes the same),
  and Control still comes from each event's modifier flags. An active tap is the other way
  out: Rectangle, skhd and yabai create default taps with Accessibility, and it keeps the
  tap's thread and field, but every pointer event would wait on Kosmos's callback, which
  [overview.md, section 3](overview.md#3-primitive-decisions) rejects for the keyboard.
- `focus-follows-mouse = true` turns it on, and `focus-follows-mouse-ignore-apps` lists
  apps by bundle identifier or name, as AutoRaise's `ignoreApps` did; Steve's AutoRaise
  ignored Google Chrome for Testing. The command `focus-follows-mouse on|off|toggle`
  switches it until the next config load.
- Left out:
  - The pointer after `join-with`, layout and resize commands, which can leave it over a
    neighbour of the focused window. Steve's AeroSpace bindings left it there too; if a
    bump then focuses the neighbour in practice, they join `Command.movesPointer`'s list.
  - A minimum movement. AutoRaise's `mouseDelta = 2` kept 1 px jitter from raising
    AeroSpace's parked slivers, and Kosmos parks none. If a still hand moves focus, a
    minimum distance from where the pointer last counted, in PointerGate, brings it back.
  - A pause key other than Control, and a delay setting, until a user needs one.
  - Open menus. Moving the pointer off an open menu onto a window focuses that window and
    closes the menu, and with no delay a short overshoot does it. The front app's own menus
    leave the key window with the front process, so the key holder check leaves them to
    this. If the live test shows it, one SkyLight window list read per window entered, for
    a window at the pop-up menu level on screen, would keep the menu open.
  - Keeping floating windows over a tile the pointer enters. Inside the front app only
    AXRaise keys a window, and for another app AXRaise follows the key record ([focus.md](focus.md)),
    so the tile comes up over any floating window it overlaps, which Hyprland keeps
    on top. Focusing or clicking a tile does the same. With SIP on, no process can set the
    level of another app's window, and raising the floating windows again after the raise
    would key one of the front app's, or reorder only a background app's own windows. A
    Space shown above the desktop's keeps a floating window on top, and covers every menu
    and all system UI too (`kosmos-probe float-layer`, on the floatprobe branch). A covered
    floating window stays in reach of `focus` in a direction ([tree.md](tree.md)), where hover
    cannot reach it. If it bothers in practice, the path is yabai's
    `window_manager_focus_window_without_raise`, which AutoRaise carries under FOCUS_FIRST
    (AutoRaise.mm:204): an AppKit-defined record (type 0x0d) with 0x8a = 0x02 to the app's
    key window, 10 ms later one with 0x8a = 0x01 to the target, then the private front and
    the key record. It would replace AXRaise on the worker, and the raise after a key
    record, for a hover focus of a tile, the echo recorded just before, once
    `kosmos-probe keying` shows it keys 20 of 20 in the front app with the window order
    unchanged.
