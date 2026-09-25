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
| Some Carbon hotkeys stop while any app holds Secure Input, for example in a password prompt (`kosmos-probe secure-input`, section 5.6) | Show Secure Input and its holder |
| Pixel-based container weights produce wrong and negative sizes | Store fractions |
| After a conceal or reveal, a check of the holding Space found the change 0 times in 50 each. After one synchronous bridged read, it found it 50 times in 50 each; the read took 1.3 ms median, 3.6 ms at most (`kosmos-probe barrier`) | One bridged read can confirm a switch, where the fork polled |
| Live on 2026-09-24, 40 alternating switches per run between two workspaces of one window each. Reading the holding Space directly every 0.1 ms confirmed each batch at a median of 2.10, 2.18 and 2.95 ms in three runs (p90 3.66, 4.83 and 3.44 ms; at most 4.62, 9.79 and 3.86 ms), and all 120 confirmed before the barrier was due. The barrier alone confirmed at 3.31 and 3.44 ms median in two runs (p90 4.72 and 5.24 ms; at most 11.08 and 10.59 ms). Switches over 8.3 ms from keypress to the end: 10 of 120 with the reads, 21 of 80 with the barrier alone | Direct reads confirm a switch; the barrier backs them up after 10 ms |
| Bridged Space operations from a process that has not started AppKit do nothing. With `NSApplication` initialized, the guardian restored a concealed window 130 ms after `kill -9`, 100 ms of it a deliberate settle (`kosmos-probe survive-kill`) | The guardian is a prohibited AppKit client with no Dock icon |
| Keying a window of another app costs about 94 ms of CPU outside Kosmos: BiomeAgent 29 ms, spotlightknowledged.updater 15, MenuBarAgent 15, duetexpertd 14, WindowManager 6, ContextStoreAgent 6 and the activated app 8, plus 12 for BetterTouchTool on the development Mac. Five stub apps were keyed back and forth through the focus path, 384 activations against 96 in 73 s each, and the cost is the difference between the two; WindowServer's share was lost in the noise of the desktop in use. The focus call took 4.4 ms at the median and 16.6 ms at p95 (`script/sweep.sh`) | Focus follows mouse keys a window only after the pointer rests in it (section 5.11) |
| Keying a window through the focus path leaves the stacking order alone. The key record alone keyed another app's window 10 times in 10 and put it on top 0 times, and inside the front app it keyed nothing (0 of 20). AXRaise alone keyed a window of the front app 20 of 20. For another app, the key record and then AXRaise keyed the window and put it on top 10 of 10, AXRaise first only 1 of 10. AXRaise in a background app posts a focus notification from it, 0.4 to 0.5 ms later, without keying it. AXRaise took 0.65 ms at the median and 3.7 ms at most (`kosmos-probe keying`, 10 rounds) | Inside the front app the worker raises. For another app the queue posts the key record and the app's worker raises the window after it |
| An AX call to a hung app returns kAXErrorCannotComplete 5 ms after its messaging timeout, and with none set macOS 27 waits 1.5 s. An app still launching fails with the same error in under 9 ms and answers about 60 ms after it starts. An answered read takes 13 µs (`kosmos-probe ax-timeout`) | Time out every call at 1 s, and back an app off only after a call that waited out the timeout |

## 3. Primitive decisions

| Area | Decision | Rejected alternative |
| --- | --- | --- |
| Window geometry | Accessibility on one worker thread per app; batched, deduplicated writes with generation ids; one read-back per batch | A shared thread pool, where one hung app stalls every relayout |
| Discovery | Inventory keyed by WindowServer window id, fed by SkyLight window notifications and per-app AX observers; reconcile only the app an event names; a 0.1 ms SkyLight sweep at launch, on a Space change and after an unlock or wake, as a backstop, with no timer (as yabai and rift) | Full discovery after commands: CPU on every switch, and the lock screen looks like every window closed |
| Hiding | Hidden windows gain membership in one concealed holding Space created once per session. A switch is two batched bridged operations, confirmed by direct reads of the holding Space, with one bridged read as the barrier when the reads do not show them within 10 ms | One macOS Space per workspace, which hides windows from Accessibility and binds workspaces to displays. Corner parking, which keeps hidden apps rendering and leaves a visible sliver |
| Recovery | A memory-mapped record of owned Space ids and first-hide window records, with no fsync, and a separate guardian executable in its own process group that Kosmos watches and respawns | A journal rewritten on every switch |
| Focus | Private window-targeted focus in every case: AXRaise the window on its app's worker, then front the process and post one mouse-down key record far off the window. A serial focus queue off the main thread, with generations and read-back | Public `activate`, which names no window and chose the wrong one in every trial on the development Mac |
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
| One AX worker per app (an actor with a custom executor on the app's run loop) | That app's AX elements, observers, frame writes and reads, and raises before focus | Touch the model directly |
| Focus queue, serial | Front-process calls and key records, generation checks, the already key check | Wait on a worker longer than 30 ms |
| Bridge queue, serial | Bridged Space operations, the reads that confirm them, and the barrier read | Run past its time budget |
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
   outgoing windows back to back, then reads the holding Space until it shows them done.
   Revealing first shows windows of both workspaces for the length of one bridged
   operation; concealing first would show an empty desktop for the same time.
4. Once the reads confirm the target window is revealed, and the switch generation is
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
  - One AX observer per app: creation, focus, main window, destroy and minimize.
  - NSWorkspace app lifecycle events, plus a process exit source for each app. The
    inventory alone observes an app's hide and unhide: it records the departure or return
    of the app's windows, then passes the event to the controller.
- Only WindowServer evidence or app exit removes a window. AX silence, AX errors and the
  lock screen never do, and while the session is locked, creation and destruction wait. A
  read that gets no answer leaves the window's AX facts as they were.
- Events drive the inventory, with no timer. A 0.1 ms SkyLight sweep runs at launch, on a
  Space change, and after an unlock or a wake, as yabai, rift and Amethyst do. Sweeps
  asked for while one runs start one more when it ends, so a burst of Space events ends
  with a sweep that started after the last of them. A window a sweep finds or loses that
  no event reported is logged as "missed by events", and so is a known window whose
  ordered in state or candidate status (level 0, no parent) a sweep corrects, so a gap in
  macOS's notifications shows in the log. The unlock sweep counts none of the windows the
  lock held back: one that arrived while locked, and one destroyed while locked or whose
  app exited then. An event handled after a sweep, for a change its snapshot already had,
  came late and still counts, so an event for a window within 1 s after a sweep counted it
  is logged too, and the count can be corrected by eye. The 3 s sweep this replaced found
  and lost none on 2026-09-24, over a day of use and live tests. It counted none of its
  corrections, which it logged only at debug or info level.
- A change of a window's level posts no event of its own. In `kosmos-probe level` on
  2026-09-24, 60 changes of an invisible or off screen window posted nothing while no
  other app's window came or went. In three runs while other apps' windows came and went,
  12 of 18 changes posted 815 as the new level landed, 10 of them 808 too. The inventory
  reads a window's row again on either, and otherwise at the window's next move, resize,
  reorder, order change or Space change, or at the next sweep, which logs the change as
  missed by events. Kosmos accepts that gap, with no timer to close it. A visible window's
  level change is unmeasured, as the probe keeps its window invisible.
- The session counts as locked from loginwindow's `com.apple.screenIsLocked` to
  `com.apple.screenIsUnlocked`, and while NSWorkspace reports it switched out by fast user
  switching. macOS 27's loginwindow still names both notifications, and alt-tab and rift
  listen for them. Kosmos asks for immediate delivery, because AppKit holds distributed
  notifications for an app that is not active. The session dictionary
  (`CGSessionCopyCurrentDictionary`) gives the state at launch, as alt-tab seeds it, and is
  read every 5 s while locked, so a missed unlock cannot stop Kosmos for good. Open
  question: unlocked, the dictionary on this Mac has no `CGSSessionScreenIsLocked` key, and
  a missing key reads as unlocked, so if the key is missing while locked too, each read
  undoes the lock within 5 s. Every read logs the dictionary's lock and console keys, and a
  lock test settles it. loginwindow
  coming to the front, which AeroSpace and rift also watch, is no lock signal. It also
  fronts its own dialogs, such as the log out confirmation.
- While locked, the inventory admits and removes no window and runs no sweep, and Kosmos
  writes no frames, runs no hides, requests no focus, ignores focus reports and refuses
  commands. After an unlock, and after a wake while unlocked, the inventory sweeps, and
  Kosmos reads the main display again, writes every tiled window of the shown workspace to
  its frame on that area whatever the frame ledger holds, conceals and reveals every window
  again, requests the focus intent and publishes the state. A wake can post both `didWake` and `screensDidWake`; each restarts a 0.5 s
  wait, so a burst gets one resync, and an unlock inside the wait resyncs instead. A wake
  gates nothing. A sleeping Mac runs nothing, and one that asks for a password after sleep
  locks its screen first.
- The model can still change while locked, as when a window minimizes or returns, its app
  hides, or a report held before the lock is decided; the resync carries out those plans.
- A tab switch (5.5) can create or destroy one of its two windows while locked. Every
  order change of a candidate window is held with its time, creations and destroys too,
  and a window first seen while locked is watched until the unlock sweep admits it. At
  the unlock the changes are reported in the order they happened, each with its own time
  and before any change after the unlock, so switches pair as they would have unlocked.
  Kosmos acts on them at the unlock. The sweep then admits and removes windows without
  reporting their order again.
- A new window becomes managed when it is ordered in, has no parent window, sits at level 0
  and passes the popup and dialog checks. Apps whose AX is late get ten retries 100 ms
  apart, as yabai and Hammerspoon do, then one every 0.5 s. A window whose AX facts no
  read has returned is read again when its app's worker reports it created, reports that
  the app answers again, or reports the window focused, when its app unhides, when it is
  ordered in or changes Space, and at the sweep after a Space change while it is ordered
  in. Accessibility lists no window on a
  Space that is not shown, such as another fullscreen Space, so reading them at every sweep
  would ask each such app again and again. A worker asked about windows it does not know reads
  its app's window list again first, once for all of them, and knows the elements it has
  cached without asking the app, so the list costs one call. Terminal launched hidden
  restored a window that no read answered for and no creation report named while it
  stayed hidden, so before these reads it was never managed (live log, September 24,
  2026).

### 5.2 Geometry

- Layout compares each target with the last confirmed frame and the pending target.
  Unchanged windows get no write, and each window keeps only its newest target.
- When the size changes, write size, then position, then size again; otherwise write the
  position alone. Read the frame back once per batch.
- A window that refuses a size keeps its observed minimum. Kosmos doesn't retry that size
  until the target changes.
- Every AX call times out after 1 s, set once for the whole process, so elements copied
  out of an app's attributes are covered too. Reads use the same 1 s. Each app's calls run
  on its own worker, so a slow read delays only that app, and a read cut off at 50 ms would
  leave its window unknown.
- A call that waited out at least half the timeout backs its app off. The worker then makes
  no call to the app, keeps only the newest frame target of each window, and asks for the
  app's role with a 50 ms timeout every 0.5 s. When the app answers, the worker tracks the
  windows created meanwhile and writes the held frames. It stops asking and reports that
  the app answers only if none of those calls timed out, and the inventory then reads the
  facts it could not read before. A focus change during the backoff went unread, so while
  the app is the front process its focused window is reported as a key window report. A launching app fails fast and is
  left to the launch retries.

### 5.3 Hiding and recovery

- Create the holding Space once per session, and record its id in the durable record
  before the first window enters it.
- Every concealed window keeps its ordinary Space membership and gains holding
  membership, so every reveal is a removal from the holding Space. On one display,
  Command-Tab and a Dock click key the app's most recently used window, which AppKit keys
  on activation, concealed or not, and Kosmos follows it to its workspace, as macOS does
  without Kosmos. The AeroSpace fork kept every concealed window's ordinary Space in its
  np3 trial and its forward selection cases passed (fork NATIVE-WINDOW-SELECTION-TRIAL.md).
  Two costs follow. Command-backtick cycles through the app's concealed windows too, and
  Kosmos follows each one. When the key window closes, AppKit can key a concealed window
  of the app, and the departure rule keeps Kosmos's workspace (section 5.4).
- Kosmos strips no window of its ordinary Space, because revealing a stripped window
  adds it back to an ordinary Space, which makes WindowManager.app rebuild its window
  model; on 2026-09-24 such switches took 2.6 to 33.2 ms, and switches that only removed
  windows from the holding Space took 0.7 to 5.0 ms.
- Open item: several displays. Keeping every concealed window's ordinary Space failed
  one of the fork's np3 cases on three displays: macOS keyed a concealed window on the
  current display in place of the app's last key window on another display (fork
  NATIVE-WINDOW-ELIGIBILITY-TRIAL.md). With several displays, Kosmos should strip a
  concealed window whose app's most recently used window is shown on another display, and
  change it when that window moves. Commit a0f9e6d on branch switch has the tracking of
  each app's most recently used window and the membership job it needs.
- A reveal removes the window from the holding Space. A window with no other Space at
  the time of the reveal is first added to an ordinary one, exclusively; that add strips
  only managed Spaces, and the holding Space is not one, so the removal is still needed.
  The add goes first because a window removed from its only Space lands on the active
  Space, which can be a native fullscreen one (`kosmos-probe reveal`).
- A window leaves the holding Space only once its add landed. The add's return says only
  that it was sent, so a barrier after the adds, about 1.3 ms and only in a batch that
  adds, and a read of each added window's Spaces come before the removals. The read
  compares the window's Spaces with the displays' ordinary Spaces, whether or not the
  window's Space list names fullscreen Spaces. A window whose add did not land stays in
  the holding Space, so the batch fails its confirmation and recovery adds it again.
- A batch is confirmed when the Spaces it touched show each revealed window out of them
  and each concealed window in them. Kosmos reads them directly, on its own connection,
  every 0.1 ms for up to 10 ms, and only then sends the barrier and reads once more. A
  direct read never shows an operation at once (0 in 60 tries on the development Mac),
  but it shows it as soon as WindowServer applied it: 0.47 ms at the median for a window
  that is not key, against 0.50 ms for the barrier, which also waits behind
  WindowManager.app. WindowServer applies a batch's operations in order, so a window
  seen out of the holding Space implies the add sent before its removal.
- A window with no ordinary Space goes to the main display's current Space, else to the
  Space it had before its first hide if that still exists, else to the main display's
  first ordinary Space. A native fullscreen Space is never chosen, so a switch works while
  one is on screen.
- There is no fallback to corner parking. At the first unconfirmed bridged operation:
  restore every hidden window, stop hiding, report the cause, and retry at the next switch.
- Recovery adds each window without an ordinary Space to the current Space of the display
  under it, or to the Space a reveal would choose, then empties each recorded Space,
  destroys the Spaces and clears the record. It removes an added window from a recorded
  Space only once the add landed, and keeps the record while a window is left there. Every
  step can safely run twice.

### 5.4 Focus

- There is one current focus intent, identified by a focus generation. A switch has its own
  generation, so a focus change adopted during a switch leaves the switch to finish.
- Every report names the key window. For an app activation, the main actor notices the
  activation and stamps it, and the app's worker reads the app's focused window. An app's
  focused window notification is stamped, and checked against the front process, in a
  callback on an observer thread that never waits behind the worker's calls into the app.
  The callback only stamps, checks and posts, so it runs before the user's next input and
  before the app's activation read, which waits for the main actor and a round trip to the
  app. It still runs after the change, and Kosmos can key or hide windows in between.
  Hotkeys and socket commands are stamped on receipt.
- Reports are classified in order:
  - An echo is a report of a requested window received after the request. Matching the
    app alone would take a Command-Tab to another window of that app for an echo. The
    exception is an activation read: Kosmos records an activation only just before
    making it, so the next activation read of that app is its echo, whichever window the
    app has by then. A notification of the same window joins an activation's record
    without using it up. Only the matched record goes: each app's reports wait behind its
    own worker, so an echo can come after the echo of a later request. When the echo
    names another window than the current intent, as after a busy app's late raise, the
    intent is requested again.
  - A report from an app that is not the front process consumes an echo it matches and is
    otherwise ignored: background apps report windows they open. An activation read of
    an app that lost the front is ignored too, unless Kosmos's activation overtook it:
    Kosmos recorded an activation after the read's stamp, or, when the main actor noticed
    the activation, the app had already lost the front to an app Kosmos had recorded an
    activation for. Then the user's activation beat Kosmos's older request and stands.
  - A notification from an app Kosmos activated, received before that activation's read,
    waits for the read. It stands if the read finds its window: the user changed the
    app's window after Kosmos's activation. Otherwise it is dropped: the app changed its
    focused window in the background, and the callback ran after Kosmos brought the app
    front.
  - A report stamped before the last report Kosmos adopted or followed was overtaken by
    it. A report that only made Kosmos request its intent again does not count: the
    notification of a Command-Tab to a hidden window ends that way, and the activation
    read, stamped earlier, still has to follow it.
  - A click or Command-Tab received before the latest command is stale. The command wins,
    and its focus is requested again.
  - A window on Kosmos's current workspace becomes the focus intent and is requested
    again, in case an older request of Kosmos's landed after the user's change.
  - A report of a window that was hidden at its stamp was the user's: only the user
    reaches such a window, with Command-Tab or by opening it, as `open` on a document, an
    app's Window menu or the Dock's window list do. Kosmos follows it to its workspace,
    whether an activation read or a notification reports it: a window opened inside the
    front app has only its notification (tla/README.md, change 22). Hiding keeps when
    each window was last concealed and revealed, because a switch can change it before
    the report is classified. That excludes the report right after the key window
    left, when it closed or minimized or its app hid. macOS then keys another window
    itself, sometimes a concealed one, and Kosmos keeps its workspace and focuses it
    again. The window key before the report left the screen within the last second if
    WindowServer ordered it out or destroyed it, Accessibility reported it minimized, or
    NSWorkspace reported its app hidden. The window key before a report is the one Kosmos
    last heard of, unless the report repeats that window, as an activation read after its
    app's notification of the same change does. Then it is the window before that one:
    otherwise the read follows the re-key the notification declined (tla/README.md,
    change 24).
  - macOS can key the next app before WindowServer orders a hidden app's windows out, so
    a report that would follow waits 100 ms, then is decided by what Kosmos knows of the
    window key before it. A newer report of another window replaces it; one stamped
    before the held report, from another app's worker, was overtaken by it. Every held
    report logs its outcome. A Command-Tab after that report follows as usual, 100 ms late. This
    happened live: Command-H on the only window of workspace 2 took Kosmos to workspace
    1, where macOS keyed Ghostty.
  - Fronting another window of the app that is already key can leave that app's key
    window in place, and the app reports it again. A report that repeats the key window
    while Kosmos awaits the echo of its request to that app is such a miss, not the
    user's choice. The missed request never comes back, so it leaves the expected
    echoes. Kosmos requests the focus again, once for each requested window; if that
    misses too, it leaves the key window where macOS put it. This happened live: Kosmos
    fronted Ghostty for a window of workspace 1, Ghostty reported the window a switch
    had just concealed on workspace 3, and Kosmos followed it there. The rule belongs to
    the key record inside the front app. With the split path below, the worker's raise
    keys the window there and requests do not miss, and the rule misreads reports that
    arrive out of order: the activation read of a Command-Tab repeats the window its own
    notification just reported (tla/README.md, change 21). The split path drops it, and
    with it a held report's repeat after a miss.
  - A visible window of another workspace is key only during a switch: macOS re-keyed
    after a hide, or the user clicked or Command-Tabbed to a window about to be
    concealed. The switch wins, and its focus is requested again. After a batch fails,
    recovery shows every workspace's windows until a switch conceals them again. A
    click on one is then the user's, and Kosmos follows it as it follows a Command-Tab.
- Four races leave Kosmos nothing to tell the cases apart. They are known limits, and the
  TLA+ spec exempts them:
  - Kosmos keys an app again before that app's activation read runs. The read finds
    Kosmos's window, and a Command-Tab to another window of that app is lost.
  - A request Kosmos made before the user's click inside the front app activates another
    app before the click's callback runs. The callback finds another app in front, as
    for a background app's own change, or finds the app front again after Kosmos
    activated it, as for a change the app made before that activation, and the click is
    lost.
  - A switch reveals or conceals a window between the user's change and the main actor's
    notice or the notification's callback. Kosmos can then follow a click that lands on a
    window in the milliseconds it is being concealed, which costs one switch back, or lose
    a Command-Tab to a hidden window. Notifications follow so that a window opened inside
    the front app brings Kosmos to it, which admits this race.
  - The user keys a window of an app between the worker's read before a raise and the
    app performing that raise. A change to the raised window reads as the raise's echo,
    and after a change to another window the raise keys its window again over the user's.
- Skip activation when the target is already key, checked by the focus queue when the
  request runs: the target's app is the front process and its focused window, read on the
  app's worker, is the target. The key window last reported can be older than a request
  still in flight: after `workspace 2` then `workspace 1` in quick succession, a skip
  against it dropped the request for w1 before w3's report arrived, and w3's echo then
  left macOS keying w3 while Kosmos focused w1 (kosmos-hover's TLC counterexample;
  tla/Kosmos.tla, ExecFocus). The front process lookup takes 1.6 us, and only a request for
  the front app pays an AX read. A read with no answer stops a request for a window and is
  logged. The read and the raise go to the same app with the same timeout, so the app is
  not answering, and a record for a call that changes nothing would swallow a later click
  on the window: going ahead failed TLC's user configs, whose model assumes reads answer.
  The empty workspace goes ahead when Finder's read gets no answer within 30 ms: stopping
  would leave a hidden Finder window key, the 30 ms measures a busy worker rather than an
  app that does not answer, and a record of no key window that gets no echo is matched
  only by a later report of no key window, which then also drops any older expectation.
- A private request for a window runs as the split model in tla/Kosmos.tla specifies it,
  one step per action (KosmosCore's KeyRequest: FocusStart, WorkerStart, WorkerRead,
  WorkerRaise, FocusDecide). Each side records the echo, through the main queue, right
  before its own call that changes the key window, and never for the other side's call.
  The queue checks the generation, reads whether the target's app is front, hands the app's
  worker one job, and waits for it at most 30 ms, as the main actor waits on a worker.
  - Inside the front app the key record changes nothing and only AXRaise keys a window, so
    the worker keys it and the queue posts no key record. The worker ends a stale request,
    and one whose front app already has the target focused; then, under the request's lock
    just before the raise, it records and marks the request raising while the app is front.
  - For a background app the worker's job only orders the request behind the app's earlier
    jobs, and raises nothing. Unless the request went stale, the app came front meanwhile,
    or the worker is raising it, the queue marks it sent, records, and posts the key record,
    which activates the app with the named window but leaves it where it sits in its app's
    stacking order. Then the app's worker raises the window, only while the app is front
    and the window is still its focused window, so it never raises over a window the user
    chose since. It does not check that the request is current: a newer request for the
    same window would find it key and raise nothing, and the window would stay behind. The
    worker records the raise's echo just
    before it, since the raise keys the window again if the user keyed another window of
    the app first. Once the raise has returned and the worker has read the app's focused
    window, it tells the main actor, which forgets the record if no report used it: the
    raise changed nothing. Without the record TLC's `split-open-postraisenone` fails, and
    with a record kept until matched `split-open-postraisekept` does (tla/README.md,
    change 23).
  - Nothing is recorded and later forgotten, so no late answer can orphan a call; `dropped`
    serves only a call that fails.
  - TLC checks the split path with RaiseKeys and RaiseReports as `kosmos-probe keying`
    measured, either app busy with the 30 ms timeout nondeterministic, background apps
    opening windows, a window opened inside the front app, two displays, and the key
    window on top of its app at rest (tla/README.md, changes 15 to 24).
  - Recording when the request was made failed TLC's `user` config. The user clicked w2, and
    Kosmos requested w2 again. Before the queue ran that request, the user clicked w1 and
    then w2, the second click on w2 was taken for the queued request's echo, and Kosmos
    stayed on w1.
  - An expectation whose echo arrived while the session was locked is never consumed, since
    reports are not classified then, so a resync forgets every pending one.
- The focus queue never names a concealed window (tla/Kosmos.tla, ExecFocus). A request for
  a window Hiding held concealed when the request was made still supersedes older requests,
  and then keys nothing; the switch that reveals the window requests focus once its
  confirmation shows the reveal. The concealment is the one known on the main actor at the request,
  since Hiding's ledger lives on the bridge queue.
- When a newer command for another workspace is already queued, the older one lays out but
  doesn't focus.
- Every focus request passes one gate: while macOS shows a native fullscreen window's
  Space, only a command requests focus. The Space counts as shown while its window is
  key, or a panel or dialog of its app that Kosmos does not manage. Parking the fullscreen
  window moved Kosmos's focus to a desktop window. Focusing the next one when that window
  closes or hides, or after an unhide conceals the app's other windows, would take the
  user out of fullscreen.
- Never front a window that just left the screen, before Kosmos heard of it: that would
  unminimize it or unhide its app. The window's departure then focuses its workspace's
  next window, or Finder. A closed focus is replaced at once. A minimized or hidden one is
  replaced at once too, unless the key window macOS last reported left with it: then
  macOS's report of the next key window is still on its way and focuses. Focusing earlier
  could put Kosmos's echo between the departure and that report. When macOS keys no
  window, the departure focuses, and when no report comes within a second, as when an
  app keeps no key window after its last window minimizes, the departure focuses then.
  The second outlasts a minimize, whose next key window macOS reported 0.73 s after the
  minimize. A window keyed during the animation, by Kosmos or the user, is taken to leave
  macOS nothing to key when it ends (not measured; the departures probe asks). A click
  or Command-Tab during the animation reads as macOS's own key change, so Kosmos keeps
  its workspace. So does one within the second after the key window left with no report
  of a next key window.
- The private path has a kill switch with two triggers. Once off, it stays off across
  restarts until `kosmos reload-config`, and the status item names the cause.
  - A crash guard. A byte in a file mapped shared is set during each private call and
    cleared after it, and a byte found set at launch turns the path off. The two stores
    cost about 1.4 ns and make no system call. A kill that lands inside the call turns the
    path off too.
  - Wrong windows. Only the private key record counts, which keys a background app's
    window; inside the front app the raise keys it. A request misses when its app reports
    another of its windows key, and neither an echo of any request nor a report of the
    requested window arrives first, before Kosmos's next request. A background report that
    consumes the echo leaves the count alone. A miss and a retry that misses too count as
    one miss. Five misses in a row turn the path off. On this Mac AXRaise and then the
    private sequence keyed the right window in 60 of 60 AutoRaise trials, 9 of them
    between two windows of the active app, so the miss rate is at most about 5% at 95%
    confidence, and five misses in a row at 5% come once in about 3 million runs. Those
    trials posted a down and up record pair, and Kosmos posts the down alone;
    `kosmos-probe keying` measures Kosmos's own sequence. The public path chose the wrong
    window in 9 of 9 trials, so a false trip costs more than a few late wrong windows
    (wm-research focus note, section 4; autoraise-steez trial results, September 8, 2026).
    A request with no report neither misses nor clears the count, so a record that changes
    nothing, as the record alone did inside the active app, goes uncounted.
- AXRaise runs on the app's worker. Inside the front app the key record alone keyed nothing
  in 20 of 20, stacked or side by side, and AXRaise alone keyed the window in 20 of 20. For
  another app the key record alone keyed the window 10 times in 10 but never put it on
  top, and the key record then AXRaise did both 10 times in 10, where AXRaise first put it
  on top once in 10 (`kosmos-probe keying`). yabai and alt-tab raise after the record too.
  AXRaise in a background app makes it post a focus notification 0.4 to 0.5 ms later,
  without keying it. A slow app's raise lands late, and a hung app holds only its own
  worker.
- While the path is off, and for a request whose SkyLight call fails, focus takes the public
  path on the app's worker: make the window the app's main window, raise it, then activate
  the app. For an empty workspace it activates Kosmos, which holds no workspace window. No
  public call fronts Finder with no key window, and activating Finder can key a hidden
  Finder window, which keeps its ordinary Space for Command-Tab, and Kosmos would follow it
  off the empty workspace on every switch. Concealing Finder's windows fully instead would
  not reach one concealed earlier: the conceal ledger leaves a concealed window as it was.
  A background accessory app activating itself became front 0 times in 10
  (`kosmos-probe keying`), so on macOS 27 that activation does nothing. The app
  picks its key window, so the spec's assumption that the requested window becomes key no
  longer holds, and a wrong window is adopted like the user's choice. A public request's
  expectation ends at the first report from its app that is no echo, so a click on the
  requested window afterwards is the user's. Private requests keep theirs until matched
  (tla/README.md, change 6). The spec models exact keying only, so its TLC passes do not
  cover the public path. If the app keys the requested window late, after the user chose
  another of its windows, that late report reads as the user's and pulls focus back, change
  6's bounce in the fallback alone.
- Open item: a switch requested while a native fullscreen Space is on screen. The private
  path keys the target window but leaves the fullscreen Space on screen. On 2026-09-24 at
  00:37:39 Kosmos fronted Ghostty, and the display stayed on Helium's fullscreen Space
  until the user swiped 3.4 s later (WindowServer's SetManagedDisplayCurrentSpace log).
  AeroSpace focuses with the public `NSRunningApplication.activate` on one monitor, which
  lets the Dock switch to the Space that holds the window. The plan is that when the main
  display's current Space is not ordinary and the target is a window, the focus queue
  follows the private call with that public activation. An empty workspace would still
  leave the fullscreen Space on screen, as in AeroSpace. It waits for a probe with a real
  fullscreen Space, which takes over the screen.

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
    as a minimized one does, and returns when the app orders it in again. Kosmos takes a
    window still ordered out a second later for none of the other reasons as one. A
    conceal leaves a window ordered in (`kosmos-probe reveal`), and the second outlasts a
    fullscreen transition. A deselected tab is not one: it has left the session. While
    the session is locked, and until the sweep after the unlock, no window counts as one,
    as none is removed then: whether the lock screen orders windows out is unmeasured.
    That sweep checks every managed window still ordered out again. A tab parked this way
    before its switch took effect, as when the new tab's admission outlasts the second,
    gives its place back to the new tab.
  - A return received before the latest command is stale, as a Command-Tab is (5.4). The
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
    parked at once when it is minimized, in native fullscreen or hidden with its app.
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

### 5.6 Hotkeys and Secure Input

- Carbon hotkeys for every binding. A mode switch re-registers only the keys that differ,
  at 8 µs per call.
- Secure Input (a password field in any app) stops some hotkeys. `kosmos-probe
  secure-input` registers ten test hotkeys, and its window asks for a real press of each
  with Secure Input off and with its own password field focused. A hotkey that fires
  consumes the key; one that does not lets the key reach the probe's window. With real
  presses on the development Mac's keyboard:
  - hotkeys whose modifiers are Option or Option and Shift stopped on Y and comma;
  - Option on Space, Return and Delete still fired;
  - every hotkey with Control or Command fired.
- An earlier version of the probe posted synthetic presses, which gave the same answer in
  three runs. They also covered keys a laptop lacks (keypad 1 stopped; Page Down, F13 and
  keypad Enter fired) and Secure Input held by another, windowless process, which made no
  difference. They are no stand-in on their own: built from the HID state, every hotkey
  on a character key missed even with Secure Input off, and a press that no hotkey takes
  types into whichever app is in front.
- Kosmos states the rule as Option or Option and Shift on a letter, digit or punctuation
  key. That rule is inferred from Y, comma and keypad 1: the other keys were not each
  tested, and Space types a character too, yet its Option hotkey fired. By that rule, 34
  of the sample config's 52 bindings stop (alt and alt-shift on letters, digits, equal and
  minus), and the ctrl-alt bindings keep working. Tab and the arrows cannot be tested
  while Kosmos runs, because it holds them; like Return and Delete, they should keep
  working.
- WindowServer sends event 752 when Secure Input turns on and 753 when it turns off,
  whichever process changes it, and 753 when the last holder exits (measured September 24,
  2026 with throwaway programs that turned it on and off from other processes). Kosmos
  registers both on its own connection, then reads `IsSecureEventInputEnabled` and names
  the holder from the session dictionary. Nothing polls. The handler runs on the main
  actor when an event arrives, never inside a switch, though it can run right after one:
  an app that holds Secure Input only while it is active, such as Terminal with Secure
  Keyboard Entry, turns it off and on as a switch leaves or enters its workspace, and the
  status item image changes with it. Checks on app activation or focus reports would
  miss a password field focused inside the active app.
- The events follow the session's state. With two holders, the second enable and a
  release while the other remains send no event, so the named holder can be stale until
  Secure Input turns off and on again.
- While Secure Input is on, the status item shows a lock, names the holder and says which
  bindings wait, and the log records each change. For a holder with no windows of its own,
  WindowServer names the frontmost app instead. Showing it in the bar, for a Mac that hides
  the menu bar, is a later option: the snapshot can gain a field without a new version.
- A reload does not warn about bindings that stop. They stop only while Secure Input is
  on, and the sample config binds 34 of them on purpose by the rule above, so the warning
  would come with every reload.

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
- A command naming a workspace the active profile leaves out fails with a message, as
  `workspace 6` does on a profile with workspaces 1 to 5. AeroSpace creates a workspace on
  demand; a profile's list is fixed, and its `merge-workspaces` moves the windows of the
  workspaces it leaves out onto its own.
- A serial is the EDID alphanumeric serial number, which the display controller publishes
  on the framebuffer that drives the display. CoreDisplay names each display's framebuffer,
  so identical monitors, whose vendor, model and numeric serial are the same, should get
  their own serials. On the built-in display `kosmos-probe displays` found the framebuffer
  and no serial, as expected. The twin check is pending a run at Steve's desk, whose twin
  VG279QE5A panels share one EDID UUID (dotfiles `aerospace/apply-profile.sh`). That run
  also shows whether macOS gives the twins one display UUID, which would merge them wherever
  Kosmos looks a display up by UUID: its bar number and its current Space.
- Window rules are declarative, and the first match wins. Kosmos warns when an earlier
  rule shadows a later one.

### 5.9 Status item and onboarding

- The status item is a static template icon at square length. Its image shows one of
  four states: running, Accessibility missing, Secure Input on, and problems (config
  errors, hotkeys that could not be registered, and hiding that stopped).
  - Nothing inside a switch writes to it, though a Secure Input change can swap its image
    right after one (section 5.6). No test checks that yet; the work counts in section 6
    are meant to.
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
- Every focus request leaves its window on top of its app (section 5.4): inside the front
  app AXRaise keys it, and for another app AXRaise follows the key record.
- A hover focus counts as a command: reports received before it are stale, the session
  adopts the window, and its focus request's echo is consumed like any other. The TLA+
  spec checks hover with the other inputs ([tla/](../tla/README.md), `hover`,
  `hover-settles`, and `split-hover` with its `settles` and `notice` configs).
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
  active profile; and the display Kosmos tiles, numbered as SketchyBar numbers it, from the
  same WindowServer display list. Every connected display joins the event with
  multi-monitor support. The bar runs no command on a switch. A bar that starts
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
