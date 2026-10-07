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
- With animations on, a switch that reveals windows with new frames shows their workspace
  at once and slides them from their old tiles to their new ones, as Omarchy's Hyprland
  does at Super+Shift+N:
  every window of the hidden workspace `move-node-to-workspace --focus-follows-window`
  enters, and a followed rule window. In Hyprland (main, 2026-09-27),
  `Actions::moveToWorkspace` in src/config/shared/actions/ConfigActions.cpp moves the
  window, the layout gives the workspace's windows animated targets,
  `CWindow::moveToWorkspace` calls `setAnimationsToMove()`, and the monitor's
  `changeWorkspace` shows the workspace with no animation, as Omarchy turns the
  `workspaces` animation off. Each revealed window whose tile changes joins an animation
  Space at the command, in the command's main actor turn, before its batch goes to the
  bridge queue, and slides as a relayout's window does ([geometry.md](geometry.md)). The
  batch goes at once and does not wait for the sliding windows' writes, since each
  Space's transform shows its window where its slide has it until the write lands. Before
  this, the switch waited for those writes: 12 of 99 such switches from September 25 to
  26, 2026 waited 78 ms at the median and 240 ms at most, with nothing changing on screen
  meanwhile (live log).
  - `kosmos-probe reveal-slide` on 2026-09-28 (macOS 27 26A428, the built-in display at
    120 Hz) concealed a red window of a child app at A in a holding Space of its own, wrote
    it 240 points right to B through Accessibility, and revealed it into an animation Space
    of its own whose transform showed it at A, then slid it to B. A capture of each frame,
    10 trials a mode:
    - Added to the animation Space, then removed from the holding Space, the window showed
      on its slide in 10 of 10, its first frame 14.5 ms after the add at the median. In
      both Spaces for 50 ms it stayed concealed: no frame changed in 10 of 10, and the
      window list put it at the holding Space's offset.
    - Removed first, then added at once, it showed on its slide in 10 of 10, and in 3 of 4
      of a shorter run that day, where the fourth showed a frame at B. With 50 ms between
      the two it showed at B in 10 of 10. So the add goes first, as it does:
      `Slides.writing` sends it before the batch goes to the bridge queue.
    - As Kosmos reveals, the add on one thread, the write to B sent, then the removal from
      another thread, 1 of 10 showed one frame at B, the reveal's first, as the write
      landed before a read set the transform, the landing ceiling
      [geometry.md](geometry.md) records for every slide.
    - Concealed with its ordinary Space stripped, then revealed as a batch reveals such a
      window, the exclusive add to the current ordinary Space left it in the animation
      Space in 10 of 10, and it showed on its slide in 10 of 10.
    - Kosmos's batch confirmation (`ConcealLedger.Batch.isDone` on the holding Space's
      members, read directly) confirmed every reveal of the 70, at 1.3 to 2.9 ms after the
      removal at the median of each mode and 11.2 ms at most, none by the barrier. A
      window's Space list (`SkyLight.spaces`) never names the animation Space, so the
      batch's `isOnAnySpace` and the check that an add landed read as without it.
    - The window stayed in front of the probe's backdrop, a floating window of the probe's,
      after each reveal and after leaving the animation Space, in every trial. The probe
      orders it front before each trial; its first runs did not, and in three of four of
      them the window, removed from the holding Space with no animation Space, showed under
      the backdrop, with its stacking before the trial unread.
- A batch that reveals a window that does not slide waits for that window's frame write to
  land, and every later batch waits behind it (`BatchOrder`), as with `animations = false`,
  on a display that holds a native fullscreen window, for a window an earlier write still
  moves, and for one that finds no animation Space free. With animations off the switch
  keeps its wait. Revealed at once, a window would show at its old tile until its write
  lands, then jump. Hyprland with its `windows` animation off draws the workspace already
  laid out, and the wait shows it the same way, late. A sliding window whose batch waits
  for another slides concealed and shows where its slide has it when the batch goes. A
  write lands once the worker's read back names its frame and a row of the window from
  WindowServer shows that frame: the inventory reads the row at each change event, and the
  controller checks the row it last read when the read back comes, since WindowServer can
  take the frame first.
  The reveal used to go out at a median of 0.5 ms (1,432 switches) while a write landed at
  48 ms (p98 171 ms, 834 slide landings), in the live logs of September 24 and 25, 2026,
  so each window a switch revealed with a new frame showed at its old tile for about 5
  frames, then jumped. A switch that waits shows late and whole, and its log line gives the
  wait as `held`. The wait leaves out a window shown already and one whose app is backed
  off, which shows at its old tile and jumps once its app answers. A write no row has shown
  counts as landed 1 s after it was sent, the Accessibility timeout, and the controller
  checks the batch again when the first write holding it reaches that second
  (`BatchOrder.recheck`). Of 1,835 slide landings from September 24 to 26, 2026, the median
  was 32.8 ms, p90 80.8 ms, p99 250.7 ms and the longest 673.7 ms, and 7 never landed
  (live log). A concealed window's move posts the change event as a shown window's does:
  in `kosmos-probe concealed-move`, off every display and on the main one, each of a
  window's two concealed moves posted two change events 10 to 13 ms after it, and the row
  showed the new frame without the holding Space's offset (September 25, 2026).
- A window on screen that the revealed workspace takes in on the display it shows on, as
  the one `move-node-to-workspace --focus-follows-window` moves or a followed rule window,
  slides from where it shows to its tile, over the old workspace as the batch conceals
  that. One that does not slide is concealed at the command by a batch of its own, whose
  switch line shows nothing, and revealed with the workspace once its write lands
  (`BatchOrder.add`, `Session.entering`). Written at once, it had landed at its tile over
  the old workspace 1 or 2 frames before the rest. Into an empty workspace nothing is
  revealed around it, so the switch goes at once and the window slides there. One whose
  workspace is on another display is never concealed: it slides there, or lands there
  before the rest when it does not slide. Concealed without being stripped, it would keep
  the ordinary Space of the display it leaves, and whether its reveal then shows it on the
  other display is open (below).
- A window a batch conceals is written only once the batch is done, so its write lands
  concealed. A batch the bridge queue sent late (p98 15.7 ms, 162 ms at most, in the same
  switches) had let the reflow of the workspace it hid show before the conceal. A write
  waits while any batch not yet done conceals its window, and a later write joins it, so
  the app takes them in order. A batch that reveals a window whose write waits for an
  earlier batch waits for that write to land. One whose write waits for a later batch
  goes, and the write lands after that batch conceals the window.
- A batch leaves out of its wait each window a later batch conceals again. So a switch
  on to a third workspace during the wait, as alt-3 right after alt-shift-2 from 1 with
  animations off, sends
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
  A failed read of the windows' rows, for which `SkyLight.rows` returns nil, leaves the
  recovery incomplete with the record kept. Read as no window alive before the plan, it
  would take every window out of its Space whether or not its add landed, and read after
  the removals, it cannot tell a closed window from one left on no Space. Every step can
  safely run twice.
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
    after 5 s, time enough for `script/install.sh`'s SIGTERM, which came 2, 6 and 7 ms
    after the arm at the three handovers of September 26, 2026 (live log). So an arm whose
    quit never came, as after a `launchctl kickstart` that failed or an install that
    stopped, cannot hand a later quit to another build (`handover-noexpiry`). The armed
    quit hands over only while the guardian is ready, as no other process would restore
    the windows should no Kosmos follow (`handover-unready`). `Handover` holds the version
    gate, a refusal clearing the arm, the 5 s life and the guardian gate. The ceiling: a
    build swapped in without `script/install.sh` and then a crash leave the record to a
    build that may not read it.
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
    handover. At the three installs of September 26, 2026 that handed over, the old
    guardian saw the new Kosmos named 371, 903 and 901 ms after the old one exited (live
    log). The old guardian logs "Kosmos <pid> exited" at the quit, then
    "Kosmos <pid> took the record over; leaving it", or "no Kosmos took the record over
    within 5 s; recovering" when the grace ran out;
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
    `SkyLight.rows`, and each recorded member that is ordered in stays concealed, with
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
    its admission, or one that parks (`handover-noreveal`). `Session.add` plans that reveal
    from its `concealed` input, for a window taken over and for one its app closed and
    kept while concealed that opens again, and KosmosCore's tests cover it. A window placed
    a second time, which `add` leaves as it is, stays as it is. The Controller's check that
    this replaced had revealed it, even on a hidden workspace. A kept window that no admission
    places within 5 s of the adoption, as one whose app never answers, is revealed where it
    is (`handover-nobackstop`), with the windows that stand on it. `Adoption.reveal` chooses
    them and the display under each. Every window of the launch of 02:08:38 was admitted
    within 68 ms of its start. A window whose app answers after the 5 s shows over the shown
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
  row query, for which `SkyLight.rows` returns nil, counts as neither, and the conceal
  that needed the room does not go.
- Open: whether recovery can restore a window its app closed and kept, as at Command-W in
  Activity Monitor. Ordered out, it is alive, in no recorded Space and on no Space, so
  recovery adds it to an ordinary Space (`RecoveryPlan.make`). Should that add never land,
  every recovery would report itself incomplete and keep the record and its holding
  Spaces. `kosmos-probe ordered-out-add` reads whether the add lands, exclusive and not,
  and whether it orders the window in or shows it.
- A batch leaves out each window to hide that WindowServer no longer lists, and each
  window new to the record whose process is gone, as a closed tab whose place waits for
  the next tab ([tree.md](tree.md)) or a window of an app that quit before the inventory
  heard. Such a window has nothing to conceal and cannot be recorded. Kept in the batch,
  one new to the record stops the batch before it sends anything, and a recorded one fails
  its confirmation, since no Space lists a closed window. Either way recovery then shows
  every concealed window, as it did when a switch hid two windows of the bench stub that
  had just quit (live log, September 25, 2026). `SkyLight.rows` returns nil for a failed
  query, and a failed query leaves no window out, so a
  window new to the record, whose owner the query would have named, stops the batch and
  recovery runs. Read as every window gone, it would leave the windows to hide on screen
  until their workspace was shown and hidden again. `ConcealLedger.concealing` makes this
  choice.
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
  ordered in, so recovery runs, as `SkyLight.rows` returns nil for a failed query. Read as
  every window gone, a failed query would leave a live window whose conceal failed on screen,
  and one whose reveal failed concealed, with no recovery.
- Open until the desk: `move-node-to-workspace --focus-follows-window` to a hidden
  workspace on another display, as alt-shift-N there. Whether a window concealed with the
  ordinary Space of one display, then written onto another, shows there once revealed
  ([displays.md](displays.md) lists the question) decides whether the batch that conceals
  a window a switch takes in can cover such a move too. It matters only for a window that
  does not slide, as with animations off; one that slides crosses to the other display in
  its animation Space, unconcealed.
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
- A screenshot of a concealed window fails, so an agent that drives a hidden workspace's
  app in the background, as with CuaDriver, cannot see it. A peek would show the window on
  its display without the user seeing it, long enough for a screenshot, then conceal it
  again. `kosmos-probe peek` on 2026-10-02 (macOS 27 26A428, the built-in display at 2x)
  measured peeks of a child app's panel that stops drawing while its occlusion state is not
  visible, as Chromium does, 5 trials a variant. Each peek added the panel to a Space of
  the probe's, then removed it from the probe's holding Space, and the reverse after; each
  batch landed within 13 ms. A peek works only under a cover, below.
  - Concealed for 3 s, the panel's occlusion state stayed hidden and it drew nothing.
    ScreenCaptureKit's capture of the window alone failed ("Failed to start stream due to
    audio/video capture failure"), `screencapture -l` printed "could not create image from
    window", and CuaDriver's `get_window_state` answered "No content produced".
  - In an animation Space at level 1, the panel's app saw its occlusion state turn visible
    1 to 13 ms after the add and drew at once, and saw it turn hidden 2 to 7 ms after the
    peek ended. It got no other notification: no key, screen or Space change.
  - Captures take the Space's alpha. At alpha 0 every capture of the panel was transparent,
    from ScreenCaptureKit, `screencapture -l` and CuaDriver alike, and the screen around it
    did not change by one level. At alpha 0.01 the first capture held the current count,
    86 to 110 ms after the add, but at opacity 3 of 255, which no agent can read, and the
    screen changed by up to 3 levels of 255 over the panel.
  - The Space's shape, set to one point at the panel's top left, read back and clipped
    nothing: at alpha 0.01 the screen and the captures were as without it.
  - In a Space at level -1, under the desktop Space at level 0, at alpha 1 and with the
    panel stripped of its ordinary Space, the desktop picture covered it and the screen did
    not change. Its occlusion state stayed hidden, so every capture was opaque and stale,
    showing the panel's last draw.
  - In an animation Space at alpha 1 scaled to show the panel at 1/400 of its size, the
    occlusion state turned visible and it drew, but captures follow the scale: one pixel at
    opacity 144, and that pixel showed on screen.
  - Under a cover, the peek worked. The cover is a window of the probe's own in a Space at
    level 2, not opaque, so WindowServer does not count the panel under it as hidden, and it
    shows a capture of the screen taken just before the peek. With the panel in an animation
    Space at alpha 1 under it, the occlusion state turned visible 2 to 6 ms after the add,
    and the first ScreenCaptureKit capture, begun 1 ms after the add, was opaque and current
    in 5 of 5, done 81 to 99 ms after the add. `screencapture -l` and CuaDriver were current
    too. The screen changed by at most 1 level of 255, the cover capture's round trip through
    sRGB. The cover took 78 to 135 ms to come up, 30 ms of it a wait for its contents.
  - WindowServer's hit test (`NSWindow.windowNumber(at:)`) at the panel's center named the
    panel only under the cover, in 5 of 5, since the cover ignores the mouse; at alpha 0 and
    0.01 it named the window of Steve's under the panel. Real clicks are untested, since a
    posted click would reach Steve's windows.
  - The cover's costs: about 0.1 s before each peek, the area under it frozen until the peek
    ends, so a change there shows late, and a click there reaching the peeked app unless
    the cover takes the mouse. A real app can take longer to draw after the occlusion change
    than the probe's panel: Discord showed black for about a second when its workspace came
    back on September 25, 2026.
  - Since branch `peekreal` the probe peeks real apps' windows too, with two more variants.
    `plain` removes the window from the holding Space with nothing over it, so the user sees
    it at its frame. `corner` first moves the concealed window so that one column of points
    stays on its display, past its right or left edge with its top 40 points down, else past
    a bottom corner, then removes it from the holding Space with no cover. A frame past an
    edge where another display lies would show the window there, so it takes an edge with
    none. Each trial reads the front app, its key window, Kosmos's focus and display, and the
    pointer before and after it.
  - `chrome`, `finder`, `textedit` and `electron[=<app>]` peek a window the probe opens
    without activating its app: a Chrome for Testing page that draws the panel's cells from
    the wall clock, a Finder window on a folder whose file the probe renames, a TextEdit
    document whose text it sets through Accessibility and reads back with Vision, and an
    Electron app, Obsidian by default, whose capture counts as current when it is not black
    and differs from the last one. Kosmos manages every such window and no rule leaves one
    out ([inventory.md](inventory.md)), so the probe lets Kosmos conceal it: `kosmos
    move-node-to-workspace --window-id` sends it to an empty workspace no display shows, and
    each peek takes it out of Kosmos's holding Space and puts it back. Kosmos leaves out a
    concealed window's change events ([geometry.md](geometry.md)), so the edge move goes
    unanswered, and a batch confirms only the windows it names.
  - Runs on 2026-10-05 (macOS 27, main display 1920 by 1080, 5 trials a variant, CuaDriver
    0.32.0), every trial with the front app, key window and Kosmos's focus unchanged:
    - `corner` was current in 5 of 5 for the probe's panel (74 ms from the peek at the
      median), TextEdit (81 ms) and Chrome for Testing (118 ms), whose page stops drawing
      while occluded. The captures were whole and opaque, the part off the display
      included: Vision read TextEdit's current text from ScreenCaptureKit, `screencapture
      -l` and CuaDriver's `get_window_state` (458 ms) alike. On screen, only the column
      changed, 272 pixels by up to 55 levels of 255, and a click on it hits the window.
    - A bottom corner failed for real apps: TextEdit and Chrome for Testing kept their top
      edge on the display (Chrome's frame stopped at y 1039 of 1079), so the probe now
      tries an edge first.
    - `plain` was current in 5 of 5 for the panel (88 ms), TextEdit (96 ms) and Chrome for
      Testing (95 ms), with the window in full view.
    - `covered` worked for the panel (82 ms after a 77 ms cover). For a 1900 point window
      the cover is most of a display, and the probe's check stopped it when 15,091 pixels
      outside the window changed during the cover, Steve's terminal drawing on.
    - Obsidian's captures in `plain` and `corner` were whole and opaque, but its release
      notes page did not change, so no capture could show it current.
    - Opening the apps, before any peek: Chrome for Testing's launch raised a keychain
      prompt for "Chromium Safe Storage" until the probe passed `--use-mock-keychain`, and
      Obsidian came to the front. Finder opened its window more than 20 s late, after the
      probe gave up, on the focused workspace.
    - The Mac locked during the Obsidian run. The displays dropped out and came back from
      13:45:36, Kosmos's next switch failed its batch, and recovery showed every concealed
      window until the following switch, the resync risk above. A peek of Kosmos's must
      give way to a display change or lock.
- The agent workspace's windows ([displays.md](displays.md)) are concealed in a Space of
  their own under the desktop, as `kosmos-probe dwell` held windows (below), not in the
  holding Space, so agents can capture and click them while no display shows them
  (`HidingStore.createBelow`). Kosmos makes it at the first such conceal, one level under
  the main display's ordinary Space as its level reads, at alpha 1, and records it in the
  record's Spaces and in a list of its own after the animation Spaces
  (`RecoveryRecord.belowSpaces`). Every window there is stripped of its ordinary Space, as
  one on any other Space shows above the desktop, so its reveal pays the add. A window
  that moves between the agent workspace and another hidden workspace changes Space in
  one batch: it joins the new Space before it leaves the old one, so it never shows
  (`ConcealLedger.Batch.moves`). A window in an older holding Space stays there. `kosmos
  peek` answers at once for a window there, as for a shown one. With no Space made, as on
  a macOS whose level read fails, the windows go to the holding Space, and the log says so.
  - Recovery restores them as it restores a holding Space's windows. A Kosmos that predates
    the list reads it as a holding Space, so Kosmos puts it first in the record's Spaces,
    where such a reader, which reuses the last, never reuses it. A recovery that keeps it
    and destroys every holding Space, as an adoption with no window of the user's concealed,
    makes a new holding Space after it at once, so it is never the last.
  - Untested live: whether Command-Tab, a Dock click, Mission Control or a lock reveals a
    window there, whether a click Cua posts as a mouse event reaches it, and whether a
    window revealed with the frame of another display than the one showing the workspace
    flashes there before the floating check moves it.
- `kosmos peek <window id> -- <command>` runs the `corner` peek past an edge around a
  command, as an agent's CuaDriver screenshot ([ipc.md](ipc.md) has the protocol). For a
  window Kosmos does not conceal, as one on a shown workspace, one it does not manage or an
  unknown id, it answers at once and the command runs as it is. A concealed window's peek,
  in `Peeks` (KosmosCore) and `Controller+Peek.swift`:
  - waits behind any other peek, and while a frame write of Kosmos's to the window is still
    landing, as the write back of a peek of it just before: until a row shows that write, a
    row at the edge could be one from before it (`Peeks.prepare`);
  - is refused, and the command runs without it, while a display change waits for its apply,
    0.5 s after the change at most: an edge chosen from the displays the session still has
    could lie on a display that arrived, which would show the window whole there. Waiting
    for the apply would hold the command up to half a second for a peek a lock or sleep may
    end anyway, and the CLI says why, so an agent can try again;
  - writes a frame past its display's right edge, else its left, with one column of points
    on the display, its top 40 points down and no part on another display (`PeekEdge`),
    while the window is still concealed, and waits for a row to show it there, 1 s at most.
    A read back anywhere else ends the peek, as AppKit kept the window on its display;
  - takes the window out of its holding Space on the bridge queue, after adding a window
    with no ordinary Space to one of its display's, as a reveal does
    (`HidingStore.peek`). The ledger keeps it as concealed, so batches, recovery and the
    controller treat it as before: its change events are left out as a concealed window's
    ([geometry.md](geometry.md)), and the frame ledger has both writes as Kosmos's own;
  - waits 160 ms for its app to draw, then lets the command run. Kosmos cannot see another
    app draw, and the probe's captures were current 74 to 118 ms after the peek at the
    median and 156 ms at most. An app slower to draw, as Discord black for about a second,
    gives a stale or black capture; Kosmos capturing the window until a capture is drawn
    and stops changing would remove that;
  - when the command ends, puts the window back into its holding Space, stripped again if
    the peek gave it an ordinary Space, in a batch of its own sent ahead of the batches
    waiting (`BatchOrder.addSent`), then writes its frame back, which waits for that batch.
    A target Kosmos wrote for the window meanwhile, as at a relayout of its workspace, would
    show it there, so it waits for the end and replaces the frame written back
    (`PeekFrames`). With no guardian ready that batch conceals nothing, so the window
    shows at its frame over the shown workspace until the next switch conceals and reveals
    every window again, as after a switch with no guardian ready.
- A peek ends at once in the way its step can be undone. Before the window leaves the
  holding Space only its frame goes back; after, it goes back into the holding Space, then
  its frame. It ends when:
  - a plan shows its workspace. The end's batch goes ahead of the switch's, the frame
    written back waits for it, and the switch waits for that write to land, as for any
    window it reveals with a write on its way, so the window shows at its tile;
  - the displays are applied again, which lays the workspaces out again: at a config reload,
    a profile command, the unlock or a wake, and a display change's apply. The resync after
    a failed batch conceals it again too. The log line and the CLI name which;
  - it closes, which leaves it as it is, since it left every Space;
  - it leaves the screen as a deselected tab, which leaves every Space too. The tab selected
    in its place takes its frame, the edge's, and the plan that replaces it conceals it, so
    that tab gets the frame written back once that plan's batch is done. Written to nothing,
    a floating tab group would show at the edge when its workspace shows, as a switch writes
    only tiles;
  - the session locks, the displays sleep, the screen parameters change or Kosmos quits.
    At a lock the batch still goes, as after the lock during the probe's run of 2026-10-05
    the next switch failed (above);
  - the CLI closes its connection, or the command runs past 10 s, about 20 times
    CuaDriver's `get_window_state` (458 ms). A slower command's captures after that fail,
    and the CLI says the peek ended early.
- A write back is owed until `sendWrites`, the one place a frame write reaches its app, hands
  it over unlocked (`PeekFrames.handed`). Until then it can wait behind the end's batch, a
  later batch that conceals the window again, the end of the peek before it, or, for a
  deselected tab's, the batch that conceals the tab selected in its place; a lock drops it
  wherever it waits. Each apply of the displays, at the unlock, a reload or a profile, writes
  what is still owed, and that write joins one still waiting. Dropped, a write back would
  leave the window at its edge frame: a switch writes only tiles, so a floating window would
  show there, and the next peek of it would take the edge for its rest frame.
- A peek keys, raises and focuses nothing, and moves neither the pointer nor a workspace.
  One line at notice level logs each: the window, its app, the edge, how it ended, the
  command's exit status and how long each step took, as
  `log show --last 10m --predicate 'subsystem == "io.github.st-eez.kosmos" AND eventMessage BEGINSWITH "peek of"'`
  lists.
- Ceilings: a quit or crash during a peek leaves the window at its edge frame, where
  recovery shows it with one column on screen until the next Kosmos lays it out; the quit
  writing the frame back and waiting for its read back would remove that. A click on the
  column during a peek hits the window, as the probe's hit test found; what Kosmos does with
  the key report that follows is untested.
- Live on 2026-10-05 (0189caf, CuaDriver 0.32.0), with the front app, key window and
  Kosmos's focus unchanged throughout:
  - A TextEdit window on hidden workspace 8 answered "No content produced" to Cua's
    `get_window_state`; inside `kosmos peek` the same call's PNG showed the text typed into
    it a moment before. The log: 790.6 ms in all, the edge move 270.3 ms (a write through
    TextEdit's Accessibility), the settle 166.7 ms, Cua's call 352.2 ms, concealed again in
    2.8 ms. The edge move is the part to speed up.
  - Cua's screenshot of a shown Ghostty window took 271 to 409 ms unwrapped and 298 to 307
    ms inside `kosmos peek` over three runs each, and no `peek of` line was logged.
  - A pixel click on a hidden Calculator, grounded on a peeked screenshot, was refused after
    the peek (`capture_target_mismatch`), and inside the peek Cua posted it but Calculator's
    display stayed 0: the point lay past the display's edge. Clicks by `element_token` land
    on hidden windows: earlier that day 7 + 5 read back 12.
- `below` for real apps, 2026-10-05 (Chrome for Testing launched with
  `--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding` and
  `--disable-background-timer-throttling`): the window in a Space shown one level under the
  desktop Space, stripped of its ordinary Space, at alpha 1. The window list put the desktop
  picture directly over it in every trial, and a hit test at its center found the user's
  window. TextEdit was current in 3 of 3 (98 ms at the median) and Chrome for Testing in 3 of
  3 (85 ms), from ScreenCaptureKit, `screencapture -l` and CuaDriver alike; Chrome's counter
  advanced between captures, so it drew throughout. The probe's panel, which stops drawing
  while occluded, had read stale there on 2026-10-02: the capture works under the desktop
  picture, and whether it is current is the app's. The pixel check cannot judge `below` on
  a display the user's windows draw on, so the probe takes the window list's order instead.
  Without its switches Chrome stops drawing when fully covered (an opaque window over a
  shown workspace's windows on 2026-10-05): two captures a second apart were the same.
- `kosmos-probe dwell` on 2026-10-05 (CuaDriver 0.32.0) held a TextEdit window and a
  Calculator window, both concealed by Kosmos on hidden workspace 3, in one Space at level
  -1 under the main display's desktop Space, stripped of their ordinary Spaces, at alpha 1,
  for 5 minutes. Every 10 s the window list kept a desktop picture directly over each, the
  hit test at each center found the user's window, and ScreenCaptureKit captures were
  current in 22 of 22 for each (90 to 146 ms); CuaDriver's screenshot was current each
  minute. Calculator floated at its frame on the left display, so the Space reached under
  that display's desktop too. Pixel clicks from CuaDriver, each grounded on a fresh
  screenshot's `capture_id`, typed AC 4 + 2 = at the start, after 2.5 minutes and at the
  end, and Calculator's display read 6 each time. CuaDriver turned each into an
  Accessibility press of the button under the point (`route: accessibility`), so a click
  on a surface with no Accessibility element, which CuaDriver posts as a mouse event, is
  untested there. The probe logged no app activation, Space change, sleep or lock during
  the run, so Command-Tab, the Dock, Mission Control and a lock with a window there are
  untested, and so is whether its observers see those events.
