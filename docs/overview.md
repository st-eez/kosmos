# Kosmos design overview

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
| Some Carbon hotkeys stop while any app holds Secure Input, for example in a password prompt (`kosmos-probe secure-input`, [hotkeys.md](hotkeys.md)) | Show Secure Input and its holder |
| Pixel-based container weights produce wrong and negative sizes | Store fractions |
| After a conceal or reveal, a check of the holding Space found the change 0 times in 50 each. After one synchronous bridged read, it found it 50 times in 50 each; the read took 1.3 ms median, 3.6 ms at most (`kosmos-probe barrier`) | One bridged read can confirm a switch, where the fork polled |
| Live on 2026-09-24, 40 alternating switches per run between two workspaces of one window each. Reading the holding Space directly every 0.1 ms confirmed each batch at a median of 2.10, 2.18 and 2.95 ms in three runs (p90 3.66, 4.83 and 3.44 ms; at most 4.62, 9.79 and 3.86 ms), and all 120 confirmed before the barrier was due. The barrier alone confirmed at 3.31 and 3.44 ms median in two runs (p90 4.72 and 5.24 ms; at most 11.08 and 10.59 ms). Switches over 8.3 ms from keypress to the end: 10 of 120 with the reads, 21 of 80 with the barrier alone | Direct reads confirm a switch; the barrier backs them up after 10 ms |
| Bridged Space operations from a process that has not started AppKit do nothing. With `NSApplication` initialized, the guardian restored a concealed window 130 ms after `kill -9`, 100 ms of it a deliberate settle (`kosmos-probe survive-kill`) | The guardian is a prohibited AppKit client with no Dock icon |
| Keying a window of another app costs about 94 ms of CPU outside Kosmos: BiomeAgent 29 ms, spotlightknowledged.updater 15, MenuBarAgent 15, duetexpertd 14, WindowManager 6, ContextStoreAgent 6 and the activated app 8, plus 12 for BetterTouchTool on the development Mac. Five stub apps were keyed back and forth through the focus path, 384 activations against 96 in 73 s each, and the cost is the difference between the two; WindowServer's share was lost in the noise of the desktop in use. The focus call took 4.4 ms at the median and 16.6 ms at p95 (`kosmos-probe sweep` and `script/sweep.sh`, commit 3223999 on the hover branch) | Accepted for focus follows mouse, which focuses the window the pointer enters at once ([focus-follows-mouse.md](focus-follows-mouse.md)) |
| Keying a window through the focus path leaves the stacking order alone. Inside the front app the key record alone keyed nothing in 20 of 20 trials, stacked or side by side, and AXRaise alone keyed the window in 20 of 20. For another app the key record alone keyed the window in 20 of 20 and put it on top in none, behind the windows of the app that was front and of its own app; the key record then AXRaise keyed it and put it on top in 20 of 20, and AXRaise then the key record in 10 or 11 of 20. Each count held in each of four runs of `kosmos-probe keying 10` on September 24, 2026. Over the four, an app whose focused window was the target already reported it again after the key record then AXRaise in 6 of 40 trials, and after the key record alone in none. AXRaise in a background app made the app report a focus change without keying it, 0.3 to 0.6 ms later in 74 of 80 trials and 3.9 ms at most. AXRaise took 0.30 to 1.02 ms at the median and 1.39 to 3.70 ms at most, over 120 raises per run | Inside the front app the worker raises. For another app the queue posts the key record and the app's worker raises the window after it ([focus.md](focus.md)) |
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
| Modifier drags | An active event tap for the left and right buttons at the annotated session location, each event decided on the tap's thread from WindowServer's hit test | `NSEvent` global monitors, which cannot keep an event from the app. A hit test of the model's frames, which knows no stacking order and would take a click on a panel over a tile |
| Borders | A click-through window of Kosmos's own per bordered window, ordered directly above it, drawn by Core Animation from the model's frames, focus and slides | JankyBorders, a separate process drawing from WindowServer's events, which knows no workspace or slide |

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
| Main actor | The model (inventory, workspaces, trees, focus intent), command execution, layout, hotkey dispatch, the bar snapshot, the display links that step slides and the bridged sends of a slide (below), the border windows | AX calls, any other bridged Space operation, waiting on another process beyond the reads listed below, file syncs, process launches |
| One AX worker per app (an actor with a custom executor on the app's run loop) | That app's AX elements, frame writes and reads, the raise that keys a window of the front app, and the raise after a key record. Its observer runs on a second thread, which stamps each focus notification and checks the front process in its callback | Touch the model directly |
| Focus queue, serial | Front-process calls and key records, generation checks, the already key check | Wait on a worker longer than 30 ms |
| Bridge queue, serial | The bridged Space operations of hiding and recovery, the reads that confirm them, the barrier read, and creating the Spaces windows slide in | Run past its time budget |
| IPC queue | Socket I/O, subscriber outboxes, Mach sends to the bar | Block the main actor |
| SkyLight notification callback | Copy the payload and hand it to the main actor | Anything else |
| Inventory read queue, serial | The rows WindowServer gives for window events, one query for each main run loop turn's events, and the sweep's reads, in order | Change the inventory |
| Slide queue (`kosmos.slide`), serial | The reads of sliding windows' rows until their writes land, and the Space transform sent for each new frame they find | Change the model |
| Pool check queue (`kosmos.slide.pool`), serial | The barrier and the read that show a slide's window out of its Space before the Space goes back to the pool | Change the pool, which the main actor holds |
| Border queue (`kosmos.borders`), serial | The reads of a border's Spaces and its window's, and the move of the border to its window's Space on Kosmos's own connection ([borders.md](borders.md)) | Set a border's frame or order, which the main actor does |

The main actor waits on a worker only with a deadline of about 30 ms. A slow app finishes
on its own and never delays another app.

The main actor makes these synchronous reads of other processes. Of them, a switch reads
only the pointer's location before it sends its batch, with mouse follows focus on. What is
known of their cost:

| Read | When | Cost |
| --- | --- | --- |
| A few windows' rows from WindowServer (`SkyLight.rows`) | Whether the window a focus request names, or the key window before a report whose verdict needs it, just left the screen (`Inventory.leftScreen`); the shown floating windows' frames after a switch's focus request (`bringFloatingHome`); the Dock check of an activation after a click, with mouse follows focus on; the level of the window the pointer entered on a display whose workspace is empty | About 0.1 ms a read on the laptop, and 1.4 ms at the desk while a switch's Space transaction commits ([inventory.md](inventory.md)). The focus request's read was 29 of about 290 busy main thread samples in 40 switches, an open item in [focus.md](focus.md). `bringFloatingHome` logs each read's time |
| The front process (`kosmos_front_pid`) | Each activation's report, once the app's worker answers; hover focus | 1.6 µs ([focus.md](focus.md)), and 54 µs at the median in the key holder probe ([focus-follows-mouse.md](focus-follows-mouse.md)) |
| The process holding the key window (`kosmos_key_focus_pid`) | Hover focus, only when a window or an empty workspace would take focus | 120 µs at the median, 42 ms at most ([focus-follows-mouse.md](focus-follows-mouse.md)) |
| LaunchServices through `NSRunningApplication`, one synchronous XPC call each | A process's activation policy, once; whether a window's app is hidden at each admission, unhide and look; an app's launch date when it keys no window on an empty workspace; the Dock check's bundle identifier; the name of an app Apps has no worker for, and of the Secure Input holder | Unmeasured per call. Read at every window event, the activation policy showed up in samples of switches, so it is read once per process ([inventory.md](inventory.md)) |
| The pointer's location (`CGEvent(source: nil)`), and the session's event times and button state (`CGEventSource`, `NSEvent.pressedMouseButtons`) | The first change event of a press; a drop at a hotkey; each hotkey while modifier drags are on; mouse follows focus's move, and a workspace command from a hotkey with it on; each activation with it on | Unmeasured |
| WindowServer's hit test (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`) and the display under a point (`CGGetDisplaysWithPoint`) | Each left mouse down, the hit test only with mouse follows focus on | Unmeasured |
| The displays (`NSScreen`, `DisplayIdentity`), the session dictionary (`CGSessionCopyCurrentDictionary`) and the permission checks | Launch and each display change; the dictionary every 5 s while locked and at each Secure Input change while it is on; the permissions at a config load and twice a second while the setup window shows | Unmeasured |

Bridged Space operations do not run on the bridge queue alone. The main actor sends a
slide's: it adds the window to a Space of the pool, sets the Space's transform and alpha at
each display frame and takes the window out at the end. The slide queue sets the transform
for each new frame its reads find ([geometry.md](geometry.md)). The limit: each goes to
WindowManager.app as the bridge queue's do, and whether a send waits on WindowManager.app
while it is busy is unmeasured. The `slide frames` log line gives the time the main actor
spends in each display's frames, the sends included. The sends go out while the bridge
queue sends its batches, to other Spaces.

### 4.3 A workspace switch

1. A hotkey or socket command arrives. The main actor updates the model: the new visible
   workspace with a new switch generation, and a focus intent with a new focus generation.
2. The incoming workspace was laid out while hidden, so its frames are usually current.
   The frame ledger leaves out each target a window already has or was already sent, with
   no read from WindowServer, and only changed frames go to their apps' workers.
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

Target, to be confirmed by the probes in [section 6](#6-verification): a few milliseconds of Kosmos's own
work, plus WindowServer's time for two bridged operations and one activation (about 7 ms,
off the main thread).

## 5. Components

Each component has a doc of its own. [README.md](README.md) lists them with the source
files each one covers.

## 6. Verification

- **TLA+ first.** Before the scheduler exists, specify it:
  - one main actor, per-app worker queues, and the focus and bridge queues;
  - echo accounting and the switch protocol in [4.3](#43-a-workspace-switch).

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
   bar event, and switching over ([integrations.md](integrations.md)). Other tools keep running beside Kosmos
   until their replacement lands. Timing compared against the AeroSpace fork.
8. **Beyond AeroSpace.** Replace what needed a workaround: focus follows mouse (retiring
   AutoRaise), moving and resizing windows with a modifier and the mouse (retiring
   BetterTouchTool's window moving), `kosmos list-bindings` for launchers, and borders
   from Kosmos's own model (retiring JankyBorders).
9. **Later.** A native bar as a separate process, and persistence across restarts.

## 8. Left out of the first version

Scrolling and BSP layouts, tabbed and stacked title bars, resizing tiles by their edges
([geometry.md](geometry.md); a modifier drag resizes them, [modifier-drags.md](modifier-drags.md)), an embedded scripting language,
window title matchers, marks, persistence across restarts, and one macOS Space per
workspace.
