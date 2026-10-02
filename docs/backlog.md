# Backlog

Open work on Kosmos, most urgent first. Each item says what is known, what settles it and
what Steve has decided. Take an item out when it lands, and add new work here.

## Decide whether an agent's window on a shown workspace keeps the focus

Steve decided that windows agents, scripts, `open -a` or computer use open never switch a
display or take focus, and that Kosmos follows Hyprland for his own: a new window a rule
sends to a hidden workspace shows that workspace and takes focus. Since branch
`agentfocus` Kosmos follows a report into a hidden workspace only when his own input made
it, and over any other it keeps its workspaces and keys his window again
([focus.md](focus.md)). A window such an app keys on a shown workspace still takes the
keyboard, and the focused display with it when it is on another display, since macOS has
activated its app. Giving that focus back breaks computer use, which needs its app front
for each click ([integrations.md](integrations.md)). The choices:
- Leave it. Agents' apps on shown workspaces take the focus, with no switch and no pointer
  move, and computer use works on any app a display shows.
- Give the focus back always. Computer use then fails on every app, as its front app check
  finds Steve's app after each `open_application`.
- Give the focus back unless a process posted input in the last few seconds. Kosmos sees
  computer use's input under its own process (`claude`, or Codex's `ChatGPT Computer Use`).
  The first `open_application` of a turn comes before any posted input, so it would still
  lose the focus once.
- Give the focus back only when the window is on another display than Steve's focus.
  Computer use then works on the display Steve works on.
- Also open: an agent's launch of an app with no window on an empty workspace keeps the
  keys there, as the empty workspace takes any app launched since it was keyed for the
  user's choice ([focus.md](focus.md)). The same test of the user's input would key the
  empty workspace's window again.

## Check the follow of the user's own input live

Kosmos follows a report into a hidden workspace only when the input tap ties it to Steve's
own key or click ([focus.md](focus.md)). Run
`log stream --predicate 'subsystem == "io.github.st-eez.kosmos"'` and bring up an app whose
windows sit on a hidden workspace each of these ways. Each passes when the log says
`following window(N) of <app>: <input> N ms before` and the display switches:
- Command-Tab (`a key to Dock`), a Dock click (`a click on Dock`), Raycast's panel (`a key
  to Raycast`), Spotlight, a Finder double-click, and a link clicked in another app.
- A Raycast app hotkey, as Opt-Shift-S for Spotify: `a key the input tap never saw`. If the
  log says `came with no key or click of the user's` instead, HID does not count a key a
  hotkey takes, and focus.md's unmeasured case needs another source for hotkeys.
- Chrome launched from Raycast, whose first window comes seconds later: `before its launch`.
- Then run `sleep 5; open -a <app>` in a terminal for an app on a hidden workspace, and keep
  typing in another app. It passes when the log says `came with no key or click of the
  user's`, the display stays, and the keys keep going to the app typed in. An agent's
  Chrome for Testing launch should do the same.

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
  Since branch `agentfocus` the follow also needs the accept's click, which goes to the
  notification service inside Teams' bundle and counts for 10 s. The log's `following`
  line names it; a `came with no key or click of the user's` line means the meeting window
  came later than that.
- FaceTime goes wrong the other way (Steve, 2026-09-28). An incoming FaceTime call opens
  FaceTime's window while the call's notification is still showing, before he accepts.
  Take a debug log of an incoming FaceTime call alongside the Teams one. A window on a
  hidden workspace no longer takes the display with no input of Steve's before it.
- Branch `rulefollow` (be88746, e4426e6) follows every window a rule sends to a hidden
  workspace, whoever opened it. Steve ruled that out, so it stays unmerged as a reference.

## Keep computer use from taking over while Steve works

Steve wants Claude Code's computer use to run beside him without switching workspaces or
displays or moving his focus. Branch `computeruse` stops the two takeovers Kosmos added: its
posted pointer moves focus nothing, and its unhide of the apps it hid at the end of each
turn no longer pulls focus to them ([integrations.md](integrations.md)). Branch
`agentfocus` stops its `open_application` from switching to a hidden workspace, which
leaves computer use unable to drive an app there until the agent runs
`kosmos workspace N`. What is left is computer use's own design, the focus item above, and
Steve's choice among these. Once the branches are installed, check them live: after a
computer use turn that clicks, the log should say `pointer movement posted by pid N
(claude) focuses nothing` with no `pointer focuses` line at the click, and the `unhid`
lines at the turn's end should have no `focus of` line for the unhidden apps' windows
after them.
- Computer use keys its target app and posts real input, so with or without Kosmos it takes
  the keyboard focus and the pointer. Its per-app background tools (`app_screenshot`,
  `app_click` and the rest, which act on one app's window through Accessibility "so the
  user can keep working") are in Claude Code 2.1.284's bundle, but its CLI build answers
  "Per-app background tools are not available in this build". Its hide before each action
  and its animated drag are server flags (`hideBeforeAction`, `mouseAnimation`), with no
  setting. Background tools from Anthropic are the real fix. When they come, check
  `app_bring_to_current_space`, which moves a window between Spaces and could take a
  concealed window out of Kosmos's holding Space.
- Hotkeys that another process posts, as computer use pressing alt-1, still switch
  workspaces, and should. BetterTouchTool posts Option-Tab for Steve's three-finger swipe,
  his `alt-tab` binding ([focus.md](focus.md), the sample of 2026-10-02), so a hotkey gate
  on HID or on the source process would break the swipe. An agent presses Kosmos's keys
  only on purpose.
- Computer use cannot drive the Claude desktop app at all, since its screenshots always
  leave that app out ([integrations.md](integrations.md)). That is Anthropic's to fix.

## Check Kosmos fullscreen live

A focus in a direction on a display with a Kosmos fullscreen window now sees that window and
the floating windows there by their centers, never the tiles under it, and leaves the display
when none lies that way ([tree.md](tree.md)). Tests cover Steve's scenarios of 2026-10-02;
nothing has run them with Kosmos yet.
- With a tile in fullscreen on the main panel and a floating window on its right half,
  alt-right focuses the floating window and alt-right again does nothing. alt-left from the
  floating window focuses the fullscreen tile, which stays under the floating window, and
  the log has a `keyed under a floating window` or `keyed without a raise` line for it.
- With no floating window, alt-left from the fullscreen tile focuses the left panel's window
  at its edge and leaves the tile in fullscreen, and alt-right lands back on it.

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

## Check dialogs float live

A standard window whose zoom button is disabled now floats as a dialog
([inventory.md](inventory.md)). No dialog was open when `kosmos-probe window-kinds` read
Steve's windows on 2026-10-02, so none of his apps' own has been seen.
- Open the Settings and About windows of the apps he uses, ChatGPT's and Ghostty's among
  them. Each should float at its own frame, and the log should show `<id> floats as a
  dialog`. `.build/debug/kosmos-probe window-kinds` lists each open window with its buttons
  and what Kosmos does with it before any rule. One that tiles has its zoom button
  enabled, and a rule floats its app.
- Drag a tab out of Chrome and out of Helium. The new window should tile. If it floats as a
  dialog, Chromium disables the zoom button during the drag, and Chromium's windows need
  their button read again once the drag ends.
- Open System Settings. It should float by rule.

## Watch a title rule apply on a retitle

The Bitwarden pop-out floated by its title rule live on 2026-10-02, in Chrome (53114 at
17:02:30) and in Helium (53127 at 17:02:44), both `floats by rule` at admission: Chrome had
already titled it `Bitwarden` by then. So the retitle path, a rule that matches only after
the app retitles the window within 2 s ([config.md](config.md)), has not run live, and
whether Chrome posts AXTitleChanged for the pop-out is still unmeasured. A pop-out that
stays tiled with no `takes the rule on its title` line is the case to look at; a delay
near 2 s in that line calls for a longer `TitleWatch.bound`.

## Check RustDesk live

Since d514acf Kosmos observes each app's activation policy, so an app that launches as an
accessory and turns regular later gets its windows managed ([inventory.md](inventory.md)).
RustDesk's `--connect` process does that. Open a new RustDesk connection, and its window should
tile without a restart, and the log should show `RustDesk became a regular app; sweeping for
its windows`.

## Check alt-shift-N's slide live

`move-node-to-workspace --focus-follows-window` now shows its target at once and slides its
windows from their old tiles, where it used to wait for their writes to land
([hiding.md](hiding.md)). `kosmos-probe reveal-slide` proved the reveal into an animation
Space with a window of its own; nothing has run it with Kosmos yet.
- Take a debug log while pressing alt-shift-N into a hidden workspace with windows, on each
  display: `log stream --level debug --predicate 'subsystem == "io.github.st-eez.kosmos"'`.
  It passes when the `switch to` lines show no `held` field, a `relayout: N windows slide`
  line comes with each, and the windows show at once and slide with their borders.
- Run `script/bench-frames.sh 20`, then `script/bench-frames.sh --slow 30 20`, from a
  terminal with Screen Recording, hands off, about 7 minutes each. alt-shift-N and
  alt-shift-N back now run as slide steps, which the analyzer has not measured before. It
  passes if their `held ms` is empty, their latency at the median is within 10 ms of
  alt-N's, their tracks start each revealed window at its old tile, and their jumps,
  flashes and displaced frames are no more frequent than move left's and move right's.

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

## Flash a border when a refusal records a minimum

The border flashes red when a window spills past its tile (`Session.spilling`), but not when
an app's refusal records a learned minimum. A learned minimum at the right edge, between
windows or down a column is then never flashed, since the app has already left the window
where it spills ([borders.md](borders.md) records this ceiling). The fix calls `flash([id])`
in the `.minimum` case of `Controller+Windows.swift`, which needs `flash` made internal, and
replaces that ceiling in borders.md with the rule. The deleted `minimum` branch did this
(9e5ee38). Weigh it against the refusal retry above, which may move the recording to the
first refusal.

## Clean up branches

The finished experiments and every branch merged into main were deleted on 2026-09-28.
`ffm-monitor` and `floatprobe` live on as tags `archive/ffm-monitor` and
`archive/floatprobe`, which focus-follows-mouse.md cites. These are kept.
- `tlccloud`, `tlccloud-handover`, `tlccloud-handover2`, `claude/tlc-h01` and
  `claude/tlc-h02` hold the cloud TLC runner (`tla/cloud.sh`) and its results. Keep them
  while TLC runs in the cloud.
- `rulefollow` is the Teams follow reference above.
- `live` is the worktree the install script builds from. Keep it.

## Deferred by Steve

- Signing, notarizing and publishing a release ([distribution.md](distribution.md)).
