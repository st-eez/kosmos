# Kosmos design

Draft, September 23, 2026.

This design comes out of a month of optimizing a personal AeroSpace fork: native window
hiding, preloaded workspaces, a TLA+ model of workspace switching, and trace-based timing
of every phase of a switch. Ten research notes then compared how AeroSpace, yabai,
Amethyst, rift, paneru, FlashSpace, AltTab, Loop, Hammerspoon, SketchyBar, skhd and i3
solve each part. They will be published under `docs/research/`.

## 1. Goal and constraints

Switch workspaces in a few milliseconds of Kosmos's own work. Keep process launches,
file writes and menu bar redraws off the switch path, and never lose a hidden window.

- SIP stays enabled. Private SkyLight calls are used only where they work from an ordinary
  process with Accessibility permission.
- Tree tiling only, with i3-style containers.
- macOS 27 only, Apple Silicon. Swift 6.4 with a small C shim for private calls.
- No external runtime dependencies.
- Logical workspaces, not one macOS Space per workspace.

## 2. What the fork measured

| Finding | Consequence |
| --- | --- |
| An optimized fork switch costs 35 ms of server time. About 21 ms is its hiding protocol (a Space created per switch, confirmation polling), 6 to 7 ms is journal writes with fsync, and 2 ms is window identity checks | Create Spaces once per session, confirm with one read, keep recovery state in memory-mapped memory |
| The bridged SkyLight operations are the only SIP-on way to move another app's windows between Spaces. Submitting one takes 0.03 to 0.10 ms | The cost is in confirmation, not the call |
| Only Accessibility can set another app's window frame. One set takes under 1 ms at the median and a full frame 2 ms (p99 39 ms). The first AX call to an app costs 11 to 35 ms | Write only changed frames, cache AX elements, isolate slow apps |
| A full window discovery after every command costs 20 to 28 ms of main-thread time, about 40% of the manager's CPU per switch | Track windows through WindowServer notifications instead |
| Every focus change makes an app frontmost, which costs macOS's app-usage daemons about 80% of one core at four switches per second | Skip activations that change nothing and coalesce bursts |
| A SwiftUI menu bar label cost 6 to 10 ms of main-thread time per switch. A label that changes width makes macOS 27's MenuBarAgent lay out the whole menu bar, about 60 ms of CPU per switch | A static status item that is never written during a switch |
| A shell hook that notifies a status bar launches 3 to 8 processes per switch; a direct Mach message costs 1 to 4 µs | Push state to the bar from inside the manager |
| Option-only Carbon hotkeys stop while another app holds Secure Input, for example a password prompt | Surface Secure Input, and test which modifiers survive it |
| Pixel-based container weights produce wrong and negative sizes | Store fractions |
| After a conceal or reveal, a check of the holding Space found the change 0 times in 50 each. After one synchronous bridged read, it found it 50 times in 50 each; the read took 1.3 ms median, 3.6 ms at most (`kosmos-probe barrier`) | One bridged read confirms a switch, where the fork polled |
| Bridged Space operations from a process that has not started AppKit do nothing. With `NSApplication` initialized, the guardian restored a concealed window 130 ms after `kill -9`, 100 ms of it a deliberate settle (`kosmos-probe survive-kill`) | The guardian is a prohibited AppKit client with no Dock icon |
| Keying a window of another app costs about 94 ms of CPU outside Kosmos: BiomeAgent 29 ms, spotlightknowledged.updater 15, MenuBarAgent 15, duetexpertd 14, WindowManager 6, ContextStoreAgent 6 and the activated app 8, plus 12 for BetterTouchTool on the development Mac. Five stub apps were keyed back and forth through the focus path, 384 activations against 96 in 73 s each, and the cost is the difference between the two; WindowServer's share was lost in the noise of the desktop in use. The focus call took 4.4 ms at the median and 16.6 ms at p95 (`script/sweep.sh`) | Focus follows mouse keys a window only after the pointer rests in it (section 5.11) |
| Keying a window through the focus path leaves the stacking order alone, and keying another window of the app that is already active leaves its key window unchanged, although the app receives the key record. With AXRaise first, the window was raised and keyed in both cases (`kosmos-probe raise`, stub apps with level 0 and floating windows) | Raise a floating window before a hover focus. Focus within the active app needs a fix in the focus path |

## 3. Primitive decisions

| Area | Decision | Rejected alternative |
| --- | --- | --- |
| Window geometry | Accessibility on one worker thread per app; batched, deduplicated writes with generation ids; one read-back per batch | A shared thread pool, where one hung app stalls every relayout |
| Discovery | Inventory keyed by WindowServer window id, fed by SkyLight window notifications and per-app AX observers; reconcile only the app an event names; a 0.1 ms SkyLight sweep every 2 to 5 s as a backstop | Full discovery after commands: CPU on every switch, and the lock screen looks like every window closed |
| Hiding | Hidden windows gain membership in one concealed holding Space created once per session. A switch is two batched bridged operations plus one bridged read as the barrier | One macOS Space per workspace, which hides windows from Accessibility and binds workspaces to displays. Corner parking, which keeps hidden apps rendering and leaves a visible sliver |
| Recovery | A memory-mapped record of owned Space ids and first-hide window records, with no fsync, and a separate guardian executable in its own process group that Kosmos watches and respawns | A journal rewritten on every switch |
| Focus | Private window-targeted focus in every case: front the process, then post one mouse-down key record far off the window. AXRaise only for windows that can overlap. A serial focus queue off the main thread, with generations and read-back | Public `activate`, which names no window and chose the wrong one in every trial on the development Mac |
| Empty workspace | Front Finder with no key window | Nothing, which leaves keystrokes going to the hidden window |
| Tree | Per-workspace roots, fractional weights, normalization after every mutation, a pure layout function with sway's gap arithmetic, a frame-write filter, and parked windows with restore hints | Pixel weights and per-state containers |
| Hotkeys | Carbon `RegisterEventHotKey` called directly and registered exclusive, checked against system shortcuts at load, delivered to a main thread that does no AX work | A keyboard event tap, which puts every keystroke behind the manager and receives nothing under Secure Input |
| IPC | A Unix socket in a 0700 directory with uid checks and length-prefixed JSON, a CLI that avoids AppKit (1.4 ms launch), and `subscribe` streams of full snapshots | A CLI that links AppKit (about 15 ms launch) |
| Bar | Each state snapshot goes to SketchyBar's Mach port as one event, and the bar never queries | Shell hooks on every switch |
| Config | TOML with a strict schema, all-or-nothing reload, diagnostics with file, line and key path, a `check` command, and built-in display profiles | Lua in process, shell scripts, Swift source |
| Status item | AppKit, a static square icon, the menu built when opened, never written on the command path, optional removal | A SwiftUI `MenuBarExtra` with a live label |

## 4. Architecture

### 4.1 Processes

- **Kosmos.app**, an agent app (LSUIElement) launched at login by a LaunchAgent with
  `KeepAlive`, so a crash restarts it.
- **kosmos-guardian**, a separate executable in the bundle, spawned in its own process group.
  It watches Kosmos with `NOTE_EXIT` and restores hidden windows when Kosmos dies. Kosmos
  watches the guardian and respawns it, and hides windows only while it is alive.
- **kosmos**, the CLI, a client without AppKit for scripts and status bar clicks.

### 4.2 Threads and queues

| Context | Owns | Never does |
| --- | --- | --- |
| Main actor | The model (inventory, workspaces, trees, focus intent), command execution, layout, hotkey dispatch, the bar snapshot | AX calls, waiting on another process, file syncs, process launches |
| One AX worker per app (an actor with a custom executor on the app's run loop) | That app's AX elements, observers, frame writes and reads | Touch the model directly |
| Focus queue, serial | Front-process calls and key records, generation checks | Wait on AX |
| Bridge queue, serial | Bridged Space operations and the barrier read | Run past its time budget |
| IPC queue | Socket I/O, subscriber outboxes, Mach sends to the bar | Block the main actor |
| SkyLight notification callback | Copy the payload and hand it to the main actor | Anything else |

The main actor waits on a worker only with a deadline of about 30 ms. A slow app finishes
on its own and never delays another app.

### 4.3 A workspace switch

1. A hotkey or socket command arrives. The main actor updates the model: the new visible
   workspace with a new switch generation, and a focus intent with a new focus generation.
2. The incoming workspace was laid out while hidden, so its frames are usually current.
   One batched SkyLight query validates its windows; layout runs only if something changed,
   and changed frames go to their apps' workers.
3. The bridge queue sends the reveal of the incoming windows and the conceal of the
   outgoing windows back to back, then the barrier read. Revealing first shows windows of
   both workspaces for the length of one bridged operation; concealing first would show an
   empty desktop for the same time.
4. Once the barrier confirms the target window is revealed, and the switch generation is
   still current, the focus queue fronts the target, or Finder with no window for an empty
   workspace, and reads back the key window.
5. The main actor publishes one bar snapshot and one `subscribe` frame.

A switch launches no process, writes no file and leaves the status item alone. Everything
Kosmos causes (a hide, a reveal, a frame write, a focus request) is recorded as an
expected echo and consumed before any notification is treated as the user's.

Target, to be confirmed by the probes in section 6: a few milliseconds of Kosmos's own
work, plus WindowServer's time for two bridged operations and one activation (about 7 ms,
off the main thread).

## 5. Components

### 5.1 Inventory and events

- Windows are keyed by WindowServer id, and apps by pid plus process start time.
- Events come from three sources:
  - SkyLight window notifications on Kosmos's own connection: created, destroyed, ordered
    in and out, moved, resized, Space and session changes. The watch list is always sent
    whole.
  - One AX observer per app: creation, focus, main window, title, destroy and minimize.
  - NSWorkspace app lifecycle events, plus a process exit source for each app.
- Only WindowServer evidence or app exit removes a window. AX silence, AX errors and the
  lock screen never do, and while the session is locked, creation and destruction wait.
- A new window becomes managed when it is ordered in, has no parent window, sits at level 0
  and passes the popup and dialog checks. Apps whose AX is late get bounded retries.

### 5.2 Geometry

- Layout compares each target with the last confirmed frame and the pending target.
  Unchanged windows get no write, and each window keeps only its newest target.
- When the size changes, write size, then position, then size again; otherwise write the
  position alone. Read the frame back once per batch.
- A window that refuses a size keeps its observed minimum. Kosmos doesn't retry that size
  until the target changes.
- AX calls time out after 1 s, reads after 50 ms. An app that times out is backed off and
  probed.

### 5.3 Hiding and recovery

- Create the holding Space once per session, and record its id in the durable record
  before the first window enters it.
- Hidden windows keep their ordinary Space membership and gain holding membership, so
  Command-Tab still selects the right window. Only an app's other concealed windows lose
  ordinary membership.
- There is no fallback to corner parking. At the first unconfirmed bridged operation:
  restore every hidden window, stop hiding, report the cause, and retry at the next switch.
- Recovery empties each recorded Space, sends stranded windows to their display's current
  Space, destroys the Spaces and clears the record. Every step can safely run twice.

### 5.4 Focus

- There is one current focus intent, identified by a focus generation. A switch has its own
  generation, so a focus change adopted during a switch leaves the switch to finish.
- Every report names the key window. For an app activation, the app's worker reads the
  app's focused window. Hotkeys, socket commands and reports are stamped on receipt.
- Reports are classified in order:
  - An echo is a report of a requested window received after the request. Matching the
    app alone would take a Command-Tab to another window of that app for an echo.
  - A click or Command-Tab received before the latest command is stale. The command wins,
    and its focus is requested again.
  - A window on Kosmos's current workspace becomes the focus intent and is requested
    again, in case an older request of Kosmos's landed after the user's change.
  - A window that was hidden when it became key was reached with Command-Tab, and Kosmos
    follows it to its workspace.
  - A visible window of another workspace is key only during a switch: macOS re-keyed
    after a hide, or the user clicked or Command-Tabbed to a window about to be
    concealed. The switch wins, and its focus is requested again.
- A report that repeats the previous report is dropped. An app activation and the app's
  focused window notification can both report one key change, and a repeat that arrives
  after a newer request would look like the user's and pull focus back.
- The main actor knows the key window only from reports, which lag, so it requests every
  focus. The focus queue skips a request whose window is already key when the request
  runs, judged from the front process and, for a request to the front app, that app's
  focused window, read on its worker within 30 ms. The echo is recorded just before each
  call that changes the key window, so a skipped request leaves nothing that a later
  click could match ([tla/](../tla/README.md), changes 8 and 9). Inside the front app
  the key record changes nothing unless the window is frontmost in its app, so the app's
  worker keys: if AXRaise alone keys the window it records just before the raise, and
  otherwise it raises, then records and posts the key record. For a background app the
  queue records just before the key record that activates it. Neither side records for
  the other's call (change 11); `kosmos-probe keying` settles which front app case
  holds. When a newer
  command for another workspace is already queued, the older one lays out but doesn't
  focus.
- A report from an app that is not the front process when it arrives consumes an echo it
  matches and is otherwise ignored: raising a window in a background app makes some apps
  report it, after a switch that window can be concealed (change 10), and background
  apps report windows they open. The check runs in the observer callback, which waits
  behind a busy worker, so a user's click inside the front app that races Kosmos's
  activation of another app can be judged against the newer front app and missed.
- The private path has a kill switch: a crash guard, and repeated wrong-window read-backs
  disable it.

### 5.5 Tree

- Invariants, checked by `validate()` after every mutation in debug builds and tests:
  - no container except a root is empty or has exactly one child;
  - no `tiles` container nests a `tiles` child with the same orientation (it is spliced
    into the parent at unchanged on-screen sizes);
  - weights are positive fractions;
  - each window has exactly one place.
- First operations: insert, remove, park, unpark, move, swap, join-with, layout, resize,
  balance-sizes, flatten-workspace-tree, fullscreen, floating and tiling, focus direction.
- Returning windows (unminimize, app unhide, leaving native fullscreen) go back to their own
  workspace at their saved position.
  - If the user restored one from the Dock, Kosmos follows it to that workspace, as it
    does for Command-Tab.
  - A `summon` command brings a window to the current workspace on purpose.

### 5.6 Hotkeys and Secure Input

- Carbon hotkeys for every binding. A mode switch re-registers only the keys that differ,
  at 8 µs per call.
- Secure Input (a password field in any app) blocks Option-only hotkeys. Kosmos shows when
  Secure Input is active and which app holds it. A probe will show whether bindings that
  include Control or Command still work.

### 5.7 IPC and bar

- The socket lives in a 0700 directory under Application Support. Peers are checked with
  `getpeereid`, and all I/O runs off the main actor.
- A bar snapshot is about 870 bytes of JSON and takes 30 µs to encode. It goes to
  SketchyBar's Mach port as one `--trigger` event with a zero timeout. The bar applies
  snapshots by sequence number and never queries Kosmos.
- Hooks that launch programs exist only for rare events such as reload and profile change.

### 5.8 Config

- A reload parses and validates the whole file, then applies it in one step. Any error
  keeps the running config, and a bad file at login falls back to the last good config.
- Display profiles are built in and matched by monitor name or serial. Runtime toggles are
  commands and never rewrite the file.
- Window rules are declarative, and the first match wins. Kosmos warns when an earlier
  rule shadows a later one.

### 5.9 Status item and onboarding

- The status item is a static template icon at square length. Its image changes only for
  three states: paused, Accessibility missing, and config error.
  - A test asserts that switches write nothing to it.
  - Kosmos keeps running when the user removes the item.
- Onboarding is an Accessibility window. Launch at login uses `SMAppService` with a
  `KeepAlive` agent, and config errors appear in one AppKit panel.

### 5.10 Distribution

- Kosmos ships the way AeroSpace does: a zip on GitHub releases holding `Kosmos.app` and
  `bin/kosmos`, installed with a cask from Kosmos's own Homebrew tap. The cask removes the
  quarantine attribute and links the CLI. There is no App Store build; its sandbox forbids
  controlling other apps' windows.
- Builds are signed with one stable certificate, so the designated requirement and the
  Accessibility grant survive updates. An ad hoc signature changes with every build and
  makes macOS ask for Accessibility again.
- Notarization needs a Developer ID certificate. Adding it would remove the need to strip
  quarantine.

### 5.11 Focus follows mouse

Kosmos replaces AutoRaise for hover focus. AutoRaise needed a local patch to key the
hovered window instead of the app's most recent one; Kosmos's focus path already does.

- The window under the pointer becomes key once the pointer has rested in it for 50 ms,
  through the same exact-window path as a focus command. Hyprland's `follow_mouse = 1`
  focuses at once, but on macOS keying another app's window activates the app, which costs
  about 94 ms of CPU outside Kosmos (section 2). A sweep across five windows of different
  apps keys four apps with no dwell and one with a dwell longer than the time the pointer
  spends in each window, so each window passed through costs about as much CPU again as
  the one the pointer stops in.
- 50 ms is the delay AutoRaise runs with on the development Mac (`delay=2` at
  `pollMillis=50`), whose raise comes one poll after the poll that finds the window, 50 to
  100 ms after the pointer enters it. Kosmos times the dwell from the movement event, so a
  hover takes 50 ms plus the focus call. How long a real sweep stays in each window was not
  measured; if the menu bar still names each app a sweep crosses, the dwell is too short.
- Pointer movement arrives through a listen-only event tap on its own thread, at the
  annotated session location, for mouse moved events only. A pointer at rest costs nothing,
  and the tap is off while focus follows mouse is. AutoRaise polls 20 times a second.
- On macOS 27, creating a listen-only tap for mouse moved events alone made macOS ask a
  process with neither Accessibility nor Input Monitoring for Input Monitoring ("would
  like to receive keystrokes from any application"), and that tap received nothing, while
  the same tap under the terminal's grants received about 5,800 movements in the same
  minutes. Apps with Accessibility alone run listen-only taps: AltTab at the annotated
  location (`src/events/WindowAttentionEvents.swift`, whose tap creation fails without
  Accessibility) and Loop for mouse movement (`PassiveEventMonitor.swift`). Whether
  Kosmos's grant is enough is open until a live test settles it. The tap is created only
  when focus follows mouse is first turned on, and Kosmos logs whether Input Monitoring is
  granted and when the first event arrives.
- Open: if the live test asks Kosmos for Input Monitoring, pointer movement comes from
  `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` instead. AeroSpace's and
  Amethyst's focus follows mouse and Rectangle's drag snapping use such monitors, and
  their code asks only for Accessibility. AppKit installs the monitor as a handler on
  HIToolbox's event monitor target (AppKit's imports and disassembly on macOS 27), which
  Carbon's documentation of `GetEventMonitorTarget` describes as WindowServer copying
  user input events sent to other processes into this one's event queue, so it is not an
  event tap. NSEvent's header requires Accessibility for key events and names nothing for
  mouse events. Against the tap it gives up two things:
  - Delivery is on the main thread, so every movement wakes the main actor and queues with
    hotkey events. The gate still runs first, and only a movement into another window
    does more.
  - The event may not name the window under the pointer; whether its `cgEvent` carries
    the annotated field is for the live test. If not, `NSWindow.windowNumber(at:
    belowWindowWithWindowNumber: 0)` returns WindowServer's hit test for a point,
    including other apps' windows, at one WindowServer call per movement. The monitor's
    points have a bottom left origin and are flipped first.

  The mask stays mouse moved, so a drag still sends nothing (AeroSpace notes the same),
  and Control still comes from each event's modifier flags. An active tap is the other
  way out: Rectangle, skhd and yabai create default taps with Accessibility, and it keeps
  the tap's thread and field, but every pointer event would wait on Kosmos's callback,
  which section 3 rejects for the keyboard.
- Each event names the window under the pointer, as WindowServer's own hit test found it
  (`kCGMouseEventWindowUnderMousePointer`, filled in at the annotated location). Kosmos
  takes that window only when its model has it as a tiled or floating window of the shown
  workspace. Moving the pointer queries no window list, and the stacking of overlapping
  floating windows, or of tiled windows held at a minimum size, is WindowServer's answer;
  a hit test of the model's frames would need a stacking order the model does not keep.
- The same check keeps focus where it is over anything else: menus, the bar, panels and
  dialogs, the Dock, and Mission Control's windows (not yet seen live). On a native
  fullscreen Space the only window under the pointer is the fullscreen one, so no tiled
  window is raised over fullscreen video, as AeroSpace's focus follows mouse did.
- Holding Control pauses focus follows mouse, as AutoRaise's `disableKey` did, and chosen
  apps are ignored. Control is read from each movement's flags, so the tap takes no
  keyboard events. Nothing is focused while a mouse button is down, because a movement
  with a button down is a drag event, which the tap does not receive.
- Keying leaves the stacking order alone (section 2), so a floating window is raised with
  AXRaise on its app's worker before it is keyed. Tiled windows are only keyed.
- A hover focus counts as a command: reports received before it are stale, the session
  adopts the window, and its focus request's echo is consumed like any other. The TLA+
  spec checks hover with the other inputs ([tla/](../tla/README.md), `hover` and
  `hover-settles`).
- The pointer follows focus the other way too. A command that focuses a window moves the
  pointer to its center unless the pointer is already over it, and so does Command-Tab to
  a window that is not under the pointer. A click happens over the window or its resize
  region, a few points past the frame, which counts as over it, so a click never moves the
  pointer. A hover focus never moves the pointer.
- `focus-follows-mouse = true` turns it on, and `focus-follows-mouse-ignore-apps` lists
  apps by bundle identifier or name; the command `focus-follows-mouse on|off|toggle`
  switches it until the next config load.
- Left out:
  - A minimum movement. AutoRaise's `mouseDelta = 2` kept 1 px jitter from raising
    AeroSpace's parked slivers, and Kosmos parks none. If a still hand moves focus, a
    minimum distance from where the pointer last counted brings it back.
  - A pause key other than Control, and a dwell other than 50 ms, until a user needs one.
  - Moving the pointer off an open menu onto a window focuses that window and closes the
    menu; a menu tracking signal would keep it open.

### 5.12 Other tools

- **Status bar (SketchyBar).** Kosmos sends one `kosmos_state` event per change, holding
  everything a bar draws: every workspace with its display, whether it is shown and
  focused, and its windows' ids, app names and positions; the focused window and app; the
  active profile; and the displays. The bar runs no command on a switch. A bar that starts
  after Kosmos runs `kosmos state` once for the current snapshot, and clicking a workspace
  runs `kosmos workspace <name>`.
- **Borders (JankyBorders).** They work unchanged while inactive borders are transparent.
  With visible inactive borders, Kosmos would have to conceal each border window along with
  its window, as the AeroSpace fork did. Borders drawn by Kosmos itself are on the later
  list (section 7).
- **Display profile scripts.** Scripts that rewrite another window manager's config when
  displays change give way to Kosmos's profiles, once Kosmos matches displays by serial,
  switches profile when displays change, and puts the profile name in the bar event.
- **Launchers and cheat sheets.** `kosmos list-bindings` prints the loaded bindings as JSON,
  so a launcher's keybinding list reads them instead of keeping its own copy.
- **Switching from another window manager.** Install Kosmos.app to /Applications and the CLI
  on the PATH; grant Accessibility to Kosmos itself; launch it at login; turn off the other
  window manager's login item and the helpers Kosmos has replaced by then (profile
  watchers at the switch; AutoRaise once focus follows mouse lands). Rolling back reverses
  those steps, so the other manager's config and the bar's code for it stay until the
  switch is final.

## 6. Verification

- **TLA+ first.** Before the scheduler exists, specify it:
  - one main actor, per-app worker queues, and the focus and bridge queues;
  - echo accounting and the switch protocol in 4.3.

  Check that the screen and key window converge with Kosmos's model and that the last
  command wins. Also check that every disturbance settles, that no hidden window lacks a
  recovery path, and what each reveal order shows mid-switch. The spec and its results
  are in [tla/](../tla/README.md).
- **Unit tests** drive the model, tree, layout, command parser, echo classifier and config
  loader without AX.
- **Probes in a macOS virtual machine** cover everything that changes window state:
  - hiding: barrier ordering, reusable Spaces, Dock restart;
  - focus: the key record in Chromium and Electron apps, same-app key changes, whether
    macOS re-keys after the key window is concealed, and the receipt order of hotkeys and
    activation reports;
  - discovery notifications, minimum sizes, and Secure Input.
- **Work counts.** Each command counts its AX calls, SkyLight calls, main-actor jobs and
  status item writes, and tests assert them. Counts are deterministic where milliseconds
  are noisy. Instructions retired per switch, from the CPU counters, are the lab metric;
  they are checked against wall-clock time once, as the claude.ai team did when it made
  its app faster (https://claude.dev/blog/how-we-made-claude-ai-faster/).
- **Budget.** Kosmos's own work in a switch fits in one frame at 120 Hz, 8.3 ms.
- **Hardware trials** cover timing, CPU and multi-monitor, because a virtual machine's
  graphics timing is not representative. Signposts mark each phase of a switch, and each
  build is compared at the 75th and 95th percentiles.

## 7. Milestones

1. **Probes and skeleton.** VM, probes, C shim, app lifecycle, onboarding, socket and CLI.
2. **Observer mode.** Inventory and events running next to an existing window manager,
   managing nothing, to prove discovery against a live desktop and measure its CPU.
3. **Tiling.** Tree, layout and geometry on one monitor.
4. **Hiding and recovery.** Holding Space, guardian, durable record, switch protocol.
5. **Focus.** Private focus path, echo classifier, empty workspaces.
6. **Hotkeys, config and bar.** Carbon hotkeys, TOML, profiles, SketchyBar push.
7. **Parity with AeroSpace.** Multi-monitor with display profiles that follow the
   connected displays, floating windows, rules, fullscreen, returning windows, the status
   bar event, and switching over (section 5.12). Other tools keep running beside Kosmos
   until their replacement lands. Timing compared against the AeroSpace fork.
8. **Beyond AeroSpace.** Replace what needed a workaround: focus follows mouse (retiring
   AutoRaise) and `kosmos list-bindings` for launchers.
9. **Later.** A native bar as a separate process, borders from Kosmos's own model,
   persistence across restarts.

## 8. Left out of the first version

Scrolling and BSP layouts, tabbed and stacked title bars, mouse drag and resize, an
embedded scripting language, window title matchers, marks, persistence across restarts,
and one macOS Space per workspace.
