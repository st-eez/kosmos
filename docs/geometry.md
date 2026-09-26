# Geometry

- Layout compares each target with the last confirmed frame and the pending target.
  Unchanged windows get no write, and each window keeps only its newest target. A write
  that goes to no worker, or that a worker drops for a window it has no element for,
  makes the ledger forget the window, so its target is not left pending and the next
  write is whole.
- When the size changes, write size, then position, then size again, since an app can
  clamp the size against the old position; otherwise write the position alone. A position
  write queued behind a frame write that has not run becomes a whole frame write, since it
  assumed that size had landed. Read the frame back once per batch.
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
  window still taller refused the height.
- Each window's minimum size comes first from WindowServer. The inventory's reads of
  window rows take the size WindowServer holds each window to
  (`SLSWindowIteratorGetConstraints`), and for a row at level 0 with no parent that holds
  no constraint at all, the one its package keeps (`SLSPackagesGetWindowConstraints`), as
  rift reads them (`constraints()` in src/sys/window_server.rs). `kosmos-probe
  constraints` on 2026-09-25 read a probe window's AppKit `minSize` exactly, and its
  `contentMinSize` as the frame size it makes. Of the 19 regular windows at the desk, 18
  held a constraint in the row, among them Helium's 785 by 588 pt, the width Kosmos had
  learned from its refusals, Activity Monitor's 740 by 384 and Discord's 800 by 500.
  - The minimums added nothing measurable to a read of 2 windows, 0.0132 and 0.0138 ms at
    the median with or without them in two runs, and 0.008 and 0.010 ms to a read of all
    50 windows, a sweep's, at 0.098 ms. A package read takes 0.0074 ms, so only a row
    Kosmos could manage takes one. Only the inventory's reads, off the main thread, take
    the minimums; a switch's batch reads rows without them ([hiding.md](hiding.md)).
  - Kosmos gives a window its minimum as it places it, from the row the inventory read,
    and again whenever a read shows another. A selected tab takes its own. A minimum
    WindowServer changes with no event for the window is seen at its next change.
  - On each axis a window's minimum is the larger of WindowServer's and one learned from
    refusals (below), which stay the fallback for an app that holds its size in its own
    code, where WindowServer reads 0. Where the minimums take effect is in
    [tree.md](tree.md).
- A window whose frame reads back more than 2 pt larger than a write's target on an axis
  refused the size. After its first refusal the target is written again whole 100 ms
  later, and only a second refusal of the target records the size kept as the window's
  minimum on that axis. Kosmos doesn't retry that size until the target changes. A first
  refusal can pass. On 2026-09-24 `move-node-to-workspace` sent a 1900 pt wide Preview
  window from the main panel to a hidden workspace on the left panel, shown 13 ms later.
  Its 945 pt target read back 1900, and an Accessibility write of 945 seconds later
  landed, so one refusal is no limit of the app's; recorded as a minimum, the width kept
  the window over its neighbour until Kosmos restarted. An app can also apply a live
  resize step queued before the button came up after Kosmos's write at the mouse up. The
  mouse up forgets the windows it sends back or drops from the ledger, refusals too, so
  that write's larger read back is a first refusal as well. The retry waits out the
  100 ms, since the window's next change event can come inside a queued live resize step
  or the display or Space change itself. A window the user holds again by then gets its
  tile at that press's mouse up. A refusal read back while the window is concealed or
  its workspace hidden says nothing of the app's limit either, as when it moves there,
  its hidden workspace is laid out again, the displays change, or its reveal has not
  landed yet, so it is a first refusal at most. A window on a hidden workspace gets no
  retry, and showing the workspace forgets its refusal, so the write that shows the
  window, sent before the reveal, is a first attempt, retried until the reveal lands. A
  window a failed batch left concealed on a shown workspace is written every 100 ms while
  it refuses, until a switch reveals it. The upgrade: the retry skips a concealed window,
  and the switch that reveals it after the failed batch writes its tile. A window moved on screen to another display, by
  `move-node-to-workspace --focus-follows-window` or `move-node-to-monitor`, is neither
  concealed nor revealed, so only the 100 ms retry keeps a size it ignores during the
  move from counting. One that ignores the retry too records a minimum, until it is
  seen smaller.
- A window seen smaller than its minimum on an axis, by more than 2 pt, with no write of
  Kosmos's in flight, as when the user or its app resized it, loses the minimum on that
  axis. Its workspace is laid out again then, or at the mouse up during a press.
- WindowServer reports each move and resize as a change event (`WindowServerEvent.changed`
  lists its ids), and the inventory reads the window's frame again. A frame it reads for
  a tiled or floating window of a shown workspace while no write of Kosmos's is in flight
  replaces the confirmed one, and a size other than the one the window kept at a refusal
  ends that refusal, so the next layout writes the target again, as a first attempt. A
  concealed window's change is left out, though its row gives the frame it has, as a shown
  window's does ([hiding.md](hiding.md)).
- A tiled window the user resizes by its edges, as a change event reports it while the
  left button is down, goes back to its tile when the button comes up, which an `NSEvent`
  global monitor hears, as AeroSpace's GlobalObserver does. Omarchy leaves Hyprland's
  `resize_on_border` off, so a tile's edges resize nothing there, and macOS gives Kosmos
  no way to stop such a resize. So does a tiled window moved while another window is
  key, as by a Command drag, or moved less than a lift takes ([displays.md](displays.md)). The ledger
  forgets the window first, so it gets a whole frame write. A lock or a resync forgets the
  presses and the windows they moved, and the resync lays those windows out, so a press
  that spans a resync loses its snap-back: its later changes count as made with the button
  up, and the window keeps what the rest of the press gives it. That is rare, and accepted.
  The resize command and the right button's modifier drag size tiles, past their
  minimums ([tree.md](tree.md)), and a floating window keeps the size the user gives it.
- The inventory applies a change event after reading the window's row off the main thread
  ([inventory.md](inventory.md)), by which time Kosmos's write may be confirmed and the button up. So
  Kosmos judges the change as of its arrival. It is a write's when it came before the
  write's read back confirmed it, even after a mouse up made the ledger forget the window,
  and it is the user's when it came during a press, from the left button's down to its up
  as `NSEvent` global monitors hear them. A mouse down off every display is left out,
  since the focus path's key record ([overview.md, section 3](overview.md#3-primitive-decisions)) is a mouse down far off every display with
  no mouse up, and a lock or a resync forgets the presses. A mouse up can come between a
  change and its apply, and it sends back or drops only the windows the press had moved by
  then, each with a write the change counts as. So a tiled window changed in a press that
  has ended by the time the change applies goes back to its tile, as the mouse up would
  have sent it. Only the last press that ended is kept, so a change from the press before
  it reads as one with the button up; keeping the presses back to the oldest change
  waiting to apply would cover it. Judged as it applied, the late echo of a hotkey's
  write to the window the user holds the button in would lift it. A change that came
  before a write was sent counts as the write's too; recording when each write was sent
  would tell them apart. The write's change still records its row when it differs from
  the frame confirmed: the row applies after the confirm and can hold the app's next step,
  as of a live resize, whose own event then finds no difference. The pointer for the
  resize border check is read as the change applies.
- Every AX call times out after 1 s, set once for the whole process, so elements copied
  out of an app's attributes, which do not take their app element's timeout (as paneru
  found), are covered too. Reads use the same 1 s. Each app's calls run
  on its own worker, so a slow read delays only that app, and a read cut off at 50 ms would
  leave its window unknown.
- A call that waited out at least half the timeout backs its app off. The worker then makes
  no call to the app, keeps only the newest frame target of each window, and asks for the
  app's role with a 50 ms timeout every 0.5 s. When the app answers, the worker tracks the
  windows created meanwhile and writes the held frames. It stops asking and reports that
  the app answers only if none of those calls timed out, and the inventory then reads the
  facts it could not read before. A launching app fails fast and is left to the launch
  retries.
- A worker that starts, or whose app answers again, reports the app's focused window after
  `answering`. A focus change the worker could not read is lost otherwise: one during the
  backoff, as a Command-Tab to the app, and one before the observer was registered, as a
  launching app's first window, whose activation read got no answer while the app
  launched (focus.md). The app can leave the front while the worker reads, so the report
  is a key window report only when the app is front after the read, and a background one
  otherwise, as for an activation read. A worker answers no read of a window's facts
  before it starts, and the inventory admits a window only once it has them, so the report
  comes before the admission of the window it names. Read before the start, between two
  launch retries, the facts let Kosmos admit a launching app's window and conceal it on a
  rule's hidden workspace before the report said the app had keyed it. The ceiling: an app
  that answers reads but refuses the observer's registration, or whose window list read
  fails, has none of its windows managed, where before it was managed without
  notifications. None has been seen; the log after the launch retries names the failing
  step.
- Slides (`Slides.swift`, `KosmosCore/Slide.swift`), on unless the config sets
  `animations = false` ([config.md](config.md)), match Omarchy: a window a relayout moves
  slides to its frame over 0.38 s along easeOutQuint, cubic-bezier(0.23, 1, 0.32, 1), and a
  window opened after launch onto a shown workspace pops in from 87% of its size about its
  center and alpha 0 over 0.41 s, while its app has not ordered it in yet. Switches and
  closes do not animate. The windows that slide are a plan's writes to windows on screen on
  a shown workspace, other than one the user holds or presses on, of an app whose worker is
  not backed off, from and to displays that hold no native fullscreen window or hold the
  key window on their desktop Space. A reveal, a hidden workspace, a drag's own writes, the
  100 ms retry and floating windows brought home jump, and so does a backed off app's
  window, whose write waits for the app while its transform would hold it where it showed.
  So does a window of a shown workspace that a batch still in flight conceals, as after a
  switch away and straight back: its slide's Space would show it above the desktop while
  that batch conceals it ([hiding.md](hiding.md)).
  - The window joins a Space of a pool, shown in place at level 1, one above the desktop
    Space's, and keeps its ordinary Space. Its frame goes through the ledger and its worker
    once, as any write. The Space's transform shows it where it showed, then eases to its
    frame. A display link per display, at that display's rate, steps the windows sliding on
    it, and stops once none is left; at the end the Space goes back to identity and the
    window leaves it.
  - WindowServer applies a Space's transform to each window the Space shows in that
    window's own coordinates, origin at its top left and y down, and maps where a point
    shows to the window's point: a translation of 300 in x shows the window 300 points
    left, and a scale of 2 shows it at half size, its top left corner in place. The hit
    test and the window list's bounds follow; SkyLight's bounds and the Accessibility frame
    do not (kosmos-probe space-anim, branch spaceanim).
  - A transform lands within about 0.4 ms, where an Accessibility write lands with the
    app's next commit, 9 ms later at the median and 15 ms at most, so the two cannot land
    together (kosmos-probe space-anim and its demo, branch spaceanim). A transform sent
    before the write lands, with the write, or with a barrier between, showed the window
    displaced backwards for 5 to 17 ms in 10 of 10 swaps. So the transform follows the
    frame instead: reads of the window's row off the main thread set the transform for
    each new frame WindowServer gives it. In the demo, reads every 0.1 ms left the window
    at its new place for one read of 10 swaps. The reads come every 0.1 ms within 20 ms of
    a window's write, its read back or a new frame, which covers the landings measured, and
    every 1 ms after, a rate no probe measured; a row a read misses tells nothing.
  - A write lands once WindowServer has the frame the worker read back after it, and the
    slide ends at that frame, so a window that rounds its size ends where it is, and one
    that refuses the move lands at once and slides back. A slide that is over holds its
    window at its end until the write lands, for 1 s after the write at most, the
    Accessibility timeout, and the reads follow the write that long.
  - A new relayout mid-slide continues from where the window shows, at the alpha it has.
    A write that does not slide ends the slide at once when it is to another frame, and is
    followed as the slide's own when it is to the same one, as the 100 ms retry after a
    refused size. A change of the window's frame during a press to a frame other than its
    newest write's target and read back, as when the user moves it, a modifier drag taking
    it, and a window concealed, parked, closed, on a workspace no longer shown or on a
    display that gains a native fullscreen window end the slide at once, before a batch
    conceals the window. So does a reload, a display change, a wake or an unlock, which
    also stops every display link: a link stops firing when its display goes, and the next
    slide starts one on a display that has a screen. A display change ends every slide at
    AppKit's notification, as a slide on a display that went would hold its window displaced
    through the 0.5 s wait for the burst to end ([displays.md](displays.md)). A change to the
    write's own frame leaves the slide: the worker reads the frame back about 3 ms after the
    write and WindowServer takes it about 9 ms later, so the other tiles' reflow at a title
    bar drag's lift lands with the button down.
  - An app shows its new window before Kosmos hears of it, so a window Kosmos places after
    launch that is ordered in already slides from where it shows to its place, as a
    relayout's window does, and stays put when that is its place. A pop hid it and faded it
    back. In seven Ghostty Command-N on September 25, 2026, each window was ordered in when
    Kosmos admitted it, 18 to 40 ms after its key report, so it showed opaque where Ghostty
    opened it for 2 to 5 frames at 120 Hz, then nothing until its write landed, then faded
    in (live log). At 60 fps, each of five Activity Monitor reopens showed the window for 1
    frame, then nothing for 1 or 2 frames, then faded it in over about 0.4 s (screen
    recording, September 25, 2026). A window its app closed and kept, then orders in again,
    shows at its old frame, and a hidden tab dragged out of its group shows for the pairing
    window before it takes a place ([tree.md](tree.md)), so they slide from there too. A
    reopen that waits the pairing window slides after the wait, the ceiling
    [tree.md](tree.md) names.
  - Only a window still ordered out when Kosmos places it pops in, as Discord's was,
    admitted 47 ms before its order-in (live log, September 25, 2026). Kosmos reads from
    WindowServer the row of a window it places that would slide or pop, since the
    inventory's row can lag an order-in whose read is under way. The pop's Space turns
    transparent before the window joins it, and the window pops in where its write landed.
    A write that has not landed after 0.25 s, as a launching app's, pops the window in at
    its target, and the reads follow it until it lands. The ceiling: an order-in between
    that read and the Space turning transparent, in the same main actor turn, shows the
    window until then, and whether a window added to a Space while ordered out stays in it
    once ordered in is unmeasured. If it leaves, the window shows where its app ordered it
    in, then jumps to its place when its write lands. Adding each candidate window of a
    regular app to a transparent Space of the pool at its first row, before its
    Accessibility facts, would remove both, once a probe shows that the add outlasts the
    order-in.
  - A window's border follows the frame the slide shows it at, at each display frame,
    from outside the animation Space ([borders.md](borders.md)).
  - A window slides only while Kosmos can conceal, with the guardian ready and every
    bridged operation present, and each Space of the pool is recorded before any window
    enters it ([hiding.md](hiding.md)). Kosmos makes 8 when animations first turn on, and
    a window that finds none free jumps and is logged. Turning animations off ends every
    slide and keeps the Spaces. Quit ends every slide, then recovery destroys the Spaces.
  - A slide's Space goes back to the pool once a barrier and a read of its windows, off
    the main thread, show its window out of it. A Space that still lists the window, as
    after a removal that did not land, or whose read fails, leaves the pool and is logged,
    since its next slide would move the window too. The ceiling: the window stays in the
    Space, above the desktop Space's windows, until the quit, the guardian's or the next
    start's recovery takes it out; if the log shows such a Space, the upgrade is to send
    the removal again and read once more. Another window the Space lists is logged and
    left, so a JankyBorders border window yet to follow its window out, as border windows
    follow the windows they border in and out of the holding Space
    ([hiding.md](hiding.md)), takes no Space from the pool.
  - A Space of the pool shows over whatever Space its display shows, so a slide on a
    display showing a native fullscreen Space would draw over the fullscreen app. So no
    window slides to or from a display that holds a native fullscreen window, as the
    inventory last read its frame, unless it holds the key window while no fullscreen
    Space shows, as the focus gate judges it from the key window ([focus.md](focus.md)):
    the user works on its desktop Space. The ceiling: another display that holds one
    slides nothing while it shows its desktop Space too. A slide under way when the user
    swipes its display to the fullscreen Space draws over the fullscreen app until the
    slide ends, 0.38 s after it began, or later while its write has not landed, and so
    does a relayout there before the report that the fullscreen window is key. Reading
    each display's current Space would tell them apart.
  - Limits, unmeasured: a resize scales the window's old content, so it stretches until
    the slide ends; a sliding window draws above every window of the desktop Space,
    floating windows included, and two sliding windows, whose Spaces share one level,
    stack in an order no probe read; a Space at level 1 was measured on the built-in
    display only; the reads stop once the write lands, so a later change the app makes on
    its own shows displaced until the slide ends; and a slide's bridged operations go from
    the main thread and the slide queue while the bridge queue sends its batches.
    `script/bench-relayout.sh` times the CPU of Kosmos, the app, WindowManager and
    WindowServer with animations on and off, and counts the reads.
  - The bench's latency is to the last frame change the stub saw for a step, the final
    frame Kosmos wrote, and to the log line of each window's final write, which Kosmos logs
    after reading the frame back, in millisecond steps. With animations on, the window
    takes its final frame at once and shows at it when its slide ends, 0.38 s after the
    write, or for a pop 0.41 s after its write lands. Each step's next response is a
    `list-workspaces` query sent as soon as the step's command answers, which Kosmos
    answers on the main actor, where every slide's display frames also run. CPU times come
    from `ps -o time=` in 10 ms steps, fine for a run's total divided by its relayouts.
    WindowServer's include every other app's drawing, so the summary also gives each
    process's time over 10 s of rest with the windows tiled, scaled to the run's length.
    The stub prints a line per frame change, a cost both modes share. A real app's window,
    given by id, reports no frames of its own, so its latency is to its final write in
    Kosmos's log, and its CPU is its app's main process, without the helper processes that
    draw it. The summary records each app's AXEnhancedUserInterface (`kosmos-probe eui`),
    which makes Chrome and Firefox animate Accessibility moves themselves.
  - Open until the live test: `kill -9` of Kosmos mid-slide and mid-pop, after which the
    guardian's recovery should show the window at its own frame and alpha 1, out of the
    pool's Space; a display unplugged or the lid closed mid-slide, after which the next
    slide should run; a relayout on a display showing a native fullscreen Space, which
    should jump, and one on its desktop Space with the key window, which should slide; and
    whether a write that lands during the 1 ms reads shows its window displaced for a
    display frame.
