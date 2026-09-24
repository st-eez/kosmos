# TLA+ spec of the workspace switch

[Kosmos.tla](Kosmos.tla) specifies the switch protocol and focus classification from
[DESIGN.md](../docs/DESIGN.md), sections 4.3 and 5.4. It models three queues: the main
actor, the bridge queue that reveals and conceals windows through the holding Space, and
the focus queue. macOS sits between them: it keys the requested window and reports every
key window change to the main actor later. The user issues workspace commands, clicks
visible windows, uses Command-Tab, and closes, minimizes or hides the key window, then
brings it back. The user or an app can also open a specific hidden window. WindowServer
can report a window gone a moment after macOS keyed the next one, and fronting another
window of the key app can miss.

[MC.tla](MC.tla) fixes a small topology: workspace 1 holds w1 and w2, workspace 2 holds
w3, and workspace 3 is empty. App A owns w1 and w3, app B owns w2. Each configuration
bounds the user to two or three inputs.

## Running

```sh
./run.sh mixed > mixed.out                # downloads tla2tools.jar on first run
python3 trace.py < mixed.out              # print the counterexample step by step
```

Java 11 or newer is required.

## Results

| Config | Inputs | Checks | Result | States |
| --- | --- | --- | --- | --- |
| `commands` | commands | convergence, last command wins, no blank frame, recovery path | pass | 11,548 |
| `user` | commands, clicks, Command-Tab, an opened hidden window | convergence, last command wins, last activation wins, recovery path | pass | 220,819 |
| `settles` | commands, clicks, Command-Tab | every disturbance settles (liveness) | pass | 104,031 |
| `no-coalesce` | commands, clicks, Command-Tab, without coalescing | convergence, last command wins, last activation wins | pass | 103,499 |
| `fallback` | commands; macOS re-keys after a hide | convergence, last command wins, settles | pass | 337,718 |
| `fallback-user` | all inputs; macOS re-keys after a hide | last activation wins | fails, expected | 6,465 |
| `mixed` | commands, reveal first | no mixed frame | fails, expected | 72 |
| `conceal-first` | commands, conceal first | no mixed frame, no blank frame | fails, expected | 59 |
| `leave` | all inputs, the key window leaving, with or without a report of the next and before or after macOS keys it, and returning | convergence, last command wins, last activation wins, keeps its workspace after a leave, recovery path | pass | 4,895,193 |
| `leave-settles` | as `leave` | every disturbance settles (liveness) | pass | 4,895,193 |
| `leave-follow` | all inputs and the key window leaving, following re-keys as before | keeps its workspace after a leave | fails, expected | 925,239 |
| `leave-nograce` | as `leave`, deciding each report at once as before | keeps its workspace after a leave | fails, expected | 973,302 |
| `quiet-unbounded` | as `leave`, waiting for a report of the next key window without a bound as before | convergence | fails, expected | 11,149 |
| `return-stale` | as `leave`, following returns received before a command as before | last command wins | fails, expected | 3,235,551 |
| `miss` | commands, clicks, Command-Tab, an opened hidden window, and a focus request that misses | convergence, last command wins, last activation wins, recovery path | pass | 304,965 |
| `miss-follow` | as `miss`, following a hidden window's report as before | last command wins | fails, expected | 71,139 |
| `miss-leave` | as `leave`, with an opened hidden window and a focus request that misses | as `leave` | pass | 7,761,228 |

The first three expected failures record trade-offs, and the others record the behaviour
this model replaced:

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

    The model does not rely on which window Command-Tab lands on. Kosmos keeps ordinary
    Space membership only for each app's most recently used window, concealed or not, so
    Command-Tab lands on that window, which can be hidden (`Controller.concealment`, the
    AeroSpace fork's np4 rule, DESIGN 5.3). CmdTab lets it land on any window of the app,
    that one included, and Open covers a hidden window keyed some other way.
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
