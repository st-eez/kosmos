# TLA+ spec of the workspace switch

[Kosmos.tla](Kosmos.tla) specifies the switch protocol and focus classification from
[DESIGN.md](../docs/DESIGN.md), sections 4.3 and 5.4. It models three queues: the main
actor, the bridge queue that reveals and conceals windows through the holding Space, and
the focus queue. macOS sits between them: it keys the requested window and reports every
key window change to the main actor later. The user issues workspace commands, clicks
visible windows, uses Command-Tab, and closes, minimizes or hides the key window, then
brings it back.

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
| `user` | commands, clicks, Command-Tab | convergence, last command wins, last activation wins, recovery path | pass | 98,785 |
| `settles` | commands, clicks, Command-Tab | every disturbance settles (liveness) | pass | 98,785 |
| `no-coalesce` | as `user`, without coalescing | convergence, last command wins, last activation wins | pass | 98,265 |
| `fallback` | commands; macOS re-keys after a hide | convergence, last command wins, settles | pass | 337,718 |
| `fallback-user` | all inputs; macOS re-keys after a hide | last activation wins | fails, expected | 3,077,021 |
| `mixed` | commands, reveal first | no mixed frame | fails, expected | 92 |
| `conceal-first` | commands, conceal first | no mixed frame, no blank frame | fails, expected | 72 |
| `leave` | all inputs, and the key window leaving and returning | convergence, last command wins, last activation wins, keeps its workspace after a leave, recovery path | pass | 1,451,991 |
| `leave-settles` | as `leave` | every disturbance settles (liveness) | pass | 1,451,991 |
| `leave-follow` | all inputs and the key window leaving, following re-keys as before | keeps its workspace after a leave | fails, expected | 343,376 |
| `return-stale` | as `leave`, following returns received before a command as before | last command wins | fails, expected | 1,221,507 |

The first three expected failures record trade-offs, and `leave-follow` and
`return-stale` record the behaviour this model replaced:

- **`mixed` and `conceal-first`.** Revealing first shows windows of both workspaces for
  one bridged operation. Concealing first shows an empty desktop for the same time. Kosmos
  reveals first.
- **`fallback-user`.** If macOS re-keys a visible window after Kosmos hides the key
  window, the re-key looks the same as a click. After Kosmos follows a Command-Tab to
  another workspace, a re-key onto another window of that workspace wins over the
  Command-Tab: the workspace is right and the window is wrong. Re-keys have not been seen
  on hardware; the probes in the virtual machine will settle it.
- **`leave-follow`.** When the key window closes or minimizes, or its app hides, macOS
  keys another window, which can be concealed on another workspace. Following that
  report switches workspaces the user never asked for. This happened live: Command-H on
  the only window of workspace 2 took Kosmos to workspace 1.
- **`return-stale`.** A window comes back: it is unminimized, its app unhides, or it
  leaves native fullscreen. If the user runs a workspace command before Kosmos handles
  the return, following the return takes Kosmos away from the workspace the command
  chose.

The key window leaves, and a window returns, only after Kosmos has had the reports before
it. Kosmos handles one in milliseconds, far below the time a person needs to see a window
become key and then close, minimize or hide it, or to see it leave and bring it back. The
departure or return and the report of the next key window still reach Kosmos in either
order.

The model leaves out a click or Command-Tab made while Kosmos has not yet handled a return.
Kosmos would follow the return after them and undo the user's choice. A command there is
covered. A report is not, because a return makes macOS key windows too, and Kosmos cannot
yet tell those key changes from the user's. The gap is widest when a window leaves
fullscreen: Kosmos handles that return once the window joins the desktop's Space, about
0.5 s after it starts to leave.

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
