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
| `commands` | commands | convergence, last command wins, no blank frame, recovery path | pass | 11,552 |
| `user` | commands, clicks, Command-Tab | convergence, last command wins, last activation wins, recovery path | pass | 105,783 |
| `settles` | commands, clicks, Command-Tab | every disturbance settles (liveness) | pass | 105,783 |
| `no-coalesce` | as `user`, without coalescing | convergence, last command wins, last activation wins | pass | 105,237 |
| `hover` | commands, clicks, Command-Tab, hover | convergence, last command wins, last activation wins, recovery path | pass | 168,304 |
| `hover-settles` | commands, clicks, Command-Tab, hover | every disturbance settles (liveness) | pass | 168,304 |
| `fallback` | commands; macOS re-keys after a hide | convergence, last command wins, settles | pass | 392,771 |
| `fallback-user` | all inputs; macOS re-keys after a hide | last activation wins | fails, expected | 3,746,589 |
| `mixed` | commands, reveal first | no mixed frame | fails, expected | 83 |
| `conceal-first` | commands, conceal first | no mixed frame, no blank frame | fails, expected | 66 |
| `skip-on-report` | commands; main skips the last reported key window | convergence, last command wins | fails, expected | 6,219 |

The `split-` configs run a focus request as the steps the implementation takes
(`SplitQueue`): the focus queue's, the target app worker's, the app's AXRaise landing
later, the app's focus notification, and the activation read, which runs on the app's
worker and reads the app's focused window whenever it runs. The queue's 30 ms wait can run
out for the busy app (`BusyApp`, app A unless named `busyb`). A raise in a background app
is reported as a focus change, or not in the `quiet` configs (`RaiseReports`). AXRaise
alone keys a window inside the front app, or needs the key record after it in the `nokey`
configs (`RaiseKeys`). In the `background` configs background apps also change their own
focused window (`AllowBackground`). The `user` configs check what `user` checks, the
`hover` ones what `hover` checks, and `commands` what `commands` checks; `settles` checks
liveness.

| Config | Result | States | Config | Result | States |
| --- | --- | --- | --- | --- | --- |
| `split-commands` | pass | 107,142 | `split-commands-nokey` | pass | 105,685 |
| `split-commands-quiet` | pass | 105,462 | `split-commands-nokey-quiet` | pass | 103,986 |
| `split-user` | pass | 5,761,524 | `split-user-nokey` | pass | 5,995,624 |
| `split-user-quiet` | pass | 5,507,397 | `split-user-nokey-quiet` | pass | 5,773,103 |
| `split-user-busyb` | pass | 3,883,449 | `split-user-busyb-nokey` | pass | 4,161,848 |
| `split-user-busyb-quiet` | pass | 3,798,536 | `split-user-busyb-nokey-quiet` | pass | 4,074,315 |
| `split-user-background` | pass | 5,985,318 | `split-user-background-nokey` | pass | 6,223,920 |
| `split-user-background-quiet` | pass | 5,730,703 | | | |
| `split-hover` | pass | 9,163,984 | `split-hover-nokey` | pass | 9,480,149 |
| `split-hover-quiet` | pass | 8,709,564 | `split-hover-nokey-quiet` | pass | 9,074,760 |
| `split-hover-settles` | pass | 9,163,898 | `split-hover-nokey-settles` | pass | 9,479,847 |

Each of these runs one rule the implementation had, and fails as expected (change 12):

| Config | The rule | Result | States |
| --- | --- | --- | --- |
| `split-user-actcheck` | an activation read counts only while its app is front (`ActFrontCheck`) | fails, expected | 86,784 |
| `split-user-latenote` | a focus notification is stamped and checked when the worker delivers it (`LateNoteCheck`) | fails, expected | 865,807 |
| `split-user-timeout` | the worker gives up on a busy app's AXRaise, which still lands (`RaiseTimeout`) | fails, expected | 5,379,113 |
| `split-user-bgraise` | the worker also raises a window of a background app (`BackgroundRaise`) | fails, expected | 4,706,703 |
| `split-user-d1be665` | robust's rules at d1be665 (`SplitRules`), which change 11 replaced | fails, expected | 1,412,358 |

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
12. **Late reports and late raises.** The split model then took each report as the
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
    activated. The spec exempts it with a ghost (`lastAmb`) and DESIGN.md 5.4 records it.
