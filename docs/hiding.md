# Hiding and recovery

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
  of the app, and the departure rule keeps Kosmos's workspace ([focus.md](focus.md)).
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
  app's activation policy is now read once ([inventory.md](inventory.md)), the departure of the window key
  before a report only when its verdict needs it ([focus.md](focus.md)), and the pointer's target frame
  comes from Kosmos's layout with no read, and never after a switch ([focus-follows-mouse.md](focus-follows-mouse.md)). Live on
  2026-09-24, 40 alternating switches between two workspaces of one window each, back to
  back under the same load (load average 5 to 8): main at 636a019 took 3.53 ms from
  keypress to the end at the median and 8.42 ms at most, and the completion waited over
  1 ms for the main actor in 12 switches; with the three changes (367cd28), 3.75 and
  10.25 ms, and 3 such waits, so the switch time is the same
  within noise. Busy main thread samples in 40 switches fell from about 290 to about 66,
  but the first sample's build still ran the 3 s sweep timer, whose sweeps caused its 6 to
  10 ms stalls until 248f668 removed it. Half of the about 66 left were the 815 reads,
  which now run off the main thread ([inventory.md](inventory.md)). Before that, switches at Steve's desk
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
  since that read failed, and recovery takes it out with the rest: removing a window that
  is gone does nothing, and left in, it would keep the record for good. Recovery adds each
  one without an ordinary Space to the current Space of the display under it, or to the
  Space a reveal would choose, then removes them from each recorded Space, destroys the
  Spaces and clears the record. It removes an added window from a recorded Space only once
  the add landed, and keeps the record while a concealed window is left there. A window
  whose Spaces do not read stays where it is and keeps the record too, since a removal
  could leave it on no Space and an add could take it off its own. Every step can safely
  run twice.
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
- The Spaces windows slide in ([geometry.md](geometry.md)) are recorded in a list of their
  own, after the windows, where a reader that predates the list stops, so it still
  restores every concealed window. Each is recorded before any window enters it. Recovery
  sets each to identity and alpha 1, takes every window out of it, since each came in
  through Kosmos (`SpaceMembers.concealed`), then destroys it with the holding Spaces and
  reads it back. The running Kosmos's recoveries, after a failed batch and when the
  guardian keeps dying (`restoreAll`), leave them to it, recorded; the quit, the guardian
  and the startup recovery destroy them.
- A window that closes leaves the ledger and the record once its concealing Space no
  longer lists it. The record's slot holds about 168 windows, 165 with the 8 Spaces
  windows slide in, and filled with closed ones it would stop every conceal. A window
  still listed stays recorded, as one that only stopped being managed or that a failed
  read took for closed, so recovery restores it. A window the ledger does not hold leaves
  once its row is gone or it has a Space: recovery restores one alive on no Space.
- A batch leaves out each window to hide that WindowServer no longer lists, and each
  window new to the record whose process is gone, as a closed tab whose place waits for
  the next tab ([tree.md](tree.md)) or a window of an app that quit before the inventory
  heard. Such a window has nothing to conceal and cannot be recorded. Kept in the batch,
  one new to the record stops the batch before it sends anything, and a recorded one fails
  its confirmation, since no Space lists a closed window. Either way recovery then shows
  every concealed window, as it did when a switch hid two windows of the bench stub that
  had just quit (live log, September 25, 2026). A failed row query reads as every window
  gone, as it does for the inventory, and leaves the windows to hide on screen until
  their workspace is shown and hidden again. If that shows up, the upgrade is for
  `SkyLight.rows` to return nil for a failed query, and for the batch to keep its whole
  hide set then.
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
