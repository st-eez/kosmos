# Geometry

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
  window still taller refused the height.
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
  it refuses, until a switch reveals it. A window moved on screen to another display, by
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
  concealed window's frame reads as off every display and is left out.
- A tiled window the user resizes by its edges, as a change event reports it while the
  left button is down, goes back to its tile when the button comes up, which an `NSEvent`
  global monitor hears, as AeroSpace's GlobalObserver does. Omarchy leaves Hyprland's
  `resize_on_border` off, so a tile's edges resize nothing there, and macOS gives Kosmos
  no way to stop such a resize. So does a tiled window moved while another window is
  key, as by a Command drag, or moved less than a lift takes ([displays.md](displays.md)). The ledger
  forgets the window first, so it gets a whole frame write. The resize command sizes
  tiles, and a floating window keeps the size the user gives it.
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
  it reads as one with the button up. Judged as it applied, the late echo of a hotkey's
  write to the window the user holds the button in would lift it. A change that came
  before a write was sent counts as the write's too. The write's change still records its
  row when it differs from the frame confirmed: the row applies after the confirm and can
  hold the app's next step, as of a live resize, whose own event then finds no
  difference. The pointer for the resize border check is read as the change applies.
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
  left to the launch retries. Its worker reports the front app's focused window when it
  starts too: a key change before the observer was registered posts nothing, and the
  activation read made while the app launched got no answer (focus.md).
