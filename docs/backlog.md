# Backlog

Open work on Kosmos, most urgent first. Each item says what is known, what settles it and
what Steve has decided. Take an item out when it lands, and add new work here.

## Follow a Teams meeting window accepted from a call notification

- Steve accepts an incoming Teams call from its notification, and the meeting window opens
  where he can't see it (2026-09-28). His config sends Teams to workspace 5
  (`app-id = 'com.microsoft.teams2'`, `workspace = '5'`), which the office ASUS usually
  hides behind 6 or 7. Starting a meeting inside Teams, or joining one from Raycast, works.
  Teams keys the window and Kosmos follows it to 5 ([focus.md](focus.md), the admission
  follow). The log of a Raycast join at 18:04:39 on 2026-09-28 shows that path.
- The cause is unconfirmed. The suspects:
  - Teams makes the window without keying it after an accept in its notification, which
    runs in the XPC service `com.microsoft.teams2.notificationcenter` inside
    `Microsoft Teams.app`.
  - With focus follows mouse on, the pointer crosses another window between Teams' key
    report and the window's admission. A hover focus counts as a newer command, so Kosmos
    conceals the window ([focus.md](focus.md) records this ceiling). This one can be tested
    without a call. Join a meeting from Raycast and move the pointer across another window
    at once.
- To settle it, take a debug log of a real call:
  `log stream --level debug --predicate 'subsystem == "io.github.st-eez.kosmos"'`.
- FaceTime goes wrong the other way (Steve, 2026-09-28). An incoming FaceTime call opens
  FaceTime's window while the call's notification is still showing, before he accepts.
  Take a debug log of an incoming FaceTime call alongside the Teams one.
- Steve's decisions:
  - Kosmos follows Hyprland. A new window a rule sends to a hidden workspace shows that
    workspace and takes focus.
  - Windows that agents, scripts, `open -a` or computer use open never switch a display
    or take focus.
- The design so far ties the follow to Steve's last real click going to the window's app or
  a helper inside its .app bundle. A posted event carries its poster's pid in
  `eventSourceUnixProcessID`, and setting the field to 0 before posting doesn't hide it
  (`kosmos-probe input-source`, branch `rulefollow`, uncommitted). Before building, sample
  Steve's real input once with `.build/debug/kosmos-probe input-source 60` in
  `~/Projects/Personal/kosmos-wt-rulefollow`, while he clicks, types, uses Command-Tab and
  dictates with Wispr Flow. Karabiner-Elements, Logitech Options+, BetterTouchTool or
  Wispr Flow may post his input under their own pid, and a rule of pid 0 alone would then
  ignore him.
- Branch `rulefollow` (be88746, e4426e6) follows every window a rule sends to a hidden
  workspace, whoever opened it. Steve ruled that out, so it stays unmerged as a reference.
- Left out until it's seen, focus follows mouse ignoring posted mouse moves, so computer
  use's pointer can't hover focus a window.

## Benchmark the slide thread on real apps

Slides step on their own thread since 7f32a0b. Its probes lost 0 vsyncs with the main
thread blocked 20 to 60 ms at a time, against 316 on main ([geometry.md](geometry.md)).
Nothing has measured it with real apps yet.
- Run `script/bench-frames.sh 20` from a terminal with Screen Recording, hands off, about
  7 minutes. It passes if its flash rows in frames 0 to 3 of move left and move right are no
  higher than the second benchmark run's, displaced steps stay at 31 of 240 or fewer, and
  latency stays within 1 ms.
- Take a debug log while windows slide next to Spotify resizing between 945 and 1,900 pt
  on the left panel. It passes with no burst of 3 or more lost vsyncs during another app's
  landing write, and the frame line's `rings` field under 1 ms. A `rings` value over 1 ms
  means main actor work holds Core Animation's lock, and geometry.md gives the upgrade.

## Check RustDesk live

Since d514acf Kosmos observes each app's activation policy, so an app that launches as an
accessory and turns regular later gets its windows managed ([inventory.md](inventory.md)).
RustDesk's `--connect` process does that. Open a new RustDesk connection, and its window should
tile without a restart, and the log should show `RustDesk became a regular app; sweeping for
its windows`.

## Show alt-shift-N's target sooner

`move-node-to-workspace --focus-follows-window` into a hidden workspace reveals it only
once the moved windows' writes land. 12 of 99 switches from 2026-09-25 to 2026-09-26
waited 78 ms at the median and 240 ms at most, with nothing changing on screen meanwhile.
The wait is the apps taking Accessibility writes, one after another for each app. The
proposed fix reveals at once and slides each window with a pending write from its old
tile, as a relayout on a shown workspace does. No probe has tested a window revealed from
the holding Space while it sits in an animation Space.

## Decide logged items once their data is in

Each of these logs what settles it, at notice level unless marked.
- The 100 ms refusal retry (controller): `<id> retry landed`, `refused again`,
  `superseded by a newer target`, `dropped`, `wrote nothing`. With a week of no
  `retry landed` line, record the minimum at the first refusal and delete
  `writeTileAgain`, `refusedLarger`, `forgetLargerReadBack` and the two exemptions. If
  retries land only for windows named in the `left mouse up: tiled windows ...` info line
  just before them, keep a retry in the mouse up path alone.
- The focus queue's 30 ms wait on a worker (focus): `focus of <id> waited X ms for the
  worker of pid P` at info level, and `ran out its 30 ms wait`. Size the wait from the
  distribution, or wait only while that app has a job queued. Teams runs out often.
- The display change debounce of 0.5 s (app): `screen parameters changed: N displays, X ms
  after the one before` and `display change applied: ...`. Set the wait from hotplug
  bursts. If changes to the visible area dominate, apply them without resetting the frame
  ledger.
- The SketchyBar retry (bar): `SketchyBar send failed: ...` and `SketchyBar took a snapshot
  after N failed sends, ...`. Remove the retry unless a streak ends `on a retry`.
- The per-window frame report (01d0e31): run `script/bench-relayout.sh 9 20` twice on
  main and twice on main with the reports sent after the drain's last write, as before
  01d0e31. Keep it if the second and third windows of a drain land sooner by more than the
  spread between runs of one build. Otherwise revert it and 31a46c5's separate
  `framesDropped` report.

## Move the remaining App decisions into KosmosCore

KosmosApp has no test target, so a decision there breaks with the suite green. Move each
one into KosmosCore as a pure function with a test, as `KeyRequest`, `DepartureFocus` and
`ClosedAndKept.hold` were, leaving the calls to macOS in the App.
- Borders' per-display pools and fullscreen wait, and the ring's coordinate flip.
- The 40 pt height retry, a timed-out raise counting as made, backoff at half the timeout,
  `landSize` and `movesDisplay` (`AppWorker.swift`).
- `motions` (`Controller.swift`).
- A keyed report before placement becoming a follow (`Controller+Windows.swift`).
- `unmanaged`'s wait, and `orderChanged`'s reopen or wait (`Controller+Windows.swift`).
- `requestFocus`'s gates and `fullscreenDisplays` (`Controller.swift`).
- Flash counting (`Controller.swift`).
- A stale return and the app hidden filter (`Controller+Windows.swift`).
- The pointer focus gates (`Controller+Pointer.swift`).
- The wiring of `PolicyWatch` and `RegularApps` in `Inventory.swift`: the observation, the
  worker added when an app turns regular, and the worker stopped at exit.
The refusal retry needs no test if the logged item above removes it.

## Keep the window's shadow off its border

Kosmos orders each border below its window (`Borders.swift`), as JankyBorders does by
default, so the window's shadow darkens the ring's bottom edge. A border above its window
fixes the shadow, but the border is one window the size of its target plus the ring, so it
would cover the target and computer use would refuse clicks inside it, since computer use
hit tests window bounds. The fix draws each border as four thin windows outside the
target's frame and orders them above it. It costs four border windows, each ordered on its
own, rounded corners still cover the window by the corner radius, and a slide moves four
windows where it now moves one ring layer. Steve deferred it on 2026-09-26, as the shadow
looks fine to him.
- Done when the focused window's ring has the same shade at its bottom edge as at its top,
  computer use clicks inside a bordered window land on it, and slide frame times stay
  within today's.

## Clean up branches

The finished experiments and every branch merged into main were deleted on 2026-09-28.
These are left, each unmerged, for Steve to decide.
- `minimum` (2 commits) overlaps minimums that don't fit only by their excess, and flashes a
  border when a minimum blocks what Kosmos asked for. Check it against main's minimums and
  refusal flash.
- `animation-trial` (13 commits) holds the first slide trial and its bench tooling, such as
  `kosmos-probe eui`. Slides took another design, so only the tooling may be worth keeping.
- `ffm-monitor` takes pointer movement from a global monitor instead of the pointer tap,
  which main kept.
- `floatprobe` probes a Space above the desktop to keep floating windows over tiles.
  Floating windows took another design.
- `tlccloud`, `tlccloud-handover`, `tlccloud-handover2`, `claude/tlc-h01` and
  `claude/tlc-h02` hold the cloud TLC runner (`tla/cloud.sh`) and its results. Keep them
  while TLC runs in the cloud.
- `rulefollow` is the Teams follow reference above.
- `live` is the worktree the install script builds from. Keep it.

## Deferred by Steve

- Signing, notarizing and publishing a release ([distribution.md](distribution.md)).
