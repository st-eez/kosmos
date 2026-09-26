# TLA+ spec of the workspace switch

The code implements changes 1 to 18 below, and the parts of changes 19 to 25 that
[docs/focus.md](../docs/focus.md) describes; its Deferred list names the rules of those
changes the code leaves out, change 21's drop of change 12's miss rule among them.

[Kosmos.tla](Kosmos.tla) specifies the switch protocol and focus classification from
[docs/overview.md, section 4.3](../docs/overview.md#43-a-workspace-switch) and
[docs/focus.md](../docs/focus.md). It models three queues: the main
actor, the bridge queue that reveals and conceals windows through the holding Space, and
the focus queue. macOS sits between them: it keys the requested window and reports every
key window change to the main actor later. The user issues workspace commands, clicks
visible windows, uses Command-Tab, and closes, minimizes or hides the key window, then
brings it back. The user or an app can also open a specific hidden window. WindowServer
can report a window gone a moment after macOS keyed the next one, and fronting another
window of the key app can miss.

Each display shows one workspace, and each workspace belongs on one display, as the
active profile assigns them ([docs/displays.md](../docs/displays.md)). A window of
any shown workspace is on screen: a report of it is adopted and moves the focus to its
display, and a command for a workspace another display shows only moves the focus.

[MC.tla](MC.tla) fixes a small topology: workspace 1 holds w1 and w2, workspace 2 holds
w3, and workspace 3 is empty. App A owns w1 and w3, app B owns w2. The `displays-`
configs use two displays: workspaces 1 = {w1} and 2 = {w3} on display 1, and workspace
3 = {w2} on display 2, with the same apps, and so does `split-displays`. Each
configuration bounds the user to two or three inputs.

## Running

```sh
./run.sh mixed > mixed.out                # downloads tla2tools.jar on first run
python3 trace.py < mixed.out              # print the counterexample step by step
```

Java 11 or newer is required. `run.sh` runs TLC with 4 workers, or `TLC_WORKERS`, and
deletes its state directory when TLC exits.

## Results

| Config | Inputs | Checks | Result | States | Depth |
| --- | --- | --- | --- | --- | --- |
| `commands` | commands | convergence, last command wins, no blank frame, recovery path | pass | 11,548 | 26 |
| `user` | commands, clicks, Command-Tab, an opened hidden window | convergence, last command wins, last activation wins, recovery path | pass | 220,819 | 29 |
| `settles` | commands, clicks, Command-Tab | every disturbance settles (liveness) | pass | 104,031 | 28 |
| `no-coalesce` | commands, clicks, Command-Tab, without coalescing | convergence, last command wins, last activation wins | pass | 103,499 | 28 |
| `hover` | commands, clicks, Command-Tab, an opened hidden window, and hover | convergence, last command wins, last activation wins, recovery path | pass | 328,029 | 29 |
| `hover-settles` | as `hover` | every disturbance settles (liveness) | pass | 328,029 | 29 |
| `fallback` | commands; macOS re-keys after a hide | convergence, last command wins, settles | pass | 337,718 | 32 |
| `fallback-user` | all inputs; macOS re-keys after a hide | last activation wins | fails, expected | 6,716 | 8 |
| `mixed` | commands, reveal first | no mixed frame | fails, expected | 90 | 6 |
| `conceal-first` | commands, conceal first | no mixed frame, no blank frame | fails, expected | 65 | 6 |
| `leave` | all inputs, the key window leaving, with or without a report of the next and before or after macOS keys it, and returning | convergence, last command wins, last activation wins, keeps its workspace after a leave, recovery path | pass | 4,895,193 | 37 |
| `leave-settles` | as `leave` | every disturbance settles (liveness) | pass | 4,895,193 | 37 |
| `leave-follow` | all inputs and the key window leaving, following re-keys as before | keeps its workspace after a leave | fails, expected | 948,393 | 14 |
| `leave-nograce` | as `leave`, deciding each report at once as before | keeps its workspace after a leave | fails, expected | 996,698 | 14 |
| `quiet-unbounded` | as `leave`, waiting for a report of the next key window without a bound as before | convergence | fails, expected | 13,917 | 7 |
| `return-stale` | as `leave`, following returns received before a command as before | last command wins | fails, expected | 3,282,596 | 21 |
| `miss` | commands, clicks, Command-Tab, an opened hidden window, and a focus request that misses | convergence, last command wins, last activation wins, recovery path | pass | 304,965 | 32 |
| `miss-follow` | as `miss`, following a hidden window's report as before | last command wins | fails, expected | 75,373 | 15 |
| `miss-leave` | as `leave`, with an opened hidden window and a focus request that misses | as `leave` | pass | 7,761,228 | 40 |
| `displays-commands` | two displays; commands | as `commands`, no blank frame on either display | pass | 4,510 | 26 |
| `displays-user` | two displays; as `user` | as `user` | pass | 56,576 | 29 |
| `displays-settles` | two displays; as `settles` | every disturbance settles (liveness) | pass | 27,752 | 26 |
| `displays-leave` | two displays; as `leave` | as `leave`, each display keeping its workspace after a leave | pass | 2,008,597 | 37 |
| `displays-leave-settles` | two displays; as `leave` | every disturbance settles (liveness) | pass | 2,008,597 | 37 |
| `displays-miss-leave` | two displays; as `miss-leave` | as `displays-leave` | pass | 2,680,857 | 40 |
| `displays-focused` | as `displays-user`, adopting only windows of the focused workspace as before | last activation wins | fails, expected | 4,918 | 9 |
| `displays-fallback` | two displays; as `fallback` | convergence, last command wins, settles | fails, expected | 7,505 | 12 |

Every run in this file's tables used TLC with 8 workers on a 12 core Linux machine, on
September 25, 2026. A failing run's state count depends on the order the workers take
states in.

`mixed`, `conceal-first`, `fallback-user` and `displays-fallback` record trade-offs, and
the others record the behaviour this model replaced:

- **`mixed` and `conceal-first`.** Revealing first shows windows of both workspaces for
  one bridged operation. Concealing first shows an empty desktop for the same time. Kosmos
  reveals first.
- **`fallback-user`.** If macOS re-keys a visible window after Kosmos hides the key
  window, the re-key looks the same as a click. After Kosmos follows a Command-Tab to
  another workspace, a re-key onto another window of that workspace wins over the
  Command-Tab: the workspace is right and the window is wrong. While Kosmos holds a
  Command-Tab for its grace (change 11), a re-key onto a window of the shown workspace
  replaces it, and the workspace is wrong too. Re-keys have not been seen on hardware;
  the probes in the virtual machine will settle it.
- **`displays-fallback`.** With two displays a re-key has a window on screen to land on
  whatever the switch does. After `workspace 2` concealed w1, macOS re-keys w2 on the
  other display, Kosmos adopts it as it would a click there, and the focus leaves the
  display the command chose. A click on w2 at that moment is the user's, and the report
  cannot tell the two apart. Only a re-key after a hide causes this, and none has been
  seen: a concealed window stays ordered in and key until Kosmos focuses the next one.
- **`displays-focused`.** Adopting only windows of the focused workspace takes every click
  on the other display for a visible window of another workspace mid-switch, and Kosmos
  focuses its own display again (change 14).
- **`leave-follow`.** When the key window closes or minimizes, or its app hides, macOS
  keys another window, which can be concealed on another workspace. Following that
  report switches workspaces the user never asked for. This happened live: Command-H on
  the only window of workspace 2 took Kosmos to workspace 1.
- **`leave-nograce`.** macOS can key the next window before WindowServer reports the
  window that left as gone, as after a hide. Deciding that report at once follows it to a
  concealed window. This happened live after change 8: Command-H on ChatGPT, the only
  window of workspace 2, took Kosmos to workspace 1, where macOS keyed Ghostty.
- **`miss-follow`.** Kosmos switches to workspace 2 and fronts w3, but app A keeps w1,
  now concealed on workspace 1, and reports it again. Following that report as a
  Command-Tab takes Kosmos back to workspace 1. This happened live with Ghostty.
- **`quiet-unbounded`.** When the only window of an app minimizes, the app can stay
  front with no key window, and macOS reports none. A departure that waits for macOS's
  report of the next key window without a bound then never focuses the workspace's
  other window.
- **`return-stale`.** A window comes back: it is unminimized, its app unhides, or it
  leaves native fullscreen. If the user runs a workspace command before Kosmos handles
  the return, following the return takes Kosmos away from the workspace the command
  chose.

The key window leaves, and a window returns, only after Kosmos has had and decided the
reports before it. Kosmos handles one in milliseconds, far below the time a person needs to
see a window become key and then close, minimize or hide it, or to see it leave and bring
it back. At that moment the user is on Kosmos's workspace, unless a command or a return is
still on its way. The departure or return and the report of the next key window still
reach Kosmos in either order.

WindowServer can report a hidden app's windows gone after macOS keyed the next window.
Kosmos's grace outlasts that delay: the departures probe saw a hidden app's window ordered
out 17 ms after the hide, and the grace is 100 ms. A departure may also leave no report of
the next key window, as when macOS keys an app Kosmos has no worker for; the grace ends
that wait too.

The model leaves out a click, Command-Tab or opened window while Kosmos has not yet
handled a return. Kosmos would follow the return after them and undo the user's choice. A
command there is covered. A report is not, because a return makes macOS key windows too,
and Kosmos cannot yet tell those key changes from the user's. The gap is widest when a
window leaves fullscreen: Kosmos handles that return once the window joins the desktop's
Space, about 0.5 s after it starts to leave.

The `split-` configs run a focus request as the steps the implementation takes
(`SplitQueue`): the focus queue's, the target app worker's, the app's AXRaise landing
later, the raise after a background app's key record (`PostRaise`) and the echo it records
(`PostRaiseEcho`), the app's focus notification, whose observer callback runs some time
after the change (`NoteDelay`), and the activation read, which runs on the app's worker
and reads the app's focused window whenever it runs. The queue's 30 ms wait can run out for the busy app (`BusyApp`, app A
unless named `busyb`). AXRaise alone keys a window inside the front app (`RaiseKeys`), and
a raise in a background app is reported as a focus change (`RaiseReports`), both as
`kosmos-probe keying` measured. A key record can activate a background app with its last
key window, and the app keys the named window a step later (`KeyOldFirst`), as Preview and
Ghostty did live (change 25). Requests do not miss there, so the split configs run
without misses and without the miss rule (change 21). In the `background` configs
background apps also change their own focused window (`AllowBackground`). In the `notice`
configs the main actor also notices an activation some time after it happens
(`NoticeDelay`), with two inputs. `split-open` lets the user open a hidden window, and
`split-displays` runs it on two displays. The split configs also check that the key window
is the front window of its app at rest (`FocusOnTop`).

Each split run was stopped after 10 minutes. A run that finished gives its state count and
the depth of its search. One that was stopped gives the states it had checked without a
violation and the depth it had reached.

| Config | Inputs | Checks | Result | States | Depth |
| --- | --- | --- | --- | --- | --- |
| `split-commands` | commands; app A busy | convergence, last command wins, key window on top, recovery path | pass | 990,973 | 60 |
| `split-user` | commands, clicks, Command-Tab; app A busy | as `split-commands`, last activation wins | stopped, no violation | 43,423,158 | 45 |
| `split-user-busyb` | as `split-user`, app B busy | as `split-user` | stopped, no violation | 45,253,366 | 45 |
| `split-user-background` | as `split-user`, background apps changing their own focused window | as `split-user` | stopped, no violation | 44,248,643 | 45 |
| `split-hover` | as `split-user`, and hover | as `split-user` | stopped, no violation | 44,305,537 | 39 |
| `split-hover-settles` | as `split-hover` | every disturbance settles (liveness) | stopped, no violation in the liveness check at 4,903,909 states | 6,881,836 | 26 |
| `split-open` | as `split-user`, and an opened hidden window | as `split-user` | stopped, no violation | 46,423,057 | 39 |
| `split-displays` | two displays; as `split-open` | as `split-user` | stopped, no violation | 43,678,787 | 42 |
| `split-leave` | as `split-user`, the key window leaving and returning as in `leave` | as `split-user`, keeps its workspace after a leave | stopped, no violation | 47,114,439 | 23 |
| `split-user-notice` | as `split-user` with two inputs, activations noticed late | as `split-user` | pass | 3,439,580 | 55 |
| `split-user-background-notice` | as `split-user-background` with two inputs, activations noticed late | as `split-user` | pass | 3,440,679 | 55 |
| `split-hover-notice` | as `split-hover` with two inputs, activations noticed late | as `split-user` | pass | 4,376,652 | 55 |

Each of these runs one rule the implementation had, or one the spec had, and fails as
expected (changes 17 to 25):

| Config | Rule | Result | States | Depth |
| --- | --- | --- | --- | --- |
| `split-user-actcheck` | an activation read counts only while its app is front (`ActFrontCheck`) | fails last activation wins, expected | 83,823 | 12 |
| `split-user-latenote` | a focus notification is stamped and checked when the worker delivers it (`LateNoteCheck`) | fails last activation wins, expected | 2,368,879 | 23 |
| `split-user-timeout` | the worker gives up on a busy app's AXRaise, which still lands (`RaiseTimeout`) | fails last command wins, expected | 40,185,832 | 42 |
| `split-user-bgraise` | the worker also raises a background app's window before the key record (`BackgroundRaise`) | fails last command wins, expected | 16,594,886 | 33 |
| `split-user-d1be665` | robust's rules at d1be665 (`SplitRules`), which change 18 replaced | fails last activation wins, expected | 1,344,425 | 20 |
| `split-user-background-nohold` | a notification from an app Kosmos activated is taken before that activation's read (`HoldNotes` off) | fails last activation wins, expected | 18,697,182 | 37 |
| `split-user-reasserttakes` | with only activation reads followed, a report Kosmos reasserts over counts as the last one taken for the user's (`ReassertTakes`) | fails last activation wins, expected | 209,889 | 15 |
| `split-user-notice-nocheck` | a late notice does not note that its app lost the front to Kosmos's activation (`NoticeCheck` off) | fails last activation wins, expected | 9,875 | 14 |
| `split-user-lostclick` | the last activation wins, without exempting a click lost to a late callback (`HonorsLastClick`) | fails last click wins, expected | 2,256,738 | 24 |
| `split-user-missrule` | the miss rule (`MissRule`) | fails last activation wins, expected | 1,916,528 | 23 |
| `split-user-nopostraise` | no raise after a background app's key record (`PostRaise` off) | fails key window on top, expected | 278,630 | 16 |
| `split-open-readfollows` | only activation reads follow into another workspace (`NoteFollows` off) | fails last activation wins, expected | 224,729 | 13 |
| `split-open-postraisenone` | the raise after a key record records no echo (`PostRaiseEcho = "none"`) | fails last command wins, expected | 22,690,877 | 38 |
| `split-open-postraisekept` | that raise's record stays until a report matches it (`PostRaiseEcho = "kept"`) | fails last activation wins, expected | 30,429,128 | 40 |
| `split-user-readsbywindow` | with `KeyOldFirst`, an activation read matches a record of the window it reads, and no notification waits for it (`ReadsByWindow`, `HoldNotes` off), as the implementation had | fails convergence, expected | 9,814,646 | 29 |

`RecoveryPath` holds by construction here, because the holding Space is recorded before
the first hide. The recovery protocol needs its own spec.

## Design changes found by the model

Each change below started as a counterexample from TLC.

1. **Stale reports.** A Command-Tab reported after a newer workspace command was adopted,
   and Kosmos switched away from the workspace the user had just asked for. Hotkeys and
   reports are now stamped on receipt, and an activation received before the latest
   command re-asserts that command's focus.
2. **Coalescing.** A resumed switch skipped focus because another command was queued, but
   that command named the current workspace and did nothing, so nothing was ever focused.
   Only a queued command for another workspace now suppresses focus.
3. **One generation for two jobs.** Adopting a click during a switch started a new
   generation, which also cancelled the switch's resume, and the incoming window was
   never focused. The switch and the focus intent now have separate generations.
4. **Echoes matched by app.** A Command-Tab to another window of the app Kosmos was
   focusing matched as Kosmos's own echo and was dropped. Echoes now match the exact
   window. This also removed an earlier rule that re-asserted focus when the intended app
   reported a different window, which would have undone the user's choice.
5. **Echoes matched too early.** A click on w3 reported before Kosmos's own request for
   w3 consumed that request's expectation. The real echo then looked like a user
   activation and pulled focus back. An echo must now be received after its request.
6. **Clearing expectations.** Dropping all expectations on the first foreign report
   turned Kosmos's own late echo into a user action, the AeroSpace bounce-back.
   Expectations now stay until matched.
7. **Following re-keys.** With macOS re-keys enabled, Kosmos followed a re-key back to the
   workspace it was leaving, which hid the key window again and caused another re-key.
   The state space never closed. Only Command-Tab reaches a hidden window, so Kosmos now
   follows a report into another workspace only if the window was hidden when it became
   key.
8. **Following re-keys after a departure.** A window closing, minimizing or hiding
   with its app made macOS key another window, sometimes a concealed one, and Kosmos
   followed it as if it were a Command-Tab (`leave-follow`). A report whose previous key
   window has left the screen is now macOS's own, and Kosmos keeps its workspace. When
   macOS keys no window, Kosmos focuses its workspace again.
9. **Windows gone before Kosmos heard.** Three counterexamples followed.
   - A late report named a window that had already left, and Kosmos adopted it.
   - A departure's refocus picked a next window that had also left, so nothing was
     focused.
   - A switch requested focus for a window whose app had just hidden.

   Kosmos now ignores reports of windows it knows left and never asks to front a window
   that left the screen. A departure focuses again when a request was dropped for that
   reason.
10. **Returns older than a command.** Kosmos followed a returning window after a newer
    workspace command, and took the user away from the workspace they had just chosen
    (`return-stale`). A return received before the latest command is now stale, as a
    Command-Tab is: the window goes back to its workspace, and Kosmos stays where the
    command took it.
11. **Departures WindowServer reports late.** Live, Command-H on the only window of
    workspace 2 still took Kosmos to workspace 1 after change 8. macOS keyed Ghostty
    before WindowServer ordered the hidden app's window out, so the report found the
    window key before it still on screen (`leave-nograce`). Kosmos now also takes the
    departure itself as evidence, from Accessibility and NSWorkspace. It holds a report
    whose verdict depends on a departure it does not know yet, and the grace decides it.
    Four counterexamples shaped the hold.
    - Ending the hold at Kosmos's own echo lost a Command-Tab. Only a newer report of a
      window ends it.
    - Holding a report of no key window lost a Command-Tab held before it. Such a report
      is not held: if the key window left, the departure focuses.
    - A switch requested focus for a window whose app was hiding, the request was
      dropped, and the departure waited for a report of the next key window that had
      already come. A minimized or hidden focus is now replaced at once, unless the key
      window Kosmos last heard of left too. This also covers a request that found its
      window gone, which had its own flag before.
    - Kosmos checked departures only for windows it had not concealed. A window that a
      switch conceals can be minimized or hidden in the same moment, and concealing
      leaves it ordered in, so every window key before a report is checked.
12. **Misses taken for Command-Tab.** Live, Kosmos fronted Ghostty for a window of
    workspace 1, Ghostty reported the window a switch had just concealed on workspace 3,
    and Kosmos followed it there (`miss-follow`). The model now lets a focus request miss
    once, and lets the user or an app open any hidden window. A report that repeats the
    key window while a request of Kosmos's to that app awaits its echo is a miss, on any
    workspace. Kosmos requests its focus again, and every other key change to a hidden
    window is followed, so an opened window is. Counterexamples shaped the rule.
    - Redirecting a report of a concealed window to its app's window on the shown
      workspace hid a window the user had opened. Only a miss of Kosmos's own request is
      not followed now.
    - The missed request stayed among the expected echoes and swallowed the user's later
      activation of that window. It leaves them at the miss.
    - Dropping every request to that app turned Kosmos's later, successful request into
      a user action. Only the oldest, the one that missed, leaves.
    - A miss reported after Kosmos had followed the window was adopted as the user's
      choice. A miss is retried on any workspace.

    The model does not rely on which window Command-Tab lands on. Kosmos keeps every
    concealed window's ordinary Space membership on one display, so Command-Tab lands on
    the app's most recently used window, which can be hidden
    ([docs/hiding.md](../docs/hiding.md)). CmdTab lets it
    land on any window of the app, that one included, and Open covers a hidden window
    keyed some other way, as by Command-backtick.
13. **Departures with no report of the next key window.** A departure of Kosmos's focus
    waited for macOS's report of the next key window, which need not come
    (`quiet-unbounded`). The wait now ends with a bound, and the departure focuses.
    - A minimize keys the next window only when its animation ends, 0.73 s after
      Accessibility reported it in the live log, so the model lets Kosmos hear of a
      departure before macOS's key change (AllowLate). The bound outlasts that key
      change: it is Kosmos's departure bound of a second, where the grace of 100 ms
      would not be.
    - A window keyed during the animation, by Kosmos or the user, is taken to leave macOS
      nothing to key when it ends. That is how AppKit keys the next window when the key
      window orders out, but it is not measured; the departures probe asks.
    - Kosmos's own echo ended the wait for macOS's report and left nothing focused. Only
      a report that is not Kosmos's echo ends it.
    - A click or Command-Tab during the animation reads as macOS's own key change, since
      the window key before it has left, and Kosmos keeps its workspace. The model leaves
      such input out.
14. **Several displays.** Each display shows a workspace, so a window of another
    workspace can be on screen with no switch in flight. Adopting only windows of the
    focused workspace, the rule for one display, took every click on the other display
    back (`displays-focused`). A report of a window of any shown workspace is now adopted,
    and the focus moves to that display. After the key window leaves, macOS can key a
    window on the other display; Kosmos adopts it, and each display keeps its workspace,
    which `KeepsWorkspaceAfterLeave` now checks per display. Holding those reports for the
    grace would delay every click on another display by 100 ms. The single display
    configs find the same state counts as before.

The split model, merged with the one above from the `hover` branch, found the rest.

15. **Skipping on reports.** The main actor skipped a request for the window macOS last
    reported key. Reports lag: after `workspace 2` then `workspace 1`, the second switch's
    request for w1 was skipped because the report of w3 had not arrived, and w3 stayed
    key. Requesting while an echo was due instead recorded an expectation for a request
    that changed nothing; no report cleared it, and a later click away and back to that
    window was taken for an echo. Recording no expectation for such a request let it land
    after a click and be adopted as the user's. The main actor now requests every focus,
    and the focus queue skips a request whose window is really key when it runs.
16. **Recording at the call.** With expectations recorded when the main actor requested and
    forgotten when the queue skipped, the user's click back to a window matched the
    expectation of a re-request the queue had not run yet, and was taken for an echo. The
    queue now records each expectation just before its call, so a request it skips leaves
    nothing to match.

The split configs found more, each in the implementation's order of steps before the
change that removed it:

17. **Background reports.** A busy app's late raise of w3, after the user had switched
    away, changed only that background app's own focused window, and the app reported it.
    w3 was concealed by then, so Kosmos took the report for a Command-Tab and followed it
    back to the workspace the user had left. A report from an app that is not the front
    process when it arrives now consumes an echo it matches and is otherwise ignored, and
    it does not count as the last report, or the user's real Command-Tab to that window
    was later dropped as a repeat.
18. **Recording for the other side.** Records were taken by whichever of the queue and the
    worker decided first, before the other's call. A worker that found the target key
    already dropped the queue's record, and the queue's activation then went unrecorded
    and was adopted after the user's click; that was still so at d1be665
    (`split-user-d1be665`). A request that turned stale after its record kept it, and it
    swallowed the user's own click or Command-Tab to that window. A raise that recorded
    after the queue's activation changed nothing and left its record behind. Now each
    side records only just before its own call that changes the key window, and skips its
    call once the other has made one. The queue posts no key record for a front app,
    where it changes nothing unless the window is frontmost in its app. There the worker
    keys: when AXRaise alone keys the window, it records just before the raise; when it
    does not, it raises, then records and posts the key record while the request is still
    current. A worker that raised, read, and posted the key record only if the window was
    not key served both cases but failed: the user's Command-Tab between the raise and the
    read made the read say not key, and the key record took focus back. Which case holds
    is for `kosmos-probe keying` to settle.
19. **Late reports and late raises.** The split model then took each report as the
    implementation takes it: an activation read runs on the app's worker, behind its
    raises, and reads whatever window the app has by then, and a busy app's AXRaise can
    land after the worker stopped waiting. That found, in turn:
    - A notification and an activation read both report one activation. With the
      notification consuming the record, the read, arriving after an unrelated echo, was
      adopted and followed into a hidden workspace. An activation read now matches
      Kosmos's activation record for that app whatever window it reads, and a
      notification only joins such a record.
    - Echoes from one app came after the echo of a later request from another, which
      dropped the earlier records with it; only the matched record goes now. The repeat
      filter dropped a Command-Tab to the window of the last report processed, which was
      another app's older report; it is gone.
    - The user clicked A, then B, and A's report came last; a report stamped before the
      last one taken as the user's is now ignored.
    - An activation read marked background once its app lost the front dropped the user's
      Command-Tab when Kosmos's older request fronted another app first. Such a read is
      now ignored only when no Kosmos activation was recorded after it.
    - A notification checked when the worker delivered it, behind the worker's calls, was
      judged against a newer front app and dropped a click. Notifications are checked
      when sent.
    - A raise the worker gave up on landed after a newer command, keying a concealed
      window that Kosmos followed. The worker waits for the raise.
    - A raise in a background app landed after the app came front and keyed a stale
      window. Nothing raises a background app's window.
    - Whether a window was hidden, judged as the report was classified, turned a
      Command-Tab into a click on a window being concealed after a later switch revealed
      it. It is judged at the report's stamp.

    One case is left: when Kosmos keys an app again before that app's activation read
    runs, the read finds Kosmos's window, and no report says which window the user
    activated. The spec exempts it with a ghost (`lastAmb`) and
    [docs/focus.md](../docs/focus.md) records it.
20. **Callbacks after the change.** An app's observer callback runs some time after the
    change it reports, and stamps it and checks the front app and the window's hiddenness
    then (`NoteDelay`). The main actor likewise notices an activation some time after it
    happens (`NoticeDelay`). Both run before the user's next input, and an app's
    callbacks run before its activation read, but Kosmos's own steps can run in between.
    That found:
    - A background app changed its focused window, Kosmos's older request brought the
      app front, and the change's callback then found the app front. Kosmos adopted the
      stale window over the user's later Command-Tab (`split-user-background-nohold`). A
      notification from an app Kosmos activated now waits for that activation's read,
      and stands only if the read finds its window.
    - The notification of a Command-Tab to a hidden window ends in Kosmos requesting its
      intent again. Counted as the last report taken for the user's, it dropped the
      activation read, stamped earlier, that would have followed the Command-Tab
      (`split-user-reasserttakes`). Only a report Kosmos adopts or follows counts now.
    - A click on a window being concealed had its callback run after the conceal, so the
      window looked hidden, and Kosmos followed it back to the old workspace over the
      user's next click. Only an activation read followed after this change; change 22
      follows notifications again and exempts this race.
    - With notices late, Kosmos's older request recorded and made its activation after
      the user's Command-Tab and before the main actor noticed the Command-Tab. The read,
      stamped after Kosmos's record, looked overtaken by the user and was dropped
      (`split-user-notice-nocheck`). The notice now records that its app had already
      lost the front to an activation Kosmos recorded, and such a read stands.

    Two more cases are left, exempted with ghosts and recorded in
    [docs/focus.md](../docs/focus.md). A click
    inside the front app is lost when a request Kosmos made before it activates another
    app before the click's callback runs (`lastLost`; `split-user-lostclick` checks
    without the exemption). A switch that reveals or conceals a window between the user's
    activation of it and the main actor's notice makes the notice misjudge whether it
    was hidden (`lastMis`, kept until Kosmos settles, since the wrong follow decides what
    later inputs lead to).

    The state view also treats the generation of the request the focus queue is running
    as current or stale now, as it does for queued requests. Before, a stale and a current
    running request could share a view, so TLC could skip behaviors; every `split-` config
    was run again with it.

21. **The split model beside returning's rules.** Reports of different apps reach Kosmos out
    of order, and three rules misread them:
    - The miss rule takes a report that repeats the key window Kosmos last heard of, while
      a request to another window of that app awaits its echo, for a miss. The
      activation read of a Command-Tab repeats the window its own notification just
      reported, so Kosmos took it for a miss of its older request to that app, asked for
      its intent again, and lost the Command-Tab (`split-user-missrule`). Inside the front
      app the worker's AXRaise keys the window, 20 times in 20, and the key record
      activates a background app with the named window, 10 times in 10 (`kosmos-probe
      keying`), so the split path does not miss. The split configs run without misses and
      without the rule.
    - For the same reason, a report that repeats the held window was taken for the held
      report after a miss. A newer Command-Tab to the window of a held, older one was
      dropped with it when the older one turned out stale. Without misses that goes too.
    - An older report of another app arriving late ended a held report as a newer
      activation, and replaced it. A report stamped before the held report is now
      overtaken by it, as by the last report taken for the user's.

    The key record leaves a background app's window where it sits in that app's stacking
    order, 0 times in 10 on top (`kosmos-probe keying`), so `FocusOnTop` fails without the
    raise after it (`split-user-nopostraise`). The app's worker raises the window after
    the key record while the app is front and the window is still its focused window;
    the key record then AXRaise put it on top 10 times in 10. Change 23 gives that raise
    its echo.
22. **Windows opened inside the front app.** With main's inputs in the split model, the user
    can open a concealed window of the front app, as its Window menu or `open` on a document
    does. Only the app's notification reports that change. With only activation reads
    followed, Kosmos requested its intent again and took the window away from the user
    (`split-open-readfollows`). A notification of a window hidden at its stamp now follows
    as an activation read does. That brings back change 20's click on a window being
    concealed whose callback runs after the conceal, which Kosmos follows back. It joins the
    exempted race of a switch that changes whether a window is hidden between the user's
    change and its notice (`lastMis`), now also between the change and its callback. The
    opened window found two more races, and their exemptions widened:
    - Kosmos's older request activated another app before the callback of the user's change
      inside the front app ran, and then brought that app front again. The callback found
      the app front, and the held notification rule dropped it as a change the app made
      before Kosmos's activation. The exemption for a click lost to a late callback
      (`lastLost`) now covers a callback that runs after its app lost the front at all.
    - The user opened the window Kosmos's older raise was keying, before the app performed
      the raise. The user's change matched the raise's record, and Kosmos, whose intent had
      moved on, requested it again. The exemption for the raise after a key record
      (`lastRaced`) now covers the user keying any window of an app with a raise Kosmos
      decided and the app has not performed.
23. **The echo of the raise after a key record.** The worker raises only while the app is
    front and the target is its focused window, so the raise finds the target key and
    changes nothing, unless the user keyed another window of the app between the check and
    the raise. With no record, the raise's report then reads as the user's. When a newer
    command had concealed the window by then, Kosmos followed it back to the workspace the
    user left (`split-open-postraisenone`). A record kept until a report matches it stays
    behind after every raise that changes nothing, and swallowed the user's later opening
    of that window (`split-open-postraisekept`). The worker now records just before the
    raise, and once the raise has returned and it has read the app's focused window, tells
    the main actor, which forgets the record if no report used it. The app's callbacks for
    the raise have run by then, as they have before its activation read.
    The worker does not check that the request is still current. With that check, a hover
    on the same window made the raise stale, the new request found the window key and
    raised nothing, and it stayed behind its app's other windows (`FocusOnTop` failed
    `split-hover` at depth 21 in a run made for this question).
24. **Departures and a second display in the split model.** `split-leave` and
    `split-displays` found five more:
    - The fold of the split model lost the check that the user leaves or brings back a
      window only after Kosmos has every report: a quantifier took it into its scope. It is
      back.
    - After the key window closed or minimized with no window keyed next, the model counted
      Kosmos as the front app, so the worker dropped its raise inside the app, which had
      stayed front, and nothing was focused. The app whose window closed or minimized now
      stays front while no window is key (`bare`).
    - The key window left and macOS keyed a concealed window of another app. That app's
      notification found the window before it gone, and Kosmos kept its workspace. The
      activation read of the same change came next, took the notification's window for the
      one before it, and Kosmos followed macOS's re-key, as in `leave-follow`. A report that
      repeats the window Kosmos last heard of now has the window before that one.
    - Kosmos's evidence that the key window left lasts a second, and the split model judges
      it by the key window Kosmos last heard of. With no report of a next key window, a
      Command-Tab within that second reads as macOS's own key change, as a click during a
      minimize's animation does above. The spec lets the second pass once Kosmos has every
      report (`Age`), and exempts input inside it (`lastEarly`).
    - On two displays the user clicked the window Kosmos's older raise was about to key, on
      the display the focus had just left. The worker had read the app's focused window
      before the click and recorded after it, and the click's callback ran after the record,
      so the click read as the raise's echo. The exemption of change 22 (`lastRaced`) now
      starts at the worker's read.
25. **Activations that key the app's last key window first.** Live, a key record activated
    Preview with its main window before Preview keyed the window the pointer entered, and
    Ghostty with its last key window, concealed on another workspace, before the requested
    one. The activation read ran between the two and found the first. Kosmos matched a
    read by the window it named, so it adopted Preview's main window, and held Ghostty's
    and followed it there when the grace ended (`split-user-readsbywindow`, which also
    turns off `HoldNotes`, as Kosmos has none). The model now lets a key record activate a
    background app with the window key when the app was last front, while that is still
    the app's focused window, and key the named one a step later (`KeyOldFirst`). Change
    19's rule takes the read for the key record's echo. That found five more:
    - The read consumed the record, and the named window's notification then read as the
      user's. After `workspace 2` and then `workspace 1`, the key record for w3 landed
      between the two commands, and Kosmos followed w3 back to workspace 2
      (`split-commands`, depth 32). A read of another window now leaves the record for the
      named window's notification, unless a notification held for the read says the user
      changed the window.
    - A busy app's raise landed after Kosmos had keyed its empty workspace's window, so
      the app's focused window was the raised one, and the key record of `workspace 2`
      activated the app with its last key window, concealed on workspace 1. The app
      notified that first key, and once the read found its window the notification held
      for the read was taken for the user's change: Kosmos followed it to workspace 1
      (`split-commands`, depth 54). An app fronted with no window brought forward keys its
      last key window, and after a raise in the background the public path keyed another
      window than the raised one in 9 of 9 trials ([docs/focus.md](../docs/focus.md)), but
      no probe has shown which window a key record keys first when the two differ. The
      model keys the last key window first only while it is the app's focused window, and
      docs/focus.md names the ceiling.
    - A key record's read that ran after Kosmos key-recorded the same app again found the
      later record's first key, and took the notification held for the later record for
      the user's change (`split-commands`, depth 54, over three commands). An app handles
      key records in order, so the model's focus queue posts a key record to an app only
      once the app has keyed the window the one before named.
    - The activation read of a Command-Tab ran while an older key record to that app had
      not yet keyed its named window, and found the user's window, which the named window
      then replaced (`split-hover`, depth 32). That is change 19's race of Kosmos keying an
      app again before its read runs, and its ghost (`lastAmb`) covers it now.
    - The raise after the key record found the app's own focused window and skipped, and
      the named window stayed behind its app's others (`FocusOnTop` failed `split-commands`
      at depth 18). That is the ceiling [docs/focus.md](../docs/focus.md) names for that
      raise, and the spec exempts it with a ghost (`lowTop`) until a window of that app
      comes to its front.
