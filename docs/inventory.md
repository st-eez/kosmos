# Inventory and events

- Windows are keyed by WindowServer id, and apps by pid plus process start time.
- Events come from three sources:
  - SkyLight window notifications on Kosmos's own connection: created, destroyed, ordered
    in and out, moved, resized, Space and session changes. The watch list is always sent
    whole. Their ids and payloads were measured on macOS 27 and are decoded in one place,
    WindowServerEvent: a window event carries the window id first, and a Space membership
    event a 64 bit Space id, then the window id.
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
  Kosmos reads the displays again ([displays.md](displays.md)), writes every tiled window of the shown
  workspaces to its frame on their areas whatever the frame ledger holds, conceals and
  reveals every window again, requests the focus intent and publishes the state. A wake can post both `didWake` and `screensDidWake`; each restarts a 0.5 s
  wait, so a burst gets one resync, and an unlock inside the wait resyncs instead. A wake
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
  matter would call for it.
