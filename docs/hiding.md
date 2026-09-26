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
  window's Space list names fullscreen Spaces. The displays are read for it, up to 7 ms on
  the development Mac, also only in a batch that adds. A window whose add did not land stays in
  the holding Space, so the batch fails its confirmation and recovery adds it again.
- A batch is confirmed when the Spaces it touched show each revealed window out of them
  and each concealed window in them. Kosmos reads them directly, on its own connection,
  every 0.1 ms for up to 10 ms, and only then sends the barrier and reads once more. A
  direct read never shows an operation at once (0 in 60 tries on the development Mac),
  but it shows it as soon as WindowServer applied it: 0.47 ms at the median for a window
  that is not key, against 0.50 ms for the barrier, which also waits behind
  WindowManager.app. WindowServer applies a batch's operations in order, so a window
  seen out of the holding Space implies the add sent before its removal.
- A batch reveals a window only once the window's frame write has landed, and every later
  batch waits behind it (`BatchOrder`). A write lands once the worker's read back names its
  frame and a row of the window from WindowServer shows that frame: the inventory reads the
  row at each change event, and the controller checks the row it last read when the read
  back comes, since WindowServer can take the frame first. The reveal used to go out at a
  median of 0.5 ms (1,432 switches) while a write landed at 48 ms (p98 171 ms, 834 slide
  landings), in the live logs of September 24 and 25, 2026, so each window a switch
  revealed with a new frame showed at its old tile for about 5 frames, then jumped: every
  window of the hidden workspace `move-node-to-workspace --focus-follows-window` enters,
  and a followed rule window. The switch now shows late and whole, and its log line gives
  the wait as `held`. The wait leaves out a window shown already and one whose app is
  backed off. A write no row has shown counts as landed 1 s after it was sent, the
  Accessibility timeout, and the controller checks the batch again when the first write
  holding it reaches that second. A concealed window's move posts the change event as a
  shown window's does: in `kosmos-probe concealed-move`, off every display and on the main
  one, each of a window's two concealed moves posted two change events 10 to 13 ms after
  it, and the row showed the new frame without the holding Space's offset (September 25,
  2026).
- A window on screen that the revealed workspace takes in on the display it shows on, as
  the one `move-node-to-workspace --focus-follows-window` moves or a followed rule window,
  is concealed at the command by a batch of its own, whose switch line shows nothing, and
  revealed with the workspace once its write lands. Written at once, it had landed at its
  tile over the old workspace 1 or 2 frames before the rest. Into an empty workspace
  nothing is revealed around it, so the switch goes at once and the window slides there.
  One whose workspace is on another display is left out and lands there as before, 1 or
  2 frames before the rest: concealed without being stripped, it would keep the ordinary
  Space of the display it leaves, and whether its reveal then shows it on the other
  display is open (below).
- A window a batch conceals is written only once the batch is done, so its write lands
  concealed. A batch the bridge queue sent late (p98 15.7 ms, 162 ms at most, in the same
  switches) had let the reflow of the workspace it hid show before the conceal. A write
  waits while any batch not yet done conceals its window, and a later write joins it, so
  the app takes them in order. A batch that reveals a window whose write waits for an
  earlier batch waits for that write to land. One whose write waits for a later batch
  goes, and the write lands after that batch conceals the window.
- A batch leaves out of its wait each window a later batch conceals again. So a switch
  on to a third workspace during the wait, as alt-3 right after alt-shift-2 from 1, sends
  both batches at once, and the windows of 2 show at their old tiles for the length of one
  batch. A switch back to 1 waits for 1's reflow to land.
- A plain switch's windows were laid out while hidden, so none has a write on its way and
  its batch goes in its command's main actor turn, with no read and no timer. The added
  work is a few lookups per window it shows, and its log line keeps its fields. The
  ceiling: a switch that conceals none of the windows a batch waits for, as one on another
  display, waits behind it. Letting a batch with no window in common go first would remove
  that wait. The spec's bridge queue can run a switch's operations any time after its
  command, which covers the wait, and the order of reveals and conceals is unchanged
  ([tla/README.md](../tla/README.md)).
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
- There is no fallback to corner parking. At the first unconfirmed bridged operation on a
  window still ordered in (below): restore every hidden window, stop hiding, report the
  cause, and retry at the next switch.
  On a macOS that lacks one of the bridged operation classes, as after an update that
  renames one, Kosmos logs one fault at startup and names the class in its status menu from
  launch. It conceals nothing, and a batch that confirms its reveals counts as confirmed.
- The record is a file of two 4 KiB slots, mapped shared. A publish fills the older slot
  with a CRC32 of its payload and stores its generation last, so a crash in a publish
  leaves the other slot for the reader. Nothing is synced to disk, since the record only
  has to outlive Kosmos, and the page cache keeps it when the process dies.
- Recovery restores the windows Kosmos concealed: each recorded window in a recorded
  Space, any other window there whose app owns a recorded window, such as a sheet, and a
  child of a concealed window, as the Open or Save panel of a sandboxed app, which the
  panel service owns. A window the Space lists and a read of its row misses counts too,
  since either that read failed or the window closed and the Space still lists it, and
  recovery takes it out with the rest. Removing a window that is gone does nothing, and
  left in, it would keep the record for good. Recovery adds each one without an ordinary
  Space to the current Space of the display under it, or to the Space a reveal would
  choose, then removes them from each recorded Space, destroys the Spaces and clears the
  record. It removes an added window from a recorded Space only once the add landed, and
  keeps the record while a concealed window is left there. A window with no row leaves
  regardless, because a closed window's Spaces read as none, so recovery adds it, and that
  add never lands. A window whose Spaces do not read stays where it is and keeps the record
  too, since a removal could leave it on no Space and an add could take it off its own.
  Every step can safely run twice.
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
  guardian keeps dying (`restoreAll`), leave them to it, recorded; the quit, the guardian,
  the startup recovery and the adoption at a restart destroy them.
- Kosmos keeps the hidden workspaces' windows concealed across a restart. Before this, quit
  recovery, and the guardian's after a crash, showed every concealed window before the next
  Kosmos started, and each window of a hidden workspace showed at its tile over the shown
  workspace until the next Kosmos admitted it from the saved layout and concealed it again
  ([tree.md](tree.md), [inventory.md](inventory.md)). At the install of September 26, 2026,
  the old Kosmos's quit recovery ended at 00:46:16.900, the new one started at
  00:46:17.670, and its first conceals at admission completed at 00:46:17.909 and
  00:46:17.947: about a second, 0.77 s of it between the two processes (live log).
  - A planned restart hands the record over. `kosmos handover [record version]` arms a quit
    within 5 s, and `script/install.sh` sends it right before its SIGTERM, with the version
    that the build starting next reads: `KosmosRecordVersion` in its Info.plist, which
    `script/bundle.sh` copies from `RecoveryRecord.version`. That build is the staged copy,
    or the previous copy at `--rollback`. An armed quit writes the layout, ends the slides
    and lets the queued batches land, then exits with every concealed window still in its
    holding Space. A plain quit, an uninstall and a `launchctl kickstart -k` restore the
    windows. Kosmos has no relaunch of its own;
    `kosmos handover && launchctl kickstart -k gui/$(id -u)/io.github.st-eez.kosmos` restarts
    it by hand with the windows kept.
  - Kosmos refuses the arm when the next build reads another record version, and the
    refusal clears an earlier arm, so the install quits it with recovery. A Kosmos that
    predates the command answers that it does not know it, and a build with no
    `KosmosRecordVersion` gets no arm. A build that cannot decode the record finds nothing
    recorded, so handing one over would leave its windows concealed with no record to
    restore them (`handover-ungated`, [tla/README.md](../tla/README.md)). The arm lapses
    after 5 s, time enough for `script/install.sh`'s SIGTERM, so an arm whose quit never
    came, as after a `launchctl kickstart` that failed or an install that stopped, cannot
    hand a later quit to another build (`handover-noexpiry`). The armed quit hands over only
    while the guardian is ready, as no other process would restore the windows should no
    Kosmos follow (`handover-unready`). The ceiling: a build swapped in without
    `script/install.sh` and then a crash leave the record to a build that may not read it.
  - A Kosmos names itself in the lock file, by its pid and start time, once it takes the
    record over: after its guardian reports ready, or after its startup recovery. Once its
    Kosmos exits and leaves a record, the guardian gives the next Kosmos a grace of 5 s. It
    reads the lock file every 50 ms, and once the file names a live Kosmos other than the
    one that exited, it leaves the record to that Kosmos. Any other holder of the lock, as
    `kosmos-probe survive-kill` or a Kosmos not named yet, takes nothing over
    (`handover-anyholder`), and after the grace the guardian retries its recovery every 2 s
    for about 30 s while such a holder has the lock. A Kosmos that dies before it names
    itself leaves the record to the guardians still waiting, and one that dies after has a
    ready guardian of its own. The ceiling: a guardian killed during its grace after a quit
    that handed over, with no Kosmos following, leaves the windows concealed until the next
    Kosmos starts.
  - launchd spawned Kosmos 25 ms after the `kill -9` of 02:08:37.751 on September 26, 2026,
    and 20 launches on September 25 and 26 were past the lock 85 to 269 ms after their
    spawn (live logs). The wait for the guardian's ready report comes on top, 1 s at most.
    `script/install.sh` spawned the new Kosmos 0.5 to 2.0 s after the old one quit in 18
    installs, a time that includes its wait for the guardian, which it skips after a
    handover. The install's time from the quit to the new Kosmos naming itself is to be
    measured at the first install that hands over. The old guardian logs
    "Kosmos <pid> exited" at the quit, then "Kosmos <pid> took the record over; leaving it",
    or "no Kosmos took the record over within 5 s; recovering" when the grace ran out;
    `log show --last 10m --predicate 'subsystem == "io.github.st-eez.kosmos" AND category == "guardian"'`
    lists both with their times. Should that time come near 5 s, the grace has to grow.
    launchd starts a Kosmos again at once only after a run of 30 s or more
    (`ThrottleInterval`), so after a crash at launch, with Launch at Login off, or after a
    handover whose next Kosmos never starts, the windows show 5 s after the exit.
  - A Kosmos that starts with Accessibility granted and manages windows takes the record
    over in place of startup recovery, once the saved layout is restored and before the
    inventory admits any window (`Controller.adopt`). It first waits up to 1 s for its
    guardian's ready report, which the main thread would read only after the launch, and
    runs startup recovery when none comes. Recovery runs with the windows it spares
    (`Recovery.run`, `sparing`). The settled members of the holding Spaces are read with
    `SkyLight.readRows`, and each recorded member that is ordered in stays concealed, with
    the windows that stand on it, as its sheets (`Adoption`). The quit wrote the layout
    after the batches landed, so nearly all of them belong to hidden workspaces, and
    admission reveals the others. The rest come back as recovery brings them: windows
    ordered out, which park at admission, and windows with no row. A failed row query keeps
    nothing, since it cannot tell a closed window. The Spaces windows slide in are emptied
    and destroyed, and so is each holding Space left with no kept window. The record keeps
    the kept windows and their Spaces, and the ledger comes back from those Spaces'
    members, as after an incomplete recovery. Without Accessibility, or while another
    window manager runs, startup recovery runs.
  - A kept window's admission to its hidden workspace finds it in the ledger, so its batch
    only confirms it. A concealed window whose admission plan does not hide it is revealed
    with that plan: one of a shown workspace, one whose workspace a switch showed before
    its admission, or one that parks (`handover-noreveal`). A kept window that no admission
    places within 5 s of the adoption, as one whose app never answers, is revealed where it
    is (`handover-nobackstop`); every window of the launch of 02:08:38 was admitted within
    68 ms of its start. A window whose app answers after the 5 s shows over the shown
    workspace until its admission conceals it again.
  - A conceal after the adoption goes into the kept holding Space, by the rule above.
    `kosmos-probe handover` on September 26, 2026 (macOS 27) made a holding Space in a
    child process, which then exited, and in a second round was killed with SIGKILL. In
    both rounds the Space stayed listed with its transform at 100000, 100000 and alpha 0,
    the concealed window stayed in it, and another process added a window to it, took both
    out and destroyed it. If an add fails, the first batch that conceals into the kept
    Space fails its confirmation, and recovery destroys the Space.
  - Border windows are Kosmos's own, so they close with it, and a concealed window has
    none, so the next Kosmos draws them as it manages its windows
    ([borders.md](borders.md)).
  - [tla/Handover.tla](../tla/Handover.tla) models the restart
    ([tla/README.md](../tla/README.md)).
- A window that closes leaves the ledger and the record once its concealing Space no
  longer lists it. The record's slot holds about 168 windows, 165 with the 8 Spaces
  windows slide in, and filled with closed ones it would stop every conceal. A window
  still listed stays recorded, as one that only stopped being managed or that a failed
  read took for closed, so recovery restores it. A window the ledger does not hold leaves
  once its row is gone or it has a Space: recovery restores one alive on no Space. A failed
  row query counts as neither (`SkyLight.readRows`).
- A batch leaves out each window to hide that WindowServer no longer lists, and each
  window new to the record whose process is gone, as a closed tab whose place waits for
  the next tab ([tree.md](tree.md)) or a window of an app that quit before the inventory
  heard. Such a window has nothing to conceal and cannot be recorded. Kept in the batch,
  one new to the record stops the batch before it sends anything, and a recorded one fails
  its confirmation, since no Space lists a closed window. Either way recovery then shows
  every concealed window, as it did when a switch hid two windows of the bench stub that
  had just quit (live log, September 25, 2026). The batch reads the rows through
  `SkyLight.readRows`, which returns nil for a failed query, where `SkyLight.rows`, as
  the inventory reads rows, returns none. A failed query leaves no window out, so a
  window new to the record, whose owner the query would have named, stops the batch and
  recovery runs. Read as every window gone, it would leave the windows to hide on screen
  until their workspace was shown and hidden again.
- A window can also close, or its app order it out, after the batch reads its row and
  before its add lands, as at Command-W right before a switch. No Space lists it, so its
  conceal never shows and the batch fails its confirmation, and recovery would show every
  other concealed window until the next switch while leaving that one where it is. So when
  the read after the barrier still fails a batch, Kosmos reads the rows of the windows it
  failed. When none of them is ordered in, each closed or was ordered out since the batch
  read it, and the batch is confirmed without them: a window it concealed stays out of the
  ledger, one it revealed stays in, and the log names them. A failed window still ordered
  in fails the batch, and recovery runs. KosmosCore's tests cover the rule
  (`ConcealLedger.Batch.confirmed`). A failed row query counts every failed window as
  ordered in, so recovery runs: this read takes its rows from `SkyLight.readRows`, which
  returns nil for a failed query, where `SkyLight.rows` returns no rows. Read as every
  window gone, a failed query would leave a live window whose conceal failed on screen,
  and one whose reveal failed concealed, with no recovery.
- Open until the desk: `move-node-to-workspace --focus-follows-window` to a hidden
  workspace on another display, as alt-shift-N there. Whether a window concealed with the
  ordinary Space of one display, then written onto another, shows there once revealed
  ([displays.md](displays.md) lists the question) decides whether the batch that conceals
  a window a switch takes in can cover such a move too.
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
