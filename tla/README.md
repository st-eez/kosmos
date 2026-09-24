# TLA+ spec of the workspace switch

[Kosmos.tla](Kosmos.tla) specifies the switch protocol and focus classification from
[DESIGN.md](../docs/DESIGN.md), sections 4.3 and 5.4. It models three queues: the main
actor, the bridge queue that reveals and conceals windows through the holding Space, and
the focus queue. macOS sits between them: it keys the requested window and reports every
key window change to the main actor later, so the main actor knows the key window only
from reports that lag. It requests every focus; the focus queue checks the real key
window when it runs a request, skips one whose window is already key, and records the
echo it expects just before each call. The user issues workspace commands, clicks
visible windows, uses Command-Tab, and rests the pointer in visible windows for focus
follows mouse, which Kosmos handles as a command for that window.

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
| `commands` | commands | convergence, last command wins, no blank frame, recovery path | pass | 11,550 |
| `user` | commands, clicks, Command-Tab | convergence, last command wins, last activation wins, recovery path | pass | 104,484 |
| `settles` | commands, clicks, Command-Tab | every disturbance settles (liveness) | pass | 104,484 |
| `no-coalesce` | as `user`, without coalescing | convergence, last command wins, last activation wins | pass | 103,938 |
| `hover` | commands, clicks, Command-Tab, hover | convergence, last command wins, last activation wins, recovery path | pass | 166,699 |
| `hover-settles` | commands, clicks, Command-Tab, hover | every disturbance settles (liveness) | pass | 166,699 |
| `fallback` | commands; macOS re-keys after a hide | convergence, last command wins, settles | pass | 374,395 |
| `split-commands` | commands; focus queue and workers split, app A busy | convergence, last command wins, no blank frame, recovery path | pass | 52,684 |
| `split-user` | as `user`, split, app A busy, background raises reported | convergence, last command wins, last activation wins, recovery path | pass | 530,263 |
| `split-user-quiet` | as `split-user`, background raises not reported | as `split-user` | pass | 440,378 |
| `split-user-busyb` | as `split-user`, app B busy | as `split-user` | pass | 415,258 |
| `split-hover` | as `hover`, split, app A busy, background raises reported | convergence, last command wins, last activation wins, recovery path | pass | 962,166 |
| `split-hover-quiet` | as `split-hover`, background raises not reported | as `split-hover` | pass | 812,303 |
| `split-hover-settles` | as `split-hover` | every disturbance settles (liveness) | pass | 962,166 |
| `fallback-user` | all inputs; macOS re-keys after a hide | last activation wins | fails, expected | 4,114,056 |
| `mixed` | commands, reveal first | no mixed frame | fails, expected | 63 |
| `conceal-first` | commands, conceal first | no mixed frame, no blank frame | fails, expected | 54 |
| `skip-on-report` | commands; main skips the last reported key window | convergence, last command wins | fails, expected | 5,525 |

The `split-` configs run a focus request as the focus queue's and the target app worker's
separate steps (`SplitQueue`), with the queue's 30 ms wait able to run out for the busy app
(`BusyApp`), and with a raise in a background app reported as a focus change or not
(`RaiseReports`).

`skip-on-report` records how Kosmos worked before the focus queue checked the key window
(change 8 below). The other three expected failures record trade-offs:

- **`mixed` and `conceal-first`.** Revealing first shows windows of both workspaces for
  one bridged operation. Concealing first shows an empty desktop for the same time. Kosmos
  reveals first.
- **`fallback-user`.** If macOS re-keys a visible window after Kosmos hides the key
  window, the re-key looks the same as a click. After Kosmos follows a Command-Tab to
  another workspace, a re-key onto another window of that workspace wins over the
  Command-Tab: the workspace is right and the window is wrong. Re-keys have not been seen
  on hardware; the probes in the virtual machine will settle it.

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

A hover counts as a command because of a counterexample of the same kind as change 1:
with the hover unstamped, a click made before the hover but reported after it was
adopted, and focus left the window the pointer rested in.

Two more changes came from TLC after the implementation was checked against the spec:

8. **Skipping on reports.** The main actor skipped a request for the window macOS last
   reported key. Reports lag: after `workspace 2` then `workspace 1`, the second switch's
   request for w1 was skipped because the report of w3 had not arrived, and w3 stayed
   key. Requesting while an echo was due instead recorded an expectation for a request
   that changed nothing; no report cleared it, and a later click away and back to that
   window was taken for an echo. Recording no expectation for such a request let it land
   after a click and be adopted as the user's. The main actor now requests every focus,
   and the focus queue skips a request whose window is really key when it runs.
9. **Recording at the call.** With expectations recorded when the main actor requested and
   forgotten when the queue skipped, the user's click back to a window matched the
   expectation of a re-request the queue had not run yet, and was taken for an echo. The
   queue now records each expectation just before its call, so a request it skips leaves
   nothing to match.

The split configs found more, each in the implementation's order of steps before the
change that removed it:

10. **Background reports.** A busy app's late raise of w3, after the user had switched
    away, changed only that background app's own focused window, and the app reported it.
    w3 was concealed by then, so Kosmos took the report for a Command-Tab and followed it
    back to the workspace the user had left. A report from an app that is not the front
    process when it arrives now consumes an echo it matches and is otherwise ignored, and
    it does not count as the last report, or the user's real Command-Tab to that window
    was later dropped as a repeat.
11. **Recording for the other side.** Records were taken by whichever of the queue and the
    worker decided first, before the other's call. A worker that found the target key
    already dropped the queue's record, and the queue's activation then went unrecorded
    and was adopted after the user's click. A request that turned stale after its record
    kept it, and it swallowed the user's own click or Command-Tab to that window. A raise
    that recorded after the queue's activation changed nothing and left its record
    behind. Now each side records only just before its own call that changes the key
    window: the worker before a raise inside the front app, the queue before the key
    record that activates a background app. The queue posts no key record for a front
    app, where it changes nothing, and each side skips its call once the other has made
    one.
