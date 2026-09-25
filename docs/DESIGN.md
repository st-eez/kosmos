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
- Where AeroSpace and Omarchy (Hyprland as Omarchy configures it) behave differently, Kosmos
  follows Omarchy: focus follows mouse, where the pointer goes, and dragging windows.
  Command names, flags and the CLI follow AeroSpace, whose syntax the configs use.

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
| Keying a window of another app costs about 94 ms of CPU outside Kosmos: BiomeAgent 29 ms, spotlightknowledged.updater 15, MenuBarAgent 15, duetexpertd 14, WindowManager 6, ContextStoreAgent 6 and the activated app 8, plus 12 for BetterTouchTool on the development Mac. Five stub apps were keyed back and forth through the focus path, 384 activations against 96 in 73 s each, and the cost is the difference between the two; WindowServer's share was lost in the noise of the desktop in use. The focus call took 4.4 ms at the median and 16.6 ms at p95 (`kosmos-probe sweep` and `script/sweep.sh`, commit 3223999 on the hover branch) | Accepted for focus follows mouse, which focuses the window the pointer enters at once (section 5.11) |
| An AX call to a hung app returns kAXErrorCannotComplete 5 ms after its messaging timeout, and with none set macOS 27 waits 1.5 s. An app still launching fails with the same error in under 9 ms and answers about 60 ms after it starts. An answered read takes 13 µs (`kosmos-probe ax-timeout`) | Time out every call at 1 s, and back an app off only after a call that waited out the timeout |

## 3. Primitive decisions

| Area | Decision | Rejected alternative |
| --- | --- | --- |
| Window geometry | Accessibility on one worker thread per app; batched, deduplicated writes with generation ids; one read-back per batch | A shared thread pool, where one hung app stalls every relayout |
| Discovery | Inventory keyed by WindowServer window id, fed by SkyLight window notifications and per-app AX observers; reconcile only the app an event names; a 0.1 ms SkyLight sweep at launch, on a Space change and after an unlock or wake, as a backstop, with no timer (as yabai and rift) | Full discovery after commands: CPU on every switch, and the lock screen looks like every window closed |
| Hiding | Hidden windows gain membership in one concealed holding Space created once per session. A switch is two batched bridged operations, confirmed by direct reads of the holding Space, with one bridged read as the barrier when the reads do not show them within 10 ms | One macOS Space per workspace, which hides windows from Accessibility and binds workspaces to displays. Corner parking, which keeps hidden apps rendering and leaves a visible sliver |
| Recovery | A memory-mapped record of owned Space ids and first-hide window records, with no fsync, and a separate guardian executable in its own process group that Kosmos watches and respawns | A journal rewritten on every switch |
| Focus | Private window-targeted focus in every case: inside the front app, AXRaise the window on its app's worker; for a background app, front the process and post one mouse-down key record far off the window. A serial focus queue off the main thread, with generations and read-back | Public `activate`, which names no window and chose the wrong one in every trial on the development Mac |
| Empty workspace | Key an invisible window of Kosmos's own | Nothing, which leaves keystrokes going to the hidden window. Finder with no window brought forward, which keys a concealed Finder window |
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
| One AX worker per app (an actor with a custom executor on the app's run loop) | That app's AX elements, frame writes and reads, and raises before focus. Its observer runs on a second thread, which stamps each focus notification and checks the front process as the app sends it | Touch the model directly |
| Focus queue, serial | Front-process calls and key records, generation checks, the already key check | Wait on a worker longer than 30 ms |
| Bridge queue, serial | Bridged Space operations, the reads that confirm them, and the barrier read | Run past its time budget |
| IPC queue | Socket I/O, subscriber outboxes, Mach sends to the bar | Block the main actor |
| SkyLight notification callback | Copy the payload and hand it to the main actor | Anything else |
| Inventory read queue, serial | The rows WindowServer gives for window events, one query for each main run loop turn's events, and the sweep's reads, in order | Change the inventory |

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
   still current, the focus queue fronts the target, or Kosmos's own invisible window for an
   empty workspace, and reads back the key window.
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
- The inventory reads each process's activation policy once, since each read is a
  synchronous LaunchServices call, and forgets it when the process's exit source fires. An
  app that changes its policy while it runs keeps the one read first, as it keeps the
  Accessibility worker Apps gave it at launch; observing activationPolicy with key-value
  observing would follow a change. An app found regular only at its launch gets a sweep
  for the windows left out before it.
- Events drive the inventory, with no timer. A 0.1 ms SkyLight sweep runs at launch, on a
  Space change, and after an unlock or a wake, as yabai, rift and Amethyst do. A workspace
  switch posts no Space event, so it starts no sweep (`kosmos-probe events`, 40 switches
  on 2026-09-24). Sweeps asked for while one runs start one more when it ends, so a burst
  of Space events ends with a sweep that started after the last of them. A window a sweep
  finds or loses that no event reported is logged as "missed by events", and so is a known
  window whose ordered in state or candidate status (level 0, no parent) a sweep corrects,
  so a gap in macOS's notifications shows in the log. The unlock sweep counts none of the
  windows the lock held back: one that arrived while locked, and one destroyed while
  locked or whose app exited then. An event handled after a sweep, for a change its
  snapshot already had, came late and still counts, so an event for a window within 1 s
  after a sweep counted it is logged too, and the count can be corrected by eye. The 3 s
  sweep this replaced found and lost none on 2026-09-24, over a day of use and live tests.
  It counted none of its corrections, which it logged only at debug or info level.
- A change of a window's level posts no event of its own. In `kosmos-probe level` on
  2026-09-24, 60 changes of an invisible or off screen window posted nothing while no
  other app's window came or went. In three runs while other apps' windows came and went,
  12 of 18 changes posted 815 as the new level landed, 10 of them 808 too. The inventory
  reads a window's row again on either, and otherwise at the window's next move, resize,
  reorder, order change or Space change, or at the next sweep, which logs the change as
  missed by events. Kosmos accepts that gap, with no timer to close it. A visible window's
  level change is unmeasured, as the probe keeps its window invisible.
- An event that names a window is answered with the window's row, read from WindowServer,
  and a read during a switch waits for WindowServer to commit the switch's Space
  transaction. Every switch posts 815 about twice for each watched window, including
  windows it never touched: on the laptop Kosmos's windows got 278 of 815 and 41 of 808 in
  40 switches, and at Steve's desk (three displays, six managed windows) 360 of 815 and 20
  of 807, 9.5 events a switch, with no Space event (`kosmos-probe events`, 2026-09-24; the
  probe watches every window, so its totals also count JankyBorders' and Wispr Flow's,
  which Kosmos never gets). At the desk each read took about 1.4 ms, against about 0.1 ms
  on the laptop alone, and the reads blocked the main actor for about 13 ms a switch (525
  main thread samples in 40 switches). So the events of one main run loop turn wait
  together: one query on a serial queue off the main thread reads every window they name,
  and the main actor applies the events in the order they came when the rows return. A
  destroyed window and an app's exit wait in the same order, a sweep reads on the same
  queue after the events already waiting, and the lock rules are checked as each event
  applies. A window an event names, and each known window of an app that exits, counts as
  changed during a running sweep from the moment the event arrives.
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
  Kosmos reads the displays again (section 5.13), writes every tiled window of the shown
  workspaces to its frame on their areas whatever the frame ledger holds, conceals and
  reveals every window again, requests the focus intent and publishes the state. A wake can post both `didWake` and `screensDidWake`; each restarts a 0.5 s
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
- AppKit ignores a shrink that leaves a window's bottom within 25 pt of a display edge
  that another display adjoins, while the bottom is at or past that edge. A window moved
  at its old height from the built-in display up to the panel above it hangs past the
  panel's bottom edge, and the 10 pt gap puts its target's bottom in that zone. On
  2026-09-24, at y = 35 on the 1080 pt panel above the built-in display, Activity Monitor
  and a probe window kept 1070 pt when asked for 1035. From a bottom at the edge,
  Activity Monitor ignored 1035 to 1025 and took 1020, and from 1020 it took 1035. The
  probe window showed no such zone at a bottom edge with no display below, nor at a right
  edge another display adjoins. So a window left more than 2 pt taller than a frame write
  asked is written again through a height 40 pt shorter, then the target's, and only a
  window still taller has a minimum.
- A window that refuses a size keeps its observed minimum. Kosmos doesn't retry that size
  until the target changes.
- WindowServer reports each move and resize as a change event (`WindowServerEvent.changed`
  lists its ids), and the inventory reads the window's frame again. A frame it reads for
  a tiled or floating window of a shown workspace while no write of Kosmos's is in flight
  replaces the confirmed one, and a size other than the one the window kept at a refusal
  ends that refusal, so the next layout writes the target again. A concealed window's
  frame reads as off every display and is left out.
- A tiled window the user resizes by its edges, as a change event reports it while the
  left button is down, goes back to its tile when the button comes up, which an `NSEvent`
  global monitor hears, as AeroSpace's GlobalObserver does. Omarchy leaves Hyprland's
  `resize_on_border` off, so a tile's edges resize nothing there, and macOS gives Kosmos
  no way to stop such a resize. So does a tiled window moved while another window is
  key, as by a Command drag, or moved less than a lift takes (section 5.13). The ledger
  forgets the window first, so it gets a whole frame write. The resize command sizes
  tiles, and a floating window keeps the size the user gives it.
- An app can apply a live resize step queued before the button came up after Kosmos's
  write, and a width gets no retry. So a window sent back or dropped at a mouse up whose
  write reads back larger records no minimum. Its ledger entry goes, and its tile is
  written once more at its next change event with the button up, or after 100 ms; only
  that write's read back can show a minimum.
- The inventory applies a change event after reading the window's row off the main thread
  (section 5.1), by which time Kosmos's write may be confirmed and the button up. So
  Kosmos judges the change as of its arrival. It is a write's when it came before the
  write's read back confirmed it, even after a mouse up made the ledger forget the window,
  and it is the user's when it came during a press, from the left button's down to its up
  as `NSEvent` global monitors hear them. A mouse down off every display is left out,
  since the focus path's key record (section 3) is a mouse down far off every display with
  no mouse up, and a lock or a resync forgets the presses. A mouse up can come between a
  change and its apply, and it sends back or drops only the windows the press had moved by
  then, each with a write the change counts as. So a tiled window changed in a press that
  has ended by the time the change applies goes back to its tile, as the mouse up would
  have sent it. Only the last press that ended is kept, so a change from the press before
  it reads as one with the button up. Judged as it applied, the late echo of a hotkey's
  write to the window the user holds the button in would lift it, and the late echo of the
  write at a mouse up would write the tile again early and record a live resize step as a
  minimum. A change that came before a write was sent counts as the write's too. The
  write's change still records its row when it differs from the frame confirmed: the row
  applies after the confirm and can hold the app's next step, as of a live resize, whose
  own event then finds no difference. The pointer for the resize border check is read as
  the change applies.
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
- On one display Kosmos strips no window of its ordinary Space, because revealing a
  stripped window adds it back to an ordinary Space, which makes WindowManager.app rebuild
  its window model; on 2026-09-24 such switches took 2.6 to 33.2 ms, and switches that
  only removed windows from the holding Space took 0.7 to 5.0 ms.
- With several displays, keeping every concealed window's ordinary Space failed one of
  the fork's np3 cases on three displays: macOS keyed a concealed window on the current
  display in place of the app's last key window on another display (fork
  NATIVE-WINDOW-ELIGIBILITY-TRIAL.md). So as Kosmos conceals a window, it strips it when
  its app's most recently used window, the one it last focused, is shown on another
  display than the concealed window's workspace, and pays the add when it is revealed.
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
- A batch's completion and the focus request after it run on the main actor, so work
  queued there delays both. Three reads had kept the main actor busy after a switch. Each
  app's activation policy is now read once (section 5.1), the departure of the window key
  before a report only when its verdict needs it (5.4), and the pointer's target frame
  comes from Kosmos's layout with no read, and never after a switch (5.11). Live on
  2026-09-24, 40 alternating switches between two workspaces of one window each, back to
  back under the same load (load average 5 to 8): main at 636a019 took 3.53 ms from
  keypress to the end at the median and 8.42 ms at most, and the completion waited over
  1 ms for the main actor in 12 switches; with the three changes (367cd28), 3.75 and
  10.25 ms, and 3 such waits, so the switch time is the same
  within noise. Busy main thread samples in 40 switches fell from about 290 to about 66,
  but the first sample's build still ran the 3 s sweep timer, whose sweeps caused its 6 to
  10 ms stalls until 248f668 removed it. Half of the about 66 left were the 815 reads,
  which now run off the main thread (section 5.1). Before that, switches at Steve's desk
  took 4.66 ms from keypress to the end at the median and 17 ms at p90, timed under the
  sampler. On a quiet machine, 53dc6af took 1.81 ms at the median, 2.21 ms at p90 and
  2.50 ms at most, and the completion waited at most 0.39 ms.
- A window with no ordinary Space goes to the current Space of the display that shows its
  workspace, else to the Space it had before its first hide if that display still has it,
  else to that display's first ordinary Space. A display missing from WindowServer's Space
  list gives way to the main display. A native fullscreen Space is never chosen, so a
  switch works while one is on screen.
- There is no fallback to corner parking. At the first unconfirmed bridged operation:
  restore every hidden window, stop hiding, report the cause, and retry at the next switch.
- Recovery restores the windows Kosmos concealed: each recorded window in a recorded
  Space, any other window there whose app owns a recorded window, such as a sheet, and a
  child of a concealed window, as the Open or Save panel of a sandboxed app, which the
  panel service owns. A window the Space lists and a read of its row misses counts too,
  since that read failed, so it keeps the record. Recovery adds each one without an
  ordinary Space to the current Space of the display under it, or to the Space a reveal
  would choose, then removes them from each recorded Space, destroys the Spaces and clears
  the record. It removes an added window from a recorded Space only once the add landed,
  and keeps the record while a concealed window is left there. Every step can safely run
  twice.
- Recovery leaves in its Space a window of another process that is neither a child of a
  concealed window nor unread, such as a JankyBorders border window (below), and so does
  the ledger rebuilt after an incomplete recovery. Whether a destroy takes away a Space
  that still holds such a window is unconfirmed, since the destroy's return says only that
  it was sent. So recovery sends a barrier after the destroys and reads each Space back.
  That read is the measurement: a Space still there is logged and stays in the record,
  with no windows, for the next recovery to destroy again. Kosmos never conceals into a
  Space it sent a destroy, whose level, transform and alpha would be unknown. After a
  recovery it conceals into the newest recorded Space again only while that Space holds a
  recorded window, which a Space sent a destroy never does, and creates a new one
  otherwise.
- A window that closes leaves the ledger and the record once its concealing Space no
  longer lists it. The record's slot holds about 168 windows, and filled with closed ones it
  would stop every conceal. A window still listed stays recorded, as one that only stopped
  being managed or that a failed read took for closed, so recovery restores it. A window
  the ledger does not hold leaves once its row is gone or it has a Space: recovery restores
  one alive on no Space.
- Open item: stripping is decided as each window is concealed. When an app's most
  recently used window later moves to another display, or its focus moves to a window on
  another display, the app's windows concealed before keep the membership they had until
  they are concealed again. The per-app tracking and the membership job outside switches
  of commit a0f9e6d (branch `switch`) would update them, if the desk shows the case.
- Known limit: Mission Control shows each concealed window that keeps its ordinary Space
  as an empty placeholder with its app's icon, and Kosmos leaves it so. Stripping every
  concealed window takes away the ordinary Space that puts it there, at the switch cost
  measured above, 2.6 to 33.2 ms against 0.7 to 5.0 ms. Stripping only while Mission
  Control is open needs a signal that it opened, and none reached the Mission Control probe
  in two runs (26A428, September 24 and 25, 2026). `kosmos-probe mission-control` repeats
  its registrations and prints what arrives.
  - The Dock accepted yabai's four notifications (AXExposeShowAllWindows,
    AXExposeShowFrontWindows, AXExposeShowDesktop and AXExposeExit, yabai
    src/mission_control.c) and posted none while Mission Control opened by swipe and by
    Control-Up, or while App Exposé opened. It refused the two controls, AXMenuOpened and
    AXWindowCreated, with kAXErrorNotificationUnsupported (-25207), so no run showed that
    the probe's observer receives any notification from the Dock. The watcher registers
    no control, so running it again cannot settle whether the Dock posts the four names
    until a notification the Dock accepts and posts on demand is found to serve as one.
  - WindowManager.app, which holds Mission Control's classes and the same four names on
    macOS 27, refused all six with -25207.
  - WindowServer event 1204, which yabai reads for Mission Control before macOS 12,
    registered and never arrived.
  - In both runs two windows that were not the probe's stayed in the holding Space after
    the probe's windows left it. After the first run their ids were gone, and a live
    window with a neighbouring id was WindowManager's "App Icon Window" at layer 17. From
    that neighbour alone, WindowManager appears to draw the placeholders as windows of its
    own and add them to the holding Space. This did not reproduce live: `kosmos-probe
    holding`, read once a second before, during and after Mission Control with Kosmos's
    own concealed windows in its holding Space, found no WindowManager or Dock window
    there, and the only windows Kosmos had not recorded were JankyBorders' border windows,
    which follow the windows they border into the holding Space and out again (September
    25, 2026).

### 5.4 Focus

- There is one current focus intent, identified by a focus generation. A switch has its own
  generation, so a focus change adopted during a switch leaves the switch to finish.
- Every report names the key window, the front app's focused window. For an app
  activation, the app's worker reads the app's focused window. An app's focused window
  notification is stamped, and checked against the front process, on an observer thread
  that never waits behind the worker's calls into the app. Checked when the worker got to
  it, a click inside the front app that raced Kosmos's activation of another app was
  dropped (tla/README.md, change 12). A focus change reported by an app that is not front,
  as a background app opening a window causes, is no key window report: it consumes an
  echo it matches, is otherwise ignored, and never counts as the last report
  (tla/Kosmos.tla, Observe). Hotkeys and socket commands are stamped on receipt.
- Reports are classified in order:
  - An echo is a report of a requested window received after the request. Matching the
    app alone would take a Command-Tab to another window of that app for an echo.
  - A click or Command-Tab received before the latest command is stale. The command wins,
    and its focus is requested again.
  - A window on a workspace that a display shows becomes the focus intent, and its
    display becomes the focused one (section 5.13). It is requested again, in case an
    older request of Kosmos's landed after the user's change.
  - Only the user reaches a window that was hidden when it became key: with Command-Tab,
    or by opening that window, as `open` on a document, an app's Window menu or the
    Dock's window list do. Kosmos follows it to its workspace. Whether the window was
    hidden is judged at the report's stamp: the bridge queue notes when it sends each
    window's conceal and reveal, because a switch can reveal or conceal the window before
    the report is classified (tla/README.md, change 12). That excludes the report right
    after the key window left, when it closed or minimized or its app hid. macOS then keys
    another window itself, sometimes a concealed one, and Kosmos keeps its workspace and
    focuses it again. The window key before the report left the screen within the last second if
    WindowServer ordered it out or destroyed it, Accessibility reported it minimized, or
    NSWorkspace reported its app hidden.
  - macOS can key the next app before WindowServer orders a hidden app's windows out, so
    a report that would follow waits 100 ms, then is decided by what Kosmos knows of the
    window key before it. A report of another window replaces it. Every held report logs
    its outcome. A Command-Tab after that report follows as usual, 100 ms late. This
    happened live: Command-H on the only window of workspace 2 took Kosmos to workspace
    1, where macOS keyed Ghostty.
  - Fronting another window of the app that is already key can leave that app's key
    window in place, and the app reports it again. A report that repeats the key window
    while Kosmos awaits the echo of its request to that app is such a miss, not the
    user's choice. The missed request never comes back, so it leaves the expected
    echoes. Kosmos requests the focus again, once for each requested window; if that
    misses too, it leaves the key window where macOS put it. This happened live: Kosmos
    fronted Ghostty for a window of workspace 1, Ghostty reported the window a switch
    had just concealed on workspace 3, and Kosmos followed it there.
  - A visible window of a workspace that no display shows is key only during a switch:
    macOS re-keyed after a hide, or the user clicked or Command-Tabbed to a window about to be
    concealed. The switch wins, and its focus is requested again. After a batch fails,
    recovery shows every workspace's windows until a switch conceals them again. A
    click on one is then the user's, and Kosmos follows it as it follows a Command-Tab.
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
  The empty workspace's window is key already when Kosmos is the front process and the
  window's last key change on the main actor said it became key.
- A private request for a window runs as the split model in tla/Kosmos.tla specifies it,
  one step per action (KosmosCore's KeyRequest: FocusStart, WorkerStart, WorkerRead,
  WorkerRaise, FocusDecide). Each side records the echo, through the main queue, right
  before its own call that changes the key window, and never for the other side's call.
  The queue checks the generation, reads whether the target's app is front, hands the app's
  worker one job, and waits for it at most 30 ms, as the main actor waits on a worker.
  - Inside the front app the key record changes nothing and only AXRaise keys a window, so
    the worker keys it and the queue posts no key record. The worker ends a stale request,
    and one whose front app already has the target focused; then, just before the raise,
    it records and raises if the request is current and the app is still front.
  - For a background app the queue keys it and nothing raises the window: a raise in a
    background app lands after anything that fronts the app meanwhile, and in TLC it keyed
    a stale window over a newer activation (tla/README.md, change 12). The app's job does
    nothing, and the queue waits on it only so its key record follows the app's queued
    activation reads. Unless the request went stale or the app came front meanwhile, the
    queue records and posts the key record, which activates the app with the named window.
  - Nothing is recorded and later forgotten, so no late answer can orphan a call; `dropped`
    serves only a call that fails.
  - TLC passes every split config (tla/README.md on the hover branch, change 11): RaiseKeys and RaiseReports
    both ways, either app busy with the 30 ms timeout nondeterministic, background apps
    opening windows, and liveness. Kosmos builds the RaiseKeys case, where AXRaise alone
    keys the target inside the front app: it did so in 20 of 20 trials of `kosmos-probe
    keying` for stacked and side by side windows, where the record alone keyed 0 of 20
    (September 24, 2026). The model's WorkerKey step, for the other case, is left out.
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
  next window, or Kosmos's empty workspace window. A closed focus is replaced at once. A minimized or hidden one is
  replaced at once too, unless the key window macOS last reported left with it: then
  macOS's report of the next key window is still on its way and focuses. Focusing earlier
  could put Kosmos's echo between the departure and that report. When macOS keys no
  window, the departure focuses, and when no report comes within a second, as when an
  app keeps no key window after its last window minimizes, the departure focuses then.
  The second outlasts a minimize, whose next key window macOS reported 0.73 s after the
  minimize. A window keyed during the animation, by Kosmos or the user, is taken to leave
  macOS nothing to key when it ends (not measured; the departures probe asks). A click
  or Command-Tab during the animation reads as macOS's own key change, so Kosmos keeps
  its workspace.
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
    trials raised first and posted a down and up record pair. Kosmos's own sequence, the
    down record alone to a background app, keyed the named window in 20 of 20 trials of
    `kosmos-probe keying` (September 24, 2026). The public path chose the wrong window in 9
    of 9 trials, so a false trip costs more than a few late wrong windows
    (wm-research focus note, section 4; autoraise-steez trial results, September 8, 2026).
    A request with no report neither misses nor clears the count, so a record that changes
    nothing, as the record alone did inside the active app, goes uncounted.
- AXRaise runs on the app's worker, and only inside the front app. On macOS 27 the record
  alone leaves the key window unchanged inside the app that is already frontmost, for
  stacked and side by side windows alike, while AXRaise and then the record keyed the right
  window in every case (`kosmos-probe raise` on the hover branch). A hung app holds only
  its own worker. AXRaise took 0.65 and 1.02 ms at the median and 3.70 and 2.13 ms at
  most, over 120 raises in each of two runs (`kosmos-probe keying`, September 24, 2026).
- Open item: the key record alone keys a background app's window but leaves it where it
  was in the window order. It was on top in 0 of 20 trials, behind the windows of the app
  that was front and of its own app. The record and then AXRaise keyed it and put it on
  top in 20 of 20, while AXRaise and then the record put it on top in 11 of 20. Tiled
  windows do not overlap, so this shows with floating windows. yabai raises after its
  record for this. A raise in a background app is what failed TLC, so the raise after
  the record waits for the split model.
- The worker waits for the app to perform the raise, for up to 5 s. A raise it stopped
  waiting for still lands when the app gets to it: in TLC it keyed a concealed window after
  a newer command, and Kosmos followed it there (tla/README.md, change 12). A raise that
  outlasts the 5 s counts as made, so its echo is still recognized. Only a raise the app
  refuses or fails at once is dropped.
- While the path is off, and for a request whose SkyLight call fails, focus takes the
  public path on the app's worker: make the window the app's main window, raise it, then
  activate the app. A background accessory app with no window, as Kosmos is, made another
  app the front process in 10 of 10 trials with each of `activate`, yielding and then
  `activate(from:)` itself, and `activate(from:)` the front app, and Finder in 10 of 10
  with each (`kosmos-probe keying`, September 24, 2026). An empty workspace has no public
  path: its window is Kosmos's own, and an accessory app that activated itself became the
  front process in 0 of 10 trials, as activate returned false. The app
  picks its key window, so the spec's assumption that the requested window becomes key no
  longer holds, and a wrong window is adopted like the user's choice. A public request's
  expectation ends at the first report from its app that is no echo, so a click on the
  requested window afterwards is the user's. Private requests keep theirs until matched
  (tla/README.md, change 6). The spec models exact keying only, so its TLC passes do not
  cover the public path. If the app keys the requested window late, after the user chose
  another of its windows, that late report reads as the user's and pulls focus back,
  change 6's bounce in the fallback alone.
- An empty workspace keys a window of Kosmos's own (EmptyWorkspaceWindow): 1 by 1 point
  at the bottom left corner of the display the workspace is on, borderless, clear and
  transparent, ignoring the mouse, on every Space and out of the window cycle. With
  displays that have separate Spaces, keying a window makes its display the active one,
  which takes the menu bar and the next new window. An app fronted with no window
  brought forward still keys its own last key window: `kosmos_front_without_windows` let
  a stub key its window in 10 of 10 trials, and a stub whose every window was concealed
  keyed one of them in 10 of 10 in each of four ways, kept in their ordinary Space or
  concealed exclusively, fronted by `activate` or by `kosmos_front_without_windows`. So
  Finder, or any app with a concealed window, cannot be the target: Kosmos would follow
  the concealed window it keys off the empty workspace on every switch. A background
  accessory app keyed an invisible window of its own by the private key record in 10 of
  10 trials, from its own background thread and from another process
  (`kosmos-probe keying`, September 24, 2026).
  - Kosmos is an accessory app, and the inventory tracks only regular apps' windows, so it
    never manages or conceals the window. The window becoming key is the key window report
    for an empty workspace, as Kosmos keeps no worker for itself; it names no window and
    is the echo of the request's record of no key window.
  - Kosmos has no main menu, and the window swallows every key and key equivalent, so
    typing on an empty workspace neither beeps nor reaches a menu command such as Quit.
    Hotkeys still fire: Carbon hotkeys are taken before the key reaches any window.
  - Another app fronted with no key window takes the keys and key equivalents instead. Live
    on 2026-09-24, a click on the desktop of the left panel, which showed an empty
    workspace, fronted Finder, and Cmd-Q quit it; the report of no key window from Finder
    repeated the empty workspace's and went unnoticed. After a key press or a click in the
    last second such a report is the user's choice and stays, as is an app launched since
    the empty workspace window became key, which activates before its first window. With
    neither, macOS or the app fronted it, and Kosmos keys the empty workspace window again.
  - The kill switch guards the call like any private call, and a crash inside it turns the
    path off. The wrong window count judges only key records to other apps' windows, so
    that trigger leaves the empty workspace's window keyed privately. After a crash the
    empty workspace keys nothing and the previous window stays key, as there is no public
    path to Kosmos's own window.
  - AeroSpace does nothing on an empty workspace, so macOS keeps the outgoing window key
    while it is hidden and keystrokes reach it (`refresh.swift`, upstream at 39e51904). The
    aerospace-steez fork fronts Finder with `kCPSNoWindows` instead, following yabai (its
    commit 2031030b), which keys a Finder window whenever Finder has one.
- Open item: a focus request reads WindowServer on the main thread to skip a window that
  just left the screen (`leftScreen`). Right after a switch that read waits on
  WindowServer's Space transaction: 29 of about 290 busy main thread samples in 40
  switches on 2026-09-24. The focus queue could read it at FocusStart instead, off the
  main thread and closer to the key call. That changes RequestFocus and FocusStart in
  tla/Kosmos.tla, as the request would take a new generation even when the queue drops its
  target, so it waits for the focus spec's merge.
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
- Open item, for the report rules of the `focus` work: echoes out of order. Each app's
  observer thread sends its own reports, so on a fast sweep of the pointer across apps an
  earlier request's echo can reach the main actor after a later one's. Consuming an echo
  drops every expectation before it, so the late echo reads as the user's choice and
  focus goes back to the window the pointer left. The hover branch's merged spec removes
  only the matched record, together with rules that keep an expectation from lingering:
  records have a kind, an activation record from the key record or Kosmos's own window
  and an in-app record from the worker's raise; an activation read matches the oldest
  activation record of its app, whatever window it reads; a notification consumes an
  in-app record of its window and only joins an activation record; and after an echo
  whose window is not the intent, the intent is requested again. Removing only the
  matched record without them leaves an expectation whose echo was lost, as when
  Apps.activated reports nothing or a background key record's only report is the
  activation read, to swallow a later report of its window as its echo: a Command-Tab to
  a concealed window is then not followed. tla/Kosmos.tla here still drops the earlier
  records, so the code does too until those rules land with the spec.

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
- Display profiles are built in and matched by monitor name or serial. The first profile
  whose `when` monitors are all connected applies. The first profile without `when`
  applies to the built-in display alone. Any other displays, as with a display no
  `[monitors]` entry knows, keep the profile that applies, as Steve's `apply-profile.sh`
  kept its profile for displays it did not know. With none applying yet, as at launch,
  the first profile without `when` applies, else the base config. Kosmos resolves the
  profile again when the displays change (section 5.13). Runtime toggles are commands and
  never rewrite the file.
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

- The window under the pointer takes focus as soon as the pointer enters it, through the
  same exact-window focus request as a focus command, as Hyprland's `follow_mouse = 1`
  does.
- Focusing another app's window activates the app, which costs macOS about 94 ms of CPU
  outside Kosmos (section 2), so a pointer swept across windows of several apps activates
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
  out of a fullscreen Space, and a hover focus passes the fullscreen gate of section 5.4
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
  other. The hover branch's spec modeled it so, and its `hover` and `hover-settles`
  configs passed (commit ae9e5c1). With the hover unstamped, TLC found a click made before
  the hover but reported after it adopted, and focus left the window the pointer was in.
  The spec on this branch does not model hover yet.
- Holding Control pauses focus follows mouse, as AutoRaise's `disableKey` did. Control is
  read from each movement's flags, so the tap takes no keyboard events. A movement with
  Control held changes nothing, so after Control is released the next movement focuses
  the window under the pointer. Nothing is focused while a mouse button is down, because a
  movement with a button down is a drag event, which the tap does not receive, nor while
  a tiled window is lifted (section 5.13): the pointer is the user's during a drag.
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
    from a click, on the window or the Dock, when it handles the activation: a key went
    down within the last second, and after the last left or right mouse down and the last
    pointer movement (`CGEventSource.secondsSinceLastEventType` in the combined session
    state). With focus follows mouse the user seldom clicks, so a key press long ago would
    otherwise pass for Command-Tab when an app activates itself. The read takes no event
    tap, and the log gives the three times. A Command-Tab switcher held open for over a
    second reads as a click.
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
    `kosmos` never moves it. Neither does a click that Kosmos follows or adopts, a hover
    focus, nor a layout, resize or `join-with` command.
  - As with AeroSpace's `window-lazy-center`, the pointer moves only when it is outside the
    window, or the empty workspace's display. A tile's frame is the layout's after the
    change, the one Kosmos is writing, which the app's worker may not have applied yet;
    AeroSpace's binding slept 50 ms before it read the frame. A floating window's is the
    last frame the inventory heard. So the move reads nothing from WindowServer and runs on
    the main actor. While a window is lifted the pointer stays (section 5.13).
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
  the first event arrives. When macOS refuses the tap, Kosmos logs an error,
  `focus-follows-mouse on` exits 1 and says to allow Input Monitoring, and the next turn on
  or config load creates the tap again.
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
  section 3 rejects for the keyboard.
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
  - A raise of a background app's window. The key record keys it and leaves the stacking
    order alone (section 5.4), until the worker's raise after the key record lands. The
    window under the pointer is on top at the pointer already, so only the parts of a
    floating window that other windows cover stay behind them.
  - Keeping floating windows over a tile the pointer enters in the app that is front.
    Inside the front app only AXRaise keys a window (section 5.4), so the tile comes up
    over any floating window it overlaps, which Hyprland keeps on top. A tile of another
    app is keyed by the key record alone and stays where it is, so hovering from floating
    Messages onto a Ghostty tile keeps Messages on top (Steve's live test on 2026-09-24);
    only two windows of the front app bury one. Raising the floating windows again after
    the raise would key one of the front app's, or reorder only a background app's own
    windows. If it bothers in practice, the path is yabai's
    `window_manager_focus_window_without_raise`, which AutoRaise carries under FOCUS_FIRST
    (AutoRaise.mm:204): an AppKit-defined record (type 0x0d) with 0x8a = 0x02 to the app's
    key window, 10 ms later one with 0x8a = 0x01 to the target, then the private front and
    the key record. It would replace AXRaise on the worker for a hover focus of a tile, the
    echo recorded just before, once `kosmos-probe keying` shows it keys 20 of 20 in the
    front app with the window order unchanged.

### 5.12 Other tools

- **Status bar (SketchyBar).** Kosmos sends one `kosmos_state` event per change, holding
  everything a bar draws: every workspace with its display, whether it is shown and
  focused, and its windows' ids, app names and positions; the focused window and app; the
  active profile; and every connected display, numbered as SketchyBar numbers it, from the
  same WindowServer display list. A workspace's display is the one section 5.13 lays it
  out on. The bar runs no command on a switch. A bar that starts
  after Kosmos runs `kosmos state` once for the current snapshot, and clicking a workspace
  runs `kosmos workspace <name>`.
- **Borders (JankyBorders).** They work unchanged while inactive borders are transparent.
  With visible inactive borders, Kosmos would have to conceal each border window along with
  its window, as the AeroSpace fork did. Borders drawn by Kosmos itself are on the later
  list (section 7).
- **Display profile scripts.** Scripts that rewrite another window manager's config when
  displays change give way to Kosmos's profiles: Kosmos matches displays by serial,
  switches profile when displays change, and puts the profile name in the bar event
  (section 5.13). A binding runs `profile <name>` where one ran `set-profile.sh`.
- **Launchers and cheat sheets.** `kosmos list-bindings` asks the running Kosmos for the
  bindings it has loaded, so a launcher's keybinding list reads them instead of keeping its
  own copy, as the Raycast keybinds extension in Steve's dotfiles does. It prints one JSON
  array of objects with four strings: `mode`; `key`, as the config writes it, such as
  `alt-shift-left`; `description`; and `category`. Mode main comes first, then the other
  modes by name, each in file order.
  - KosmosCore writes the description and the category from the parsed command
    (`Command.summary` and `Command.category`), so the config holds no descriptions:
    `focus --boundaries all-monitors-outer-frame left` is "Focus left, across monitors" in
    Focus.
  - The categories are Focus, Move, Workspace, Monitor, Layout, Resize, Profile and Other.
    Moving a window to a workspace or a monitor goes with the workspace or monitor commands.
  - Profiles carry no bindings, so the list is the same under every profile.
  - With Kosmos not running, the CLI exits 1 and says so, as for every command. Before a
    config has loaded, as while Accessibility is missing, Kosmos answers that no hotkeys are
    registered.
- **Switching from another window manager.** Install Kosmos.app to /Applications and the CLI
  on the PATH; grant Accessibility to Kosmos itself; launch it at login; turn off the other
  window manager's login item and the helpers Kosmos has replaced by then (profile
  watchers at the switch; AutoRaise once focus follows mouse lands). Rolling back reverses
  those steps, so the other manager's config and the bar's code for it stay until the
  switch is final.

### 5.13 Displays

- Each connected display shows one workspace. One display is focused, and its workspace
  holds Kosmos's focus.
- Two orders number the displays, and neither stands in for the other.
  - Commands and the config order displays left to right, then top to bottom, as
    AeroSpace orders monitors: monitor numbers, `next` and `prev`, and the first display a
    monitor matcher matches follow that order.
  - The bar event keeps SketchyBar's numbers (`BarSnapshot.displayNumber`, from
    WindowServer's managed display list, section 5.12), so a bar item's `display` value
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
    display in the direction at the edge of the workspace. `focus` then focuses that
    display's workspace; `move` moves a tiled window there and follows it. A move is at
    the edge when the window has no sibling in the direction and no container above its
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
  screen, the user's or macOS's choice. Kosmos adopts it and focuses its display (section
  5.4). After the key window leaves, macOS can key a window on another display; Kosmos
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
- A burst of changes gets one response, 0.5 s after the last, as a wake does (section
  5.1). Kosmos reads the displays, resolves the profile again, which ends a forced one, and
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
  workspace for a drag when a change event (section 5.2) reports it, no frame write of
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
- A concealed window keeps its ordinary Space, as on one display, unless its app's most
  recently used window is shown on another display, since macOS prefers an eligible
  window on the current display over the app's key window on another display (section
  5.3, and its open item on windows concealed before that window moved).
- Open item: a click on the desktop of another display does not focus that display, as
  when its workspace is empty. AeroSpace watches left mouse up with
  `NSEvent.addGlobalMonitorForEvents` (GlobalObserver.swift), and when the pointer is in
  a display's visible area and that display's workspace is not the focused one, it
  focuses that workspace. Kosmos sees such a click only as Finder becoming front with no
  key window, which names no display. The pointer events of focus follows mouse (section
  5.11) could carry the same check.
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
    (section 5.8);
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
7. **Parity.** AeroSpace's features, with Omarchy's behavior where the two differ. Multi-monitor with display profiles that follow the
   connected displays, floating windows, rules, fullscreen, returning windows, the status
   bar event, and switching over (section 5.12). Other tools keep running beside Kosmos
   until their replacement lands. Timing compared against the AeroSpace fork.
8. **Beyond AeroSpace.** Replace what needed a workaround: focus follows mouse (retiring
   AutoRaise), moving and resizing windows with a modifier and the mouse (retiring
   BetterTouchTool's window moving), and `kosmos list-bindings` for launchers.
9. **Later.** A native bar as a separate process, borders from Kosmos's own model,
   persistence across restarts.

## 8. Left out of the first version

Scrolling and BSP layouts, tabbed and stacked title bars, resizing tiles with the mouse
(section 5.2), an embedded scripting language, window title matchers, marks, persistence
across restarts, and one macOS Space per workspace.
