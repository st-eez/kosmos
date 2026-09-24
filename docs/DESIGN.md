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
| After a conceal or reveal, a check of the holding Space found the change 0 times in 50 each. After one synchronous bridged read, it found it 50 times in 50 each; the read took 1.3 ms median, 3.6 ms at most (`kosmos-probe barrier`) | One bridged read confirms a switch, where the fork polled |
| Bridged Space operations from a process that has not started AppKit do nothing. With `NSApplication` initialized, the guardian restored a concealed window 130 ms after `kill -9`, 100 ms of it a deliberate settle (`kosmos-probe survive-kill`) | The guardian is a prohibited AppKit client with no Dock icon |

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
- The barrier at the end confirms that each revealed window left the holding Space.
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
- Skip activation when the target is already key. When a newer command for another
  workspace is already queued, the older one lays out but doesn't focus.
- The private path has a kill switch: a crash guard, and repeated wrong-window read-backs
  disable it.
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
  workspace at their saved position.
  - If the user restored one from the Dock, Kosmos follows it to that workspace, as it
    does for Command-Tab.
  - A `summon` command brings a window to the current workspace on purpose.

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

- The window under the pointer becomes key as soon as the pointer enters it, through the
  same exact-window path as a focus command, as Hyprland's `follow_mouse = 1` does.
  Tiled windows never overlap, so only focus moves; a floating window is also raised.
- Instant focus has one cost on macOS that it lacks on Linux: focusing another app's
  window activates the app, and activations cost macOS's app usage daemons CPU (section
  2). Sweeping the pointer across several windows activates each of them. AutoRaise waits
  for the pointer to rest on a window for about 100 ms to avoid that. Kosmos starts
  without a delay, measures a sweep's CPU and daemon activity, and adds the shortest dwell
  that the measurement justifies, if any.
- The pointer must move at least 2 pt to count, holding Control pauses it, and chosen apps
  are ignored: the settings an AutoRaise user has today.
- Kosmos finds the window under the pointer in its own model: floating windows first, then
  the shown workspace's tiled frames, which never overlap. Moving the pointer queries no
  window list.
- Pointer movement arrives through a listen-only event tap on its own thread, so a pointer
  at rest costs nothing. AutoRaise polls 20 times a second.
- Nothing is raised while a mouse button is down, while the front app is in native
  fullscreen (AeroSpace's focus follows mouse raised tiled windows over fullscreen video),
  over a window Kosmos does not manage (menus, the bar, panels), or during Mission Control.
- A hover focus counts as a command: the session adopts the window, and its focus
  request's echo is consumed like any other.
- The pointer follows focus the other way too. A command that focuses a window moves the
  pointer to its center unless the pointer is already inside it, and so does Command-Tab
  to a window that is not under the pointer. A click always happens under the pointer, so
  it never moves it.
- `focus-follows-mouse = true` turns it on, with ignored apps and the pause key as settings;
  the command `focus-follows-mouse on|off|toggle` switches it at run time.

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
