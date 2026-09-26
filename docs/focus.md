# Focus

- There is one current focus intent, identified by a focus generation. A switch has its own
  generation, so a focus change adopted during a switch leaves the switch to finish.
- Every report names the key window, the front app's focused window. A key change inside
  an app is reported by the app's focused window notification, and an app that came front
  also by its activation read: the main actor notices and stamps the activation, and the
  app's worker reads the app's focused window. A notification is stamped, and checked
  against the front process, in its callback on an observer thread that never waits
  behind the worker's calls into the app. Checked when the worker got to it, a click inside
  the front app that raced Kosmos's activation of another app was dropped (tla/README.md,
  change 19, `split-user-latenote`). The callback still runs some time after the change,
  and Kosmos can key or hide windows in between (change 20). An activation read is checked
  against the front process on the main actor, once the worker's read returns. Hotkeys and
  socket commands are stamped on receipt.
- Reports are classified in order:
  - An echo is a report of a requested window received after the request. Matching the
    app alone would take a Command-Tab to another window of that app for an echo. Records
    requested before the matched one go with it, so a record whose echo never comes goes
    once a later request's echo comes.
  - A report from an app that is not the front process, at the notification's callback or
    once the activation read returns, consumes an echo it matches and is otherwise
    ignored: background apps report windows they open, and a raise in a background app
    reports a focus change. Such a report is never the key window Kosmos last heard of
    (change 17).
  - A click or Command-Tab received before the latest command is stale. The command wins,
    and its focus is requested again.
  - A window on a workspace that a display shows becomes the focus intent, and its
    display becomes the focused one ([displays.md](displays.md)). It is requested again, in case an
    older request of Kosmos's landed after the user's change.
  - Only the user reaches a window that was hidden when it became key: with Command-Tab,
    or by opening that window, as `open` on a document, an app's Window menu or the
    Dock's window list do. Kosmos follows it to its workspace, whether a notification or an
    activation read reports it: a window opened inside the front app has only its
    notification (tla/README.md, change 22, `split-open-readfollows`). Whether the window
    was hidden is judged at the report's stamp: the bridge queue notes when it sends each
    window's conceal and reveal, because a switch can reveal or conceal the window before
    the report is classified (change 19). Only each window's last change is kept: a report
    is classified within milliseconds of its stamp. That excludes the report right
    after the key window left, when it closed or minimized or its app hid. macOS then keys
    another window itself, sometimes a concealed one, and Kosmos keeps its workspace and
    focuses it again. The window key before the report left the screen within the last second if
    WindowServer ordered it out or destroyed it, Accessibility reported it minimized, or
    NSWorkspace reported its app hidden. The window key before a report is the one Kosmos
    last heard of, unless the report repeats that window, as an activation read after its
    app's notification of the same change does. Then it is the window before that one:
    otherwise the read follows the re-key the notification declined (tla/README.md,
    change 24).
  - A window the front app keyed before Kosmos admitted it, as a launching app keys its
    first window, is the user's choice too, and its report waits for the window's place
    (`AdmissionFocus`). So does the key report of a window closed and kept, which takes a
    place as a new window when its app opens it again ([tree.md](tree.md)). On a shown
    workspace the window becomes the focus. On a hidden one, which only a rule names for a
    new window, the report is decided as one of a concealed window whose key window before
    it stayed, since an app keys a window it opens, and Kosmos follows it there
    (displays.md). A report that comes after the admission and
    before the window's conceal completes is followed the same way. After that, Kosmos
    requests its focus intent again, and a later report loses to it, as a tab's does
    (tree.md). A command received after the report wins, as over a Command-Tab. Kosmos
    follows no window parked at admission or admitted while the session is locked.
    On 2026-09-25 at 10:25:31 Steve launched Chrome from workspace 8, and a rule put its
    first window on workspace 4, which no display showed. The log has no key window report
    from Chrome, and Accessibility answered for the window 854 ms after WindowServer made
    it a candidate, within the launch retries: Chrome keyed the window before its worker's
    observer was registered, and its activation read got no answer while it launched.
    Kosmos concealed the window, keyed Claude on workspace 8 again, and Steve pressed alt-4
    himself. A worker now reports its app's focused window when it starts, before any of
    the app's windows is admitted (geometry.md). KosmosCore's tests replay the waiting
    report through the admission and its follow (`KeyReportIntake`), and cover
    `AdmissionFocus` and the classification. The Controller decides the report before the
    admission's plan runs, and a follow joins that plan, so one switch shows the rule's
    workspace with the window never concealed. Before this, the plan concealed the window
    where its app opened it, and the follow's switch revealed it there before its write
    moved it. No test covers that order, the worker's report at its start or its refusal of
    window reads before it: they are in KosmosApp, which has no test target.
  - macOS can key the next app before WindowServer orders a hidden app's windows out, so
    a report that would follow waits 100 ms, then is decided by what Kosmos knows of the
    window key before it. A report of another window replaces it, and a held report whose
    window is no longer the key window last heard of when the grace ends is dropped. Every
    held report logs its outcome. A Command-Tab after that report follows as usual, 100 ms
    late. This happened live: Command-H on the only window of workspace 2 took Kosmos to
    workspace 1, where macOS keyed Ghostty. So did the drop, on 2026-09-25: from
    workspace 6, alt-1 key-recorded Ghostty's window on workspace 1, Ghostty first keyed
    its last key window, concealed on workspace 5, then the requested one, and the held
    report of the first, decided after Kosmos's echo of the second, took Kosmos to
    workspace 5.
  - A report that repeats the key window Kosmos last heard of, while a request of Kosmos's
    to another window of that app awaits its echo, is a miss of that request, not the
    user's choice: the app kept its key window, or keyed another one itself before
    reporting the requested one. Preview re-keyed its main window within about 40 ms of a
    hover keying its second window (live, 2026-09-24 at 23:56). The missed request, the
    oldest to the app as the focus queue runs requests in order, never comes back, so it
    leaves the expected echoes. Kosmos requests the focus again, once for each requested
    window; if that misses too, it leaves the key window where macOS put it. A report that
    echoes a request is no miss: an app can report the window again after the raise that
    follows its key record (below). A report that repeats the held window leaves the hold
    standing.
  - A visible window of a workspace that no display shows is key only during a switch:
    macOS re-keyed after a hide, or the user clicked or Command-Tabbed to a window about to be
    concealed. The switch wins, and its focus is requested again. After a batch fails,
    recovery shows every workspace's windows until a switch conceals them again. A
    click on one is then the user's, and Kosmos follows it as it follows a Command-Tab.
- Five races leave Kosmos nothing to tell the cases apart. They are known limits, and the
  TLA+ spec exempts them:
  - Kosmos keys an app again before that app's activation read runs. The read finds
    Kosmos's window, and a Command-Tab to another window of that app is lost.
  - A request Kosmos made before the user's click inside the front app activates another
    app before the click's callback runs. The callback finds another app in front, as
    for a background app's own change, and the click is lost.
  - A switch reveals or conceals a window between the user's change and the main actor's
    notice or the notification's callback. Kosmos can then follow a click that lands on a
    window in the milliseconds it is being concealed, which costs one switch back, or lose
    a Command-Tab to a hidden window. Notifications follow so that a window opened inside
    the front app brings Kosmos to it, which admits this race.
  - The user keys a window of an app between the worker's read before a raise and the
    app performing that raise. A change to the raised window reads as the raise's echo,
    and after a change to another window the raise keys its window again over the user's.
    The report of a raise after a key record reaches the main actor from the app's
    observer thread, and the worker's word that the raise is done from the worker's, so
    the report can come after its record is forgotten and read as the user's choice of the
    raised window. The spec runs the app's callbacks for the raise before the worker's
    read. Forgetting the record only once the observer has handled the notifications the
    app sent before it answered the worker's read would close this. Besides this race, an
    app reported the window it had focused already after 6 of 40 such raises ([overview.md, section 2](overview.md#2-what-the-fork-measured)); read as the user's, that report takes focus back to the
    window only when a newer request came between the raise and the report.
  - The key window closes or minimizes, and macOS reports no next key window. Kosmos counts
    the departure for a second from when it heard of it (DepartureLog), so a Command-Tab
    within that second reads as macOS's re-key, and Kosmos keeps its workspace. The spec
    lets the second pass once Kosmos has every report (tla/README.md, change 24, `Age`),
    and exempts input inside it (`lastEarly`).
- Skip activation when the target is already key, checked by the focus queue when the
  request runs: the target's app is the front process and its focused window, read on the
  app's worker, is the target. The key window last reported can be older than a request
  still in flight: after `workspace 2` then `workspace 1` in quick succession, a skip
  against it dropped the request for w1 before w3's report arrived, and w3's echo then
  left macOS keying w3 while Kosmos focused w1 (kosmos-hover's TLC counterexample;
  tla/Kosmos.tla, ExecFocus). The front process lookup takes 1.6 us, and only a request for
  the front app pays an AX read. A read with no answer stops a request for a window and is
  logged. The read and the raise go to the same app with the same timeout, so the app is
  not answering, and a record for a call that changes nothing would swallow a later click
  on the window: going ahead failed TLC's user configs, whose model assumes reads answer.
  The empty workspace's window, its display's (below), is key already when Kosmos is the
  front process and the window's last key change on the main actor said it became key.
- A private request for a window runs as the split model in tla/Kosmos.tla specifies it,
  one step per action (KosmosCore's KeyRequest: FocusStart, WorkerStart, WorkerRead,
  WorkerRaise, FocusDecide as `queueKeys`, WorkerPost). Each side records the echo,
  through the main queue, right before its own call that changes the key window, never at
  the request and never for the other side's call (tla/README.md, changes 16 and 18).
  The queue checks the generation, reads whether the target's app is front, hands the app's
  worker one job, and waits for it at most 30 ms, as the main actor waits on a worker.
  - Inside the front app the key record changes nothing and only AXRaise keys a window, so
    the worker keys it and the queue posts no key record. The worker ends a stale request,
    and one whose front app already has the target focused; then, just before the raise,
    it records and raises if the request is current and the app is still front. The app
    stays front while it has no key window after its key window closed or minimized, and
    Kosmos reads the front process from WindowServer, so the worker raises there too
    (change 24).
  - For a background app the queue keys it, and nothing raises the window before the key
    record: a raise in a background app lands after anything that fronts the app
    meanwhile, and in TLC it keyed a stale window over a newer activation (change 19,
    `split-user-bgraise`). The app's job does nothing, and the queue waits on it only so
    its key record follows the app's queued activation reads. Unless the request went stale
    or the app came front meanwhile, the queue records and posts the key record, which
    activates the app with the named window but leaves it where it sits in its app's
    stacking order.
  - Then the app's worker raises the window, only while the app is front and the window is
    its focused window, so it never raises over a window the user chose since. Every
    private request for a background app's window gets this raise, whatever made it: a
    focus command, the focus after a switch, a move that follows its window, the next
    window after a departure, a reassert, or the pointer ([focus-follows-mouse.md](focus-follows-mouse.md)). The window then
    comes up over the windows it overlaps, other apps' floating windows included. The
    raise does not check that the request is current: with that check, a hover on the same
    window made the raise stale, the new request found the window key and raised nothing,
    and the window stayed behind its app's other windows (`FocusOnTop` failed
    `split-hover`; without the raise `split-user-nopostraise` fails it). The worker records
    the raise's echo just before it, since the raise keys the window again if the user
    keyed another window of the app first. Once the raise has returned and the worker has
    read the app's focused window, the main actor forgets the record if no report used it.
    Without the record `split-open-postraisenone` fails, and with a record kept until
    matched `split-open-postraisekept` does (changes 21 and 23). The ceiling: the worker's
    read can reach the app before the app handles the key record, and then finds the
    window it had focused before and skips the raise. Each skip is logged with whether the
    app was front and the window it had focused. The log stays until `kosmos-probe keying`
    runs its `record, then AXRaise while front and focused` order, which measures that
    read.
  - Only the raise after a key record has its record forgotten, once the raise is done, so
    no late answer can orphan any other call; `forgetRecord` otherwise serves only a call that
    fails.
  - Kosmos builds the model's RaiseKeys case, where AXRaise alone keys the target inside
    the front app ([overview.md, section 2](overview.md#2-what-the-fork-measured)). The model's WorkerKey step, for the other case, is left out.
    TLC checks the spec's full rule set, and no TLC run checks the part Kosmos builds
    (Deferred, below).
  - Recording when the request was made failed TLC's `user` config. The user clicked w2, and
    Kosmos requested w2 again. Before the queue ran that request, the user clicked w1 and
    then w2, the second click on w2 was taken for the queued request's echo, and Kosmos
    stayed on w1.
  - An expectation whose echo arrived while the session was locked is never consumed, since
    reports are not classified then, so a resync forgets every pending one.
- The focus queue never names a concealed window (tla/Kosmos.tla, ExecFocus). A request for
  a window Hiding held concealed when the request was made still supersedes older requests,
  and then keys nothing; the switch that reveals the window requests focus once its
  confirmation shows the reveal. The concealment is the one known on the main actor at the request,
  since Hiding's ledger lives on the bridge queue.
- When a newer command for another workspace is already queued, the older one lays out but
  doesn't focus.
- Every focus request passes one gate: while macOS shows a native fullscreen window's
  Space, only a command requests focus. The Space counts as shown while its window is
  key, or a panel or dialog of its app that Kosmos does not manage. Parking the fullscreen
  window moved Kosmos's focus to a desktop window. Focusing the next one when that window
  closes or hides, or after an unhide conceals the app's other windows, would take the
  user out of fullscreen.
- Never front a window that just left the screen, before Kosmos heard of it: that would
  unminimize it or unhide its app. The window's departure then focuses its workspace's
  next window, or Kosmos's empty workspace window. A closed focus is replaced at once. A minimized or hidden one is
  replaced at once too, unless the key window macOS last reported left with it: then
  macOS's report of the next key window is still on its way and focuses. Focusing earlier
  could put Kosmos's echo between the departure and that report. When macOS keys no
  window, the departure focuses, and when no report comes within a second, as when an
  app keeps no key window after its last window minimizes, the departure focuses then.
  The second outlasts a minimize, whose next key window macOS reported 0.73 s after the
  minimize. A window keyed during the animation, by Kosmos or the user, is taken to leave
  macOS nothing to key when it ends (not measured; the departures probe asks). A click
  or Command-Tab during the animation reads as macOS's own key change, so Kosmos keeps
  its workspace.
  - A window its app closed and kept departs when Kosmos counts it closed
    ([tree.md](tree.md)). When its app has no other candidate window macOS could key, one
    ordered in and not minimized, the app stays front with no window and no report comes,
    so the departure focuses at once. Activity Monitor's only
    window, closed while key, got no report, and Helium became key 1.1 s after the window
    parked, when the second ran out (live log, September 25, 2026). A concealed window
    counts as one macOS could key: it stays ordered in, and macOS keyed concealed windows
    (below). With such a window macOS keys it as the window closes, and the departure
    waits for that report as a minimize's does, up to the second. A window that closes
    and is destroyed has no such wait: its removal requests the next focus at once.
  - macOS fronted no other app when an app's last window closed. In the live logs of
    September 24 and 25, seven closes of an app's only managed window while it was key,
    three of Activity Monitor's, one of Spotify's and three of Microsoft Teams', were
    followed by no report from any app for 1.2 to 2.1 s, until Kosmos's own request or
    the user's next command. The app stays front with no key window (tla/README.md, change
    24). One close is unexplained: 0.68 s after Claude's window closed on September 24 at
    about 10:57:31.7, Finder came front with no key window, as a click on the desktop also
    makes it, and no debug log was kept.
- The private path has a kill switch with two triggers. Once off, it stays off across
  restarts until `kosmos reload-config`, and the status item names the cause.
  - A crash guard. A byte in a file mapped shared is set during each private call and
    cleared after it, and a byte found set at launch turns the path off. The two stores
    cost about 1.4 ns and make no system call. A kill that lands inside the call turns the
    path off too.
  - Wrong windows. Only the private key record counts, which keys a background app's
    window; inside the front app the raise keys it. A request misses when its app reports
    another of its windows key, and neither an echo of any request nor a report of the
    requested window arrives first, before Kosmos's next request. A background report that
    consumes the echo leaves the count alone. A miss and a retry that misses too count as
    one miss. Five misses in a row turn the path off. On this Mac AXRaise and then the
    private sequence keyed the right window in 60 of 60 AutoRaise trials, 9 of them
    between two windows of the active app, so the miss rate is at most about 5% at 95%
    confidence, and five misses in a row at 5% come once in about 3 million runs. Those
    trials raised first and posted a down and up record pair. Kosmos's own sequence, the
    down record alone to a background app, keyed the named window in every trial ([overview.md, section 2](overview.md#2-what-the-fork-measured)).
    The public path chose the wrong window in 9 of 9 trials, so a false trip costs more
    than a few late wrong windows ([overview.md, section 3](overview.md#3-primitive-decisions);
    AutoRaise trials of September 8, 2026).
    A request with no report neither misses nor clears the count, so a record that changes
    nothing, as the record alone did inside the active app, goes uncounted.
- AXRaise runs on the app's worker, inside the front app, where only it keys a window, and
  after the key record, which leaves another app's window where it sits in its app's
  stacking order ([overview.md, section 2](overview.md#2-what-the-fork-measured)). yabai and alt-tab raise after the record too. A hung app
  holds only its own worker.
- The worker waits for the app to perform the raise, for up to 5 s. A raise it stopped
  waiting for still lands when the app gets to it: in TLC it keyed a concealed window after
  a newer command, and Kosmos followed it there (tla/README.md, change 19,
  `split-user-timeout`). A raise that outlasts the 5 s counts as made, so its echo is
  still recognized, and its app is backed off ([geometry.md](geometry.md)). Only a raise
  the app refuses or fails at once is dropped. No measurement chose the 5 s.
- While the path is off, and for a request whose SkyLight call fails, focus takes the
  public path on the app's worker: make the window the app's main window, raise it, then
  activate the app. Each step can wait out the timeout on a slow app, so each first checks
  that the request is still current: a request stale before its record does nothing, and
  one that goes stale after its record stops and keeps it for any report its steps cause.
  A background accessory app with no window, as Kosmos is, made another app the front
  process in 10 of 10 trials with each of `activate`, yielding and then
  `activate(from:)` itself, and `activate(from:)` the front app, and Finder in 10 of 10
  with each (`kosmos-probe keying`, September 24, 2026). An empty workspace has no public
  path: its window is Kosmos's own, and an accessory app that activated itself became the
  front process in 0 of 10 trials, as activate returned false. The app
  picks its key window, so the spec's assumption that the requested window becomes key no
  longer holds, and a wrong window is adopted like the user's choice. A public request's
  expectation ends at the first report from its app that is no echo, so a click on the
  requested window afterwards is the user's. Private requests keep theirs until matched
  (tla/README.md, change 6). The spec models exact keying only, so its TLC passes do not
  cover the public path. If the app keys the requested window late, after the user chose
  another of its windows, that late report reads as the user's and pulls focus back,
  change 6's bounce in the fallback alone.
- An empty workspace keys a window of Kosmos's own (EmptyWorkspaceWindow): 1 by 1 point at
  the bottom left corner of the display the workspace is on, borderless, clear and
  transparent, ignoring the mouse, on every Space, and out of the window cycle and Mission
  Control (`transient`). With displays that have separate Spaces, keying a window makes its
  display the active one, which takes the menu bar and the next new window. An app fronted
  with no window brought forward still keys its own last key window:
  `kosmos_front_without_windows` let a stub key its window in 10 of 10 trials, and a stub
  whose every window was concealed keyed one of them in 10 of 10 in each of four ways, kept
  in their ordinary Space or concealed exclusively, fronted by `activate` or by
  `kosmos_front_without_windows`. So Finder, or any app with a concealed window, cannot be
  the target: Kosmos would follow the concealed window it keys off the empty workspace on
  every switch. A background accessory app keyed an invisible window of its own by the
  private key record in 10 of 10 trials, from its own background thread and from another
  process (`kosmos-probe keying`, September 24, 2026).
  - Each display has a window of its own, made at its bottom left corner and never moved,
    as each display keeps its own border window ([borders.md](borders.md)). Before
    2026-09-25 one window moved to the empty workspace's display before each request:
    `setFrameOrigin` ran on the main actor while the focus queue posted the key record from
    its own thread, and the border hop showed AppKit's new frame reaching WindowServer after
    another thread's SkyLight call. Keyed at its old place, the window left the menu bar and
    the next new window on the display it came from. The focus queue also skipped the moved
    window as key already when it was key on the other display. A display that goes keeps
    its window for its return. A display whose frame changes gets a new window, created at
    its new corner at the display change, and the old one closes, so no move is left to
    land late. Unmeasured: whether the order-in of a window made at a display change can
    reach WindowServer after the key record of the resync that follows in the same main
    actor turn.
  - Inside the front app the key record keys nothing
    ([overview.md, section 2](overview.md#2-what-the-fork-measured)), so while Kosmos is
    the front process with another of its windows key, as another display's empty
    workspace window, AppKit keys the window on the main actor, and the request records
    its echo just before. Unmeasured: whether AppKit's key change inside Kosmos moves the
    menu bar to the window's display as the key record does.
  - Kosmos is an accessory app, and the inventory tracks only regular apps' windows, so it
    never manages or conceals the window. The window becoming key is the key window report
    for an empty workspace, as Kosmos keeps no worker for itself; it names no window and
    is the echo of the request's record of no key window.
  - Kosmos has no main menu, and the window swallows every key and key equivalent, so
    typing on an empty workspace neither beeps nor reaches a menu command such as Quit.
    Hotkeys still fire: Carbon hotkeys are taken before the key reaches any window.
  - Another app fronted with no key window takes the keys and key equivalents instead. Live
    on 2026-09-24, a click on the desktop of the left panel, which showed an empty
    workspace, fronted Finder, and Cmd-Q quit it; the report of no key window from Finder
    repeated the empty workspace's and went unnoticed. After a key press or a click in the
    last second such a report is the user's choice and stays, as is an app launched since
    the empty workspace window became key, which activates before its first window. With
    neither, macOS or the app fronted it, and Kosmos keys the empty workspace window again.
  - The kill switch guards the call like any private call, and a crash inside it turns the
    path off. The wrong window count judges only key records to other apps' windows, so
    that trigger leaves the empty workspace's window keyed privately. After a crash the
    empty workspace keys nothing and the previous window stays key, as there is no public
    path to Kosmos's own window.
  - AeroSpace does nothing on an empty workspace, so macOS keeps the outgoing window key
    while it is hidden and keystrokes reach it (`refresh.swift`, upstream at 39e51904). The
    aerospace-steez fork fronts Finder with `kCPSNoWindows` instead, following yabai (its
    commit 2031030b), which keys a Finder window whenever Finder has one.
- Open item: a focus request reads WindowServer on the main thread to skip a window that
  just left the screen (`leftScreen`). Right after a switch that read waits on
  WindowServer's Space transaction: 29 of about 290 busy main thread samples in 40
  switches on 2026-09-24. The focus queue could read it at FocusStart instead, off the
  main thread and closer to the key call. That changes RequestFocus and FocusStart in
  tla/Kosmos.tla, as the request would take a new generation even when the queue drops its
  target, so it waits for that change to the spec and a TLC run of it.
- Open item: a switch requested while a native fullscreen Space is on screen. The private
  path keys the target window but leaves the fullscreen Space on screen. On 2026-09-24 at
  00:37:39 Kosmos fronted Ghostty, and the display stayed on Helium's fullscreen Space
  until the user swiped 3.4 s later (WindowServer's SetManagedDisplayCurrentSpace log).
  AeroSpace focuses with the public `NSRunningApplication.activate` on one monitor, which
  lets the Dock switch to the Space that holds the window. The plan is that when the main
  display's current Space is not ordinary and the target is a window, the focus queue
  follows the private call with that public activation. An empty workspace would still
  leave the fullscreen Space on screen, as in AeroSpace. It waits for a probe with a real
  fullscreen Space, which takes over the screen.
- Deferred. The spec's split model makes these changes too (tla/README.md, changes 19 to
  24). Each answers a race TLC found, and none has been seen live, so Kosmos leaves them
  out until one is:
  - Held notifications (change 20, `HoldNotes`; `split-user-background-nohold`). A
    notification from an app Kosmos activated, received before that activation's read,
    waits for the read, and stands only if the read finds its window. Without it, a
    background app's own change whose callback runs after Kosmos's older request brought
    the app front is adopted, over the user's later Command-Tab. The live evidence: a
    window adopted just after Kosmos activated its app, one the user did not pick, with its
    notification logged before the app's activation read.
  - Removing only the matched record, with three rules that come with it (change 19): an
    activation read matches its app's key record whatever window it reads, a notification
    of that window only joins the record, and an echo that names a window other than the
    intent requests the intent again. Removing only the matched record alone leaves a
    record whose echo never comes, as when an app re-keys another window before reporting
    the requested one, to swallow a later Command-Tab to its window, and the activation
    read rule consumes that record. Kosmos drops the records before the matched one, so an
    earlier request's echo that arrives after a later one's reads as the user's choice.
    Kosmos also lets the notification of its own activation consume the record, so the
    activation read is a report of its own. The split configs found these races before
    change 19, and none keeps the old rules. The live evidence: on a fast sweep of the
    pointer across apps, focus going back to a window the pointer left, with that
    window's report logged after the echo of the later request.
  - An activation read of an app that lost the front that still stands when Kosmos
    recorded an activation after its stamp, or when the app had already lost the front to
    Kosmos's activation as the main actor noticed it (changes 19 and 20, `NoticeCheck`;
    `split-user-actcheck`, `split-user-notice-nocheck`). Kosmos ignores such a read, so
    a Command-Tab is lost when an older request of Kosmos's fronts another app before the
    read runs (Apps.activated). The live evidence: a Command-Tab that Kosmos did not
    follow, with a request of Kosmos's to another app just before.
  - Dropping the miss rule (change 21). The rule dates from the key record inside the
    front app, which keys nothing there ([overview.md, section 2](overview.md#2-what-the-fork-measured)): live, Kosmos fronted Ghostty for a
    window of workspace 1, Ghostty reported the window a switch had just concealed on
    workspace 3, and Kosmos followed it there. The worker's raise keys that window now.
    The activation read of a Command-Tab repeats the window its own notification just
    reported, so the rule takes it for a miss of an older request to that app, and the
    Command-Tab is lost (`split-user-missrule`). Dropping the rule comes only with the
    rule above that an activation read matches its app's key record whatever window it
    reads. On the private path the miss rule is what clears a key record whose echo never
    comes, as when Preview re-keyed its main window, and without either that record
    swallows the user's later report of its window. The spec drops the held report's
    repeat check with the rule; Kosmos keeps it, so a newer Command-Tab to the window of
    an older held report is taken for that report, and lost when the grace finds the
    older one stale. The live evidence: a Command-Tab lost as a miss, with "focus request
    missed" logged for the window it reached, or lost at a grace's end.
  - Reports overtaken by a newer one (changes 19 to 21). A report stamped before the last
    report Kosmos adopted or followed is ignored, as is one stamped before a held report,
    which it would otherwise end and replace: the user clicked a window of one app, then of
    another, and the first app's report came last. It comes only with the rule above that a
    notification of Kosmos's key record only joins that record. Without it, one of the two
    reports of Kosmos's own activation is adopted and counts as the last report taken, and
    a Command-Tab of the user's whose notification arrives after it is dropped. The live
    evidence: a late older report adopted, as focus going back to a window the user left,
    with its report logged after the report of the window the user chose next, or a held
    report's log line "replaced by" naming a report stamped before it.
