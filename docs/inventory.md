# Inventory and events

- Windows are keyed by WindowServer id, and apps by pid plus process start time.
- Events come from three sources:
  - SkyLight window notifications on Kosmos's own connection: created, destroyed, ordered
    in and out, moved, resized, Space and session changes. The watch list is always sent
    whole. Events 804, 806 to 808, 815 and 816 arrive only for windows on it, and 811, 1325
    and 1326 for every window, 811 only while the list names some window. Kosmos's list
    names every window it tracks, candidate or not, so it is empty only before the first
    sweep or while it tracks no window. A new window then reaches the inventory by 1325 as
    it joins a Space. An earlier version of `kosmos-probe policy`, which sent no list or an
    empty one, got no 811 and got 1325 for its child's window (2026-09-27). Their ids and
    payloads were measured on macOS 27 and are decoded in one place, WindowServerEvent. A
    window event carries the window id first, and a Space membership event a 64 bit Space
    id, then the window id.
  - One AX observer per app: creation, focus, main window, destroy and minimize, and for
    2 s after Kosmos admits a new window that a rule on the title may reach, that window's
    title ([config.md](config.md)).
  - NSWorkspace app lifecycle events, plus a process exit source for each app. The
    inventory alone observes an app's hide and unhide: it records the departure or return
    of the app's windows, then passes the event to the controller.
- Only WindowServer evidence or app exit removes a window. AX silence, AX errors and the
  lock screen never do, and while the session is locked, creation and destruction wait. A
  read that gets no answer leaves the window's AX facts as they were.
- The inventory reads each process's activation policy once, since each read is a
  synchronous LaunchServices call, then follows it by key-value observing, and forgets it
  when the process's exit source fires. Read at every window event and at every row of a
  sweep, the call showed up on the main thread in samples of workspace switches
  (2026-09-24). The running apps come from NSWorkspace's list at start, since
  `NSRunningApplication(processIdentifier:)` returned nil for a running app then, and a
  later process is read as it launches or at its first window. A process LaunchServices
  does not know, such as JankyBorders, is not regular. NSWorkspace posts the launch only of
  an app regular as it launches, and the exit only of an app regular as it exits, so the
  exit source is there for the rest, and because pids come round again, about every 7 hours
  on the development Mac. A process that exited before its source started reports its exit
  at once (macOS 27). WindowServer names pid 0 as the owner of some windows (2 of 34 rows on
  the development Mac), and dispatch aborts on a process source for pid 0 or less, so such
  a pid's answer stays cached.
- An app can change its activation policy while it runs. RustDesk's Info.plist sets
  LSUIElement, and its remote desktop process makes itself regular for its window. Kosmos
  did not manage that window on September 27, 2026. In `kosmos-probe policy` that day, over
  10 rounds, a child launched as an accessory, from a bundle with LSUIElement set or
  setting the policy itself, then became regular and an accessory again, and in 5 rounds
  regular once more. NSWorkspace posted no launch of it, at its launch or when it became
  regular, and posted its exit only in the 5 rounds it exited regular. Key-value observing
  of `activationPolicy` reported each of its 25 changes to the probe, on the main thread,
  1.2 to 5.9 ms after the child began it, on the instance from NSWorkspace's list and on
  one made by pid alike. The child's call returned 1.3 to 4.0 ms after it began. A panel the
  child made once the call returned reached WindowServer 39 to 66 ms after the change began,
  while AppKit made it, so the observation came first there only because the panel took that
  long. For an app that makes its window faster the order is unmeasured, and the design does
  not depend on it. A window read while its app is not regular is left out, and the sweep
  that the change to regular starts admits it. `RegularApps` decides what each policy
  recorded calls for:
  - An app that becomes regular gets its Accessibility worker, and a sweep admits its
    windows the old policy left out, whose rules and placement apply as to any window
    admitted, so one there since Kosmos launched joins the workspace of the display under
    it ([displays.md](displays.md)). The sweep counts none of them as missed by events. An
    app first read before LaunchServices knew it, and found regular only by its launch
    notification, takes the same path.
  - An app first read as regular at a window, as one that became regular before it made
    any, gets its worker then, since no launch notification gave it one. Every regular
    record gives Apps the app, which skips one it has a worker for. Before this, such an
    app's windows were tracked and never managed, as Apps made workers only at its start
    and at launch notifications.
  - An app that stops being regular keeps its windows already admitted and its worker, and
    its new windows are left out until it is regular again. Dropping its windows as an
    exit does would break the rule that only WindowServer evidence or app exit removes a
    window, and one concealed then would stay on the holding Space until Kosmos quits, as
    a window that stops being managed does ([hiding.md](hiding.md)). The exit source stops
    its worker. Across a restart the next Kosmos reads the policy then and admits none of
    those windows. Each stays where it is, and one concealed shows over the shown
    workspace 5 s after the adoption, unmanaged, as a kept window no admission places does
    ([hiding.md](hiding.md)).
  - Nothing polls. Observing the 96 to 102 apps running took 7 to 13 ms in the probe's
    runs, about 0.1 ms each, which Kosmos pays once at start and once for each later
    process at its launch or first window.
  - Each observation ends before its app can be released. AppKit keeps each
    NSRunningApplication with an observer in an NSHashTable made with
    NSPointerFunctionsZeroingWeakMemory, which without garbage collection holds
    unretained pointers that nothing clears (AppKit's disassembly on macOS 27, and
    NSPointerFunctions.h). The instance's dealloc leaves it there and only logs that it
    "is being deallocated while observers are still registered". Each LaunchServices
    notification for the policy then sends `_hasASN:` to every instance in the table,
    freed ones included. NSKeyValueObservation holds its object weakly, so ending it
    once the app is freed removes nothing. The policyfix merge (6a9a3df) ended each
    observation with `policyWatches.removeValue(forKey: pid)?.observation.invalidate()`,
    and Swift released the tuple's app before `invalidate` ran. The Kosmos started at
    11:44 on September 28, 2026 logged 37 instances freed while observed, the first 11
    ms after it logged that it started and 7 within 80 ms of Outlook's exit at 11:48:16.
    At 15:58:42, as Phone began to quit, it crashed with EXC_BAD_ACCESS in
    `objc_msgSend` under AppKit's `runningApplicationNotificationCallback`
    (Kosmos-2026-09-28-155851.ips). An earlier version of `kosmos-probe policy` crashed
    so on September 27. `PolicyWatch`, in the KosmosPolicyWatch target so that the probe
    below runs it too, holds the app and ends the observation in its deinit, which runs
    before a class releases its properties, so every path that drops a watch ends the
    observation first.
  - `kosmos-probe policy-exits` runs children that launch, change their policy and exit,
    4 at a time, observes each with `PolicyWatch` and ends the observation at the exit
    source. Ended as the merge did, 3 of 10 debug runs of 100 children crashed with
    Kosmos's stack. The other 7 debug runs and 5 release runs lived, and each logged up
    to all 100 instances freed while observed and 239 to 244 callbacks that threw, which
    AppKit logs and skips, as it sent `_hasASN:` to other objects in the freed memory. A
    throw ends that notification's walk, so the live instances in the table miss the
    change too, and those runs got 4 to 7 observations, against about 248 in a run of
    100 with `PolicyWatch`. So one instance freed while observed can keep Kosmos from
    seeing an app become regular, before anything crashes. Kosmos logged no such throw
    from 11:44 to 15:59 on September 28, so there the crash was the only sign. With
    `PolicyWatch`, none of 7 runs logged either or crashed (September 28, 2026). 6 of
    them, debug and release, ran 2500 children in all with an identical copy of the
    class, and 1 ran 300 with the class itself. 1059 of those children exited in the run
    loop turn of a change. The order of a change's notification and the exit does not
    matter, as AppKit walks the table on the main thread under the lock that removing an
    observer takes, and the removal takes the instance out of the table.
  - The ceiling is a process LaunchServices did not know at its first window, which has no
    instance to observe, so only a launch notification can say it became regular.
    NSWorkspace's list gained the probe's child 40 to 180 ms after it started, long before
    its window. Observing that list, as LaunchServices learns of each process, would close
    the gap.
  - Only `RegularApps` has a runnable check. Kosmos has no test target for KosmosApp, so
    no test covers the wiring in Inventory and Apps that observes each app, gives Apps
    each regular one, sweeps, stops the worker at exit and keeps the admitted windows. A
    KosmosApp test target would add one. `kosmos-probe policy 2 bundle titled` shows the
    wiring against a running Kosmos, with a standard window the child makes before it
    becomes regular and one it makes as it does. `kosmos-probe policy-exits` runs
    Kosmos's own `PolicyWatch`.
- Events drive the inventory, with no timer. A 0.1 ms SkyLight sweep runs at launch, on a
  Space change, after an unlock or a wake, as yabai, rift and Amethyst do, and when an app
  becomes regular. A workspace switch posts no Space event, so it starts no sweep
  (`kosmos-probe events`, 40 switches on 2026-09-24). Sweeps asked for while one runs
  start one more when it ends, so a burst of Space events ends with a sweep that started
  after the last of them. The Space list omits windows on no Space, such as one created
  but not yet shown, so a sweep reads the tracked windows missing from it directly before
  it counts them gone, and the windows first seen while locked too, which an unlock sweep
  admits even when ordered out. Those reads can block during a Space transition, so they
  run off the main thread, after the reads for events already waiting. A window a sweep
  finds or loses that no event reported is logged as "missed by events", and so is a known
  window whose ordered in state or candidate status (level 0, no parent) a sweep corrects,
  so a gap in macOS's notifications shows in the log. The unlock sweep counts none of the
  windows the lock held back: one that arrived while locked, and one destroyed while
  locked or whose app exited then. An event handled after a sweep, for a change its
  snapshot already had, came late and still counts. Of the 32 windows sweeps counted from
  September 24 to 26, 2026, 28 had their event within 1 s after the sweep, which Kosmos
  logged then (live log), so a count most often marks a late event. The 3 s sweep this
  replaced found and lost none on 2026-09-24, over a day of use and live tests.
  It counted none of its corrections, which it logged only at debug or info level.
- A read of window rows or of the window list can fail, as during a Space transition, and
  `SkyLight.rows` and `SkyLight.allWindowIDs` then return nil, so no caller takes the
  failure for every window gone. A sweep whose read fails changes nothing, and a failed
  read for events leaves each window they name as it was; each logs a notice. The ceiling:
  a failed first sweep at launch leaves every window unmanaged, and a failed sweep after
  an unlock leaves the windows the lock held back waiting, each until the next sweep, at
  the next Space change or the next app to become regular. Sweeping again after a delay
  would close both. A read of one window that fails leaves it as the inventory has it,
  ordered in or not. No failed read shows in the live log of September 24 to 26, 2026; the
  one mass loss, 23 windows at 23:22:08 on September 25, was real closes whose events came
  3 to 5 ms late.
- A change of a window's level posts no event of its own. In `kosmos-probe level` on
  2026-09-24, 60 changes of an invisible or off screen window posted nothing while no
  other app's window came or went. In three runs while other apps' windows came and went,
  12 of 18 changes posted 815 as the new level landed, 10 of them 808 too. The inventory
  reads a window's row again on either, and otherwise at the window's next move, resize,
  reorder, order change or Space change, or at the next sweep, which logs the change as
  missed by events. Kosmos accepts that gap, with no timer to close it. A visible window's
  level change is unmeasured, as the probe keeps its window invisible. A window that stops
  being a candidate stays in the inventory: apps such as Helium change a window's level
  while it lives, and dropping the window would lose it until the next sweep.
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
  changed during a running sweep from the moment the event arrives. `Sweeps` keeps these
  rules, the sweep asked for during another and the windows the first sweep sees, which
  were there at launch.
- The session counts as locked from loginwindow's `com.apple.screenIsLocked` to
  `com.apple.screenIsUnlocked`, and while NSWorkspace reports it switched out by fast user
  switching. macOS 27's loginwindow still names both notifications, and alt-tab and rift
  listen for them. Kosmos asks for immediate delivery, because AppKit holds distributed
  notifications for an app that is not active. The session dictionary
  (`CGSessionCopyCurrentDictionary`) gives the state at launch, as alt-tab seeds it, and is
  read every 5 s while locked, so a missed unlock cannot stop Kosmos for good. Unlocked,
  the dictionary on this Mac has no `CGSSessionScreenIsLocked` key, and a missing key
  reads as unlocked. While locked it had the key. From September 24 to 26, 2026 all 128
  reads while locked had `CGSSessionScreenIsLocked=1`, and none read as an unlock (live
  log), so the 5 s read does not undo a lock. loginwindow
  coming to the front, which AeroSpace and rift also watch, is no lock signal. It also
  fronts its own dialogs, such as the log out confirmation.
- While locked, the inventory admits and removes no window and runs no sweep, and Kosmos
  writes no frames, runs no hides, requests no focus, ignores focus reports and refuses
  commands. After an unlock, and after a wake while unlocked, the inventory sweeps, and
  Kosmos reads the displays again ([displays.md](displays.md)), writes every tiled window of the shown
  workspaces to its frame on their areas whatever the frame ledger holds, conceals and
  reveals every window again, requests the focus intent and publishes the state. A wake can post both `didWake` and `screensDidWake`; each restarts a 0.5 s
  wait, so a burst gets one resync, and an unlock inside the wait resyncs instead. No
  measurement chose the 0.5 s; the log gives the gap between the two. A wake
  gates nothing. A sleeping Mac runs nothing, and one that asks for a password after sleep
  locks its screen first.
- The model can still change while locked, as when a window minimizes or returns, its app
  hides, or a report held before the lock is decided; the resync carries out those plans.
- A tab switch ([tree.md](tree.md)) can create or destroy one of its two windows while locked. Every
  order change of a candidate window is held with its time, creations and destroys too,
  and a window first seen while locked is watched until the unlock sweep admits it. At
  the unlock the changes are reported in the order they happened, each with its own time
  and before any change after the unlock, so switches pair as they would have unlocked.
  Kosmos acts on them at the unlock. The sweep then admits and removes windows without
  reporting their order again.
- A new window becomes managed when it is ordered in, has no parent window, sits at level 0
  and its subrole is AXStandardWindow. Apps whose AX is late get ten retries 100 ms
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
- An AppKit Open or Save panel standing alone is managed and floats at its own frame
  (`WindowRule.floats`, [config.md](config.md)). Its subrole is AXStandardWindow, and
  its AXIdentifier names it. Kosmos tiled ChatGPT's Save panel for a download beside
  ChatGPT's window (live log, September 29, 2026, 12:26:02). System Events, polled every
  200 ms through three downloads that day, read the panel as title "Save", subrole
  AXStandardWindow and AXIdentifier `save-panel`, and ChatGPT's main window with an empty
  AXIdentifier.
  - The identifiers are `save-panel` for NSSavePanel and `open-panel` for NSOpenPanel. On
    macOS 27.0 (26A428), on September 29, 2026, panels made and never shown in a process of
    their own, which took no focus, answered `accessibilityIdentifier()` with those names,
    in and out of the App Sandbox, where the class stayed NSSavePanel or NSOpenPanel.
    Those two classes override `accessibilityIdentifier`; NSRemoteSavePanel and
    NSLocalSavePanel, which subclass NSPanel, do not. No sandboxed app's panel on screen
    has been read, so that its window is the NSSavePanel is inferred. The dyld shared
    cache holds both strings, and four other `-panel` names, which Kosmos does not float:
    `find-panel`, `spelling-panel`, `substitutions-panel` and `autofill-panel`.
  - The worker reads the identifier with the subrole and the minimized state, one more
    Accessibility call for each window read. A failed identifier read counts as no
    identifier, so an app that fails it only for this attribute still has its windows
    managed, where a failed subrole read leaves the window out. Against 11 windows of 10 running apps that
    day, each of the three reads took 0.02 to 0.15 ms (median of 20). One
    `AXUIElementCopyMultipleAttributeValues` for all three took 0.04 to 0.17 ms, less than
    the two reads before, and would take the place of the three if window reads ever cost
    enough to matter.
  - A sheet, a panel attached to its window, has that window as its WindowServer parent,
    so it is no candidate and Kosmos leaves it alone.
  - The ceiling: a file dialog an app builds itself, rather than with NSSavePanel or
    NSOpenPanel, carries no such identifier and tiles unless a rule floats its app.
- A standard window whose zoom button is there and disabled floats at its own frame as a
  dialog, unless its app's rule says `float = false` (`WindowRule.floats`,
  [config.md](config.md)). AppKit disables the button on a window without the resizable
  style, and Chromium on one it will not let be resized or maximized
  (`ApplyNSWindowSizeConstraints` in ui/gfx/mac/nswindow_frame_controls.mm). Hyprland,
  which Omarchy runs, floats a window that cannot be resized too, which it reads from equal
  minimum and maximum sizes (`CWindow::suggestsFloat`).
  - On macOS 27.0 (26A428), on October 2, 2026, windows made and never shown in a process
    of their own answered AXEnabled false for the zoom button without the resizable style
    and true with it, for NSWindow and NSPanel alike. A minimum size equal to the maximum
    left it enabled.
  - AeroSpace's Accessibility dumps (`axDumps/` at 74a1bf17e8, October 1, 2026, from macOS
    15 to 27 where they name it) hold 54 standard windows at level 0 of regular apps. The
    zoom button is disabled on 6, all dialogs: Calendar's and Mail's settings, Raycast's
    Settings, Ghostty's About, Calculator, and Safari's Google sign in window. Each main
    window there has it enabled, or has no buttons, as Ghostty with its window decorations
    off.
  - `kosmos-probe window-kinds` read the 7 windows of Steve's 7 regular apps that day.
    Each was a main window with its zoom button enabled and AXSize settable, and no
    settings, About or Get Info window was open.
  - AeroSpace floats a window whose fullscreen button is missing or disabled, and names in
    code the apps whose main windows have none (`isDialogHeuristic` in
    Sources/AppBundle/model/AxUiElementWindowType.swift). Steve's Activity Monitor window
    has none, nor do VLC's and VS Code's with `window.nativeFullScreen` off, and each keeps
    its zoom button enabled. AeroSpace names Activity Monitor and VS Code, and floats VLC's
    main window.
  - The worker reads the button and its AXEnabled with the subrole, two Accessibility
    calls more for each window read, which took 0.04 to 0.10 ms together for Steve's 7
    windows (median of 20). A missing button or a failed read leaves the window tiled.
    Kosmos decides at admission, as for a rule, so a window the saved layout has keeps its
    place.
  - The ceilings. A dialog its app lets be resized tiles, as System Settings, whose zoom
    button AeroSpace's dump of macOS 26.1 reads enabled, IntelliJ's Rebase dialog and
    Archive Utility's progress window. A rule floats such an app, as
    [sample-config.toml](sample-config.toml) floats System Settings. A window its app holds
    to one size by equal minimum and maximum sizes tiles too; WindowServer's constraints,
    from which the inventory reads the minimum ([geometry.md](geometry.md)), would show it,
    once such a window turns up. Whether Chromium disables the zoom button of the window a
    dragged tab makes is unmeasured. AeroSpace keeps Chrome out of its test because the
    fullscreen button is disabled then, and such a window would float here.
- The worker reads each window's title with its other facts, for rules on the title
  ([config.md](config.md)), one more Accessibility call for each window read. A failed
  read counts as no title, which no rule on the title matches.
  - For 2 s after Kosmos admits a new window of an app that a rule on the title names, the
    worker observes that window's AXTitleChanged. It reads the title as the observation
    starts, since the title can have changed after the window's read, and at each change,
    and reports it; the inventory keeps it, and the controller checks the rules again.
  - `kosmos-probe window-kinds` read 6 windows of 6 apps on October 2, 2026, in two runs
    (median of 20): 0.018 to 0.082 ms for the title, and 0.025 to 0.131 ms for an
    AXTitleChanged registration with its removal. Each window watched costs a registration,
    its removal and a title read, then a title read and a main actor turn at each change of
    its title. Chrome and Helium were not running, so their windows' costs are unmeasured.
  - Other windows' titles are not observed, so an app whose windows change title often, as
    a terminal's, costs nothing at a change, and Kosmos keeps each such window's title from
    its last read. A window its app reopens, or a tab dragged out of its group, is placed
    by that title.
- A window with another subrole, as AXDialog, AXSystemDialog, AXFloatingWindow or AXUnknown,
  stays unmanaged. Kosmos never tiles it, and it stays where its app puts it. Of AeroSpace's
  71 dumps of windows at level 0 of regular apps, 17 report another subrole: 13 popups, such
  as Chrome's find bar, Xcode's Open Quickly and Emacs's child frames; qutebrowser's main
  window with its decorations off; and 3 dialogs, Xcode's Settings (AXDialog), Transmission's
  inspector (AXFloatingWindow) and Firefox's video in its own fullscreen (AXUnknown).
  AeroSpace manages such windows as floating windows behind a popup test with exceptions
  named by app (`isWindowHeuristic`).
  - The ceiling is that such a dialog does not hide with its workspace, gets no border, and
    is passed by focus commands and focus follows mouse. A close button that is there and
    enabled holds for Xcode's Settings and Transmission's inspector and for none of the 13
    popups, so managing these windows as floating would start from it, once a dialog left
    over another workspace shows up often enough to matter.
- A known limit. A window on an ordinary Space that no display shows at launch, as one
  behind a native fullscreen Space, is managed only once its Space is shown, since its
  app's window list names only windows on shown Spaces. On 2026-09-24 Kosmos restarted at
  23:50:33 while the main panel showed Moonlight's fullscreen Space. The launch sweep found
  the ChatGPT, Helium and Activity Monitor windows on the ordinary Space behind it as
  candidates, but no read returned their facts. Steve left fullscreen at 23:54:31, and the
  sweep after that Space change managed all three within 0.6 s. yabai's search of an
  app's elements by id, from a remote token, would admit them at launch. It finds only
  windows some process has read from the list before, and a search that finds nothing
  took 0.4 to 0.8 s (`kosmos-probe ax-search` at 174c067, since removed), so Kosmos leaves
  the case to the next Space change. Launches behind a fullscreen Space often enough to
  matter would call for it. A window the saved layout has holds its tile there until then,
  unless the tree changes first ([tree.md](tree.md)).
- At launch the saved layout puts each window it has back on its workspace as the sweep's
  window is admitted ([tree.md](tree.md)). A window of a hidden workspace is concealed by a
  batch of its own before any frame is written to it, so it never takes a tile of the shown
  workspace, and the shown workspace's windows keep their tiles. Until then it shows, as
  quit recovery showed it ([hiding.md](hiding.md)).
