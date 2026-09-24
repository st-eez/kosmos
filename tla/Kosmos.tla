------------------------------- MODULE Kosmos -------------------------------
(***************************************************************************)
(* Kosmos's workspace switch (docs/DESIGN.md, sections 4.3 and 5.4) at the *)
(* level of its queues:                                                    *)
(*                                                                         *)
(*   mq  the main actor's jobs: commands, barrier resumptions, observer    *)
(*       reports. A job runs to completion.                                *)
(*   bq  the bridge queue: reveal and conceal operations on the holding    *)
(*       Space, and the barrier read that resumes the command.             *)
(*   fq  the focus queue: front a window, or front Finder with no window   *)
(*       for an empty workspace. Each request carries its generation and   *)
(*       is dropped when a newer intent exists.                            *)
(*                                                                         *)
(* macOS keys the window it is asked to, and reports every key window      *)
(* change to the main actor later. Kosmos records the focus it performs.   *)
(* An echo is a report of a requested window received after the request;   *)
(* key changes carry a sequence number (`i`) for that.                     *)
(*                                                                         *)
(* Any other report is the user's (a click or Command-Tab). A report of a  *)
(* user activation that happened before the latest command is stale: the   *)
(* command wins and its focus is requested again. Each user input and each *)
(* key change carries its position in the input history (`t`) to express   *)
(* "happened before"; the implementation stamps hotkeys and observer       *)
(* callbacks on receipt.                                                   *)
(*                                                                         *)
(* Fronting another window of the app that is already key can miss,        *)
(* leaving that app's key window as it was and reporting it again.         *)
(*                                                                         *)
(* A fresh report of a window on the visible workspace becomes the focus.  *)
(* Only the user reaches a hidden window, with Command-Tab or by opening   *)
(* that window, so Kosmos follows a report into another workspace only if  *)
(* the window was hidden when it became key. A report that repeats a       *)
(* hidden key window while Kosmos awaits the echo of its request to that   *)
(* window's app is a miss: Kosmos requests its focus again. A visible      *)
(* window of another workspace can only be key mid-switch, from a macOS    *)
(* re-key or a user activation of a window about to be concealed; the      *)
(* switch wins.                                                            *)
(*                                                                         *)
(* The key window can leave: it closes or minimizes, or its app hides.     *)
(* macOS keys another window at once, possibly a hidden one. That report   *)
(* is not Command-Tab: the window key before it has left the screen.       *)
(* Kosmos learns that from the departure itself, or from WindowServer,     *)
(* which can still show the window for a moment after macOS keyed the next *)
(* one, as after a hide. A report that Kosmos would follow waits a short   *)
(* grace for that evidence. If the window left, Kosmos keeps its workspace *)
(* and focuses it again; if not, it follows. The departure reaches Kosmos  *)
(* separately, before or after the report. Kosmos never fronts a window    *)
(* that left, which would unminimize it or unhide its app: if the report   *)
(* comes first while its focus is that window, the departure focuses the   *)
(* workspace's next window, or Finder. A closed focus is replaced at once. *)
(*                                                                         *)
(* A window that did not close can return: it is unminimized, its app      *)
(* unhides, or it leaves native fullscreen. macOS keys it, and its return  *)
(* reaches Kosmos on the departures' path. Kosmos puts it back on its      *)
(* workspace and follows it there, unless a command was received after     *)
(* the return: the command wins, as it does over a stale Command-Tab.      *)
(*                                                                         *)
(* Two generations: `sw` names the latest switch and gates its resume;     *)
(* `gen` names the latest focus intent and gates focus requests. Adopting  *)
(* a window on the visible workspace starts a new intent and leaves a      *)
(* switch in flight to resume.                                             *)
(*                                                                         *)
(* Workspaces are laid out while hidden, so a switch writes no frames and  *)
(* frames are not modelled.                                                *)
(*                                                                         *)
(* Each display shows one workspace, and each workspace belongs on one     *)
(* display (`DisplayOf`, the profile's assignment). The focused workspace  *)
(* is the one on the focused display. A window on any shown workspace is   *)
(* on screen: a report of it is adopted and moves the focus to its         *)
(* display, and a command for a shown workspace only moves the focus.      *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Win,            \* windows
    Workspaces,     \* workspace 1 is visible initially
    WsOf,           \* [Win -> Workspaces]
    DisplayOf,      \* [Workspaces -> displays]: the display each workspace shows on
    AppOf,          \* [Win -> apps]
    MaxEvents,      \* bound on user inputs
    AllowClicks,    \* the user may click a visible window
    AllowCmdTab,    \* the user may Command-Tab to any other app's window
    AllowOpen,      \* the user or an app may key a specific hidden window, as `open` or a Window menu does
    AllowFallback,  \* macOS may re-key when the key window is hidden (not observed)
    AllowLeave,     \* the key window may close or minimize, or its app hide
    AllowMiss,      \* fronting another window of the key app may leave its key window, once
    AllowQuiet,     \* a departure may leave no key window and no report of one
    AllowLate,      \* macOS may key the next window after Kosmos hears of the departure, as after a minimize
    AllowReturn,    \* a window that left without closing may return
    FollowRekeys,   \* Kosmos follows a re-key onto a hidden window (the behaviour before this rule)
    FollowStale,    \* Kosmos follows a return received before the latest command (the behaviour before this rule)
    Grace,          \* Kosmos holds a report until it knows whether the key window before it left
    MissRule,       \* Kosmos takes a repeat of a hidden key window during its request to that app for a miss
    AdoptShown,     \* Kosmos adopts a window of any shown workspace, where it adopted the focused workspace's alone
    WaitBound,      \* a departure's wait for macOS's report of the next key window has a bound
    RevealFirst,    \* a switch reveals the incoming windows before concealing the outgoing
    Coalesce        \* a resumed command does not focus while a newer command is queued

ASSUME RevealFirst \in BOOLEAN /\ Coalesce \in BOOLEAN /\ AllowLeave \in BOOLEAN /\ FollowRekeys \in BOOLEAN
ASSUME AllowReturn \in BOOLEAN /\ FollowStale \in BOOLEAN /\ Grace \in BOOLEAN
ASSUME AllowMiss \in BOOLEAN /\ MissRule \in BOOLEAN /\ AllowQuiet \in BOOLEAN /\ WaitBound \in BOOLEAN
ASSUME AllowOpen \in BOOLEAN /\ AllowLate \in BOOLEAN /\ AdoptShown \in BOOLEAN

NoWin == "none"   \* no key window: Finder fronted without windows
AppOfX(w) == IF w = NoWin THEN "finder" ELSE AppOf[w]
WsWins(k) == {w \in Win : WsOf[w] = k}
Displays == {DisplayOf[k] : k \in Workspaces}
\* The first workspace of each display is shown initially.
InitShown == [d \in Displays |-> CHOOSE k \in Workspaces : DisplayOf[k] = d /\ \A j \in Workspaces : DisplayOf[j] = d => k <= j]
Shown(t) == {t.onDisplay[d] : d \in Displays}
ShownWins(t) == UNION {WsWins(k) : k \in Shown(t)}

VARIABLES
    s,        \* the state record
    history   \* user inputs: k = `workspace k`, -1 = click, -2 = Command-Tab, -3 = key window leaves,
              \* -4 = a window returns, -5 = a hidden window opened

vars == <<s, history>>

Job(kind, ws, g, evs, t) == [kind |-> kind, ws |-> ws, g |-> g, evs |-> evs, t |-> t]
\* k: the workspace revealed, or kept visible by a conceal. skip: the windows
\* Kosmos knew had left when it planned the switch, which it leaves out.
\* k: the workspace each display shows once the switch is done.
Op(op, k, g, skip) == [op |-> op, k |-> k, g |-> g, skip |-> skip]
FocusOp(w, g) == [w |-> w, g |-> g]

InitMru(f) == [k \in Workspaces |->
                 IF k = 1 THEN f ELSE IF WsWins(k) = {} THEN NoWin ELSE CHOOSE w \in WsWins(k) : TRUE]

Init ==
    /\ \E f \in WsWins(1) :
         s = [ start    |-> f,
               active   |-> 1,        \* Kosmos: the focused workspace
               onDisplay |-> InitShown, \* Kosmos: the workspace each display shows
               focus    |-> f,        \* Kosmos: focused window, NoWin on an empty workspace
               mru      |-> InitMru(f),
               sw       |-> 0,        \* latest switch
               gen      |-> 0,        \* current focus intent
               hidden   |-> [w \in Win |-> WsOf[w] \notin {InitShown[d] : d \in Displays}],   \* WindowServer: in the holding Space
               recorded |-> TRUE,     \* holding Space id published before any hide
               osFocus  |-> f,        \* macOS key window
               ne       |-> 0,        \* key changes so far
               shown    |-> InitShown, \* WindowServer: the workspaces of the last executed reveal
               lastCmdT |-> 0,        \* input position of the latest executed command
               lastWin  |-> {},       \* ghost: the windows the latest input claims if it was a click, Command-Tab or return
               goal     |-> InitShown, \* ghost: the workspace the user last asked for on each display
               mq       |-> <<>>,
               bq       |-> <<>>,
               fq       |-> <<>>,
               evs      |-> <<>>,     \* key window changes not yet reported
               expect   |-> <<>>,     \* performed focus requests not yet reported
               gone     |-> {},       \* WindowServer: closed, minimized or hidden with their app
               closed   |-> {},       \* WindowServer: the gone windows that closed and never return
               lag      |-> {},       \* WindowServer: gone windows it does not report gone yet
               left     |-> {},       \* Kosmos: departures it has handled
               held     |-> <<>>,     \* Kosmos: a report waiting to learn whether the key window before it left
               seenKey  |-> f,        \* Kosmos: the key window macOS last reported
               missed   |-> FALSE,    \* macOS: a focus request already missed
               waiting  |-> NoWin,    \* Kosmos: a departure waits for macOS's report after this key window
               rekey    |-> <<>>,     \* macOS: the key change it makes when a departure's animation ends: [w, t]
               notices  |-> <<>> ]    \* departures and returns not yet reported: [w, closed, back, t]
    /\ history = <<>>

Visible == {w \in Win : ~s.hidden[w] /\ w \notin s.gone}

RECURSIVE SeqOf(_)
SeqOf(S) == IF S = {} THEN <<>> ELSE LET x == CHOOSE x \in S : TRUE IN <<x>> \o SeqOf(S \ {x})

(***************************************************************************)
(* macOS                                                                   *)
(***************************************************************************)
\* `at` is the input position when the key window changed. A minimizing window
\* that is no longer key leaves nothing for macOS to key when its animation
\* ends, so a key change drops a pending one (not measured; the departures
\* probe asks).
KeyChange(t, w, at) ==
    IF t.osFocus = w THEN t
    ELSE [t EXCEPT !.osFocus = w, !.rekey = <<>>,
                   !.ne = t.ne + 1,
                   !.evs = Append(@, [w |-> w, act |-> AppOfX(t.osFocus) # AppOfX(w), t |-> at, i |-> t.ne + 1,
                                      hid |-> w # NoWin /\ t.hidden[w], prev |-> t.osFocus])]

(***************************************************************************)
(* The switch protocol                                                     *)
(***************************************************************************)
\* Model changes happen at once on the main actor; WindowServer work is queued.
\* k shows on its display, which becomes focused.
StartSwitch(t, k, target) ==
    LET shown == [t.onDisplay EXCEPT ![DisplayOf[k]] = k]
        reveal == Op("reveal", shown, 0, t.left)
        conceal == Op("conceal", shown, 0, t.left)
        ops == IF RevealFirst THEN <<reveal, conceal>> ELSE <<conceal, reveal>>
        mru1 == IF t.focus # NoWin THEN [t.mru EXCEPT ![t.active] = t.focus] ELSE t.mru
    IN [t EXCEPT !.sw = t.sw + 1,
                 !.gen = t.gen + 1,
                 !.active = k,
                 !.onDisplay = shown,
                 !.focus = target,
                 !.mru = [mru1 EXCEPT ![k] = target],
                 !.bq = t.bq \o ops \o <<Op("barrier", shown, t.sw + 1, {})>>]

\* Departures Kosmos can know of: the ones it handled, and the ones
\* WindowServer reports when Kosmos reads it.
Known(t) == t.left \cup (t.gone \ t.lag)

\* Kosmos asks the focus queue for w, unless w left the screen: fronting it
\* would unminimize it or unhide its app. Its departure focuses instead.
RequestFocus(t, w, g) ==
    IF w # NoWin /\ w \in Known(t) THEN t
    ELSE [t EXCEPT !.fq = Append(@, FocusOp(w, g))]

\* The focus moves to a workspace another display shows: nothing is revealed or
\* concealed, and its window is requested at once.
FocusShown(t, k) ==
    LET mru1 == IF t.focus # NoWin THEN [t.mru EXCEPT ![t.active] = t.focus] ELSE t.mru
    IN RequestFocus([t EXCEPT !.gen = t.gen + 1, !.active = k, !.focus = t.mru[k], !.mru = mru1],
                    t.mru[k], t.gen + 1)

RunCommand(t, x) ==
    LET t1 == [t EXCEPT !.lastCmdT = x.t]
    IN IF x.ws = t.active THEN t1
       ELSE IF x.ws \in Shown(t) THEN FocusShown(t1, x.ws)
       ELSE StartSwitch(t1, x.ws, t1.mru[x.ws])

\* The barrier confirmed the reveal. Focus the intent unless it is stale, or a
\* newer command is already queued (coalescing a burst).
Resume(t, x) ==
    IF x.g # t.sw THEN t
    ELSE IF Coalesce /\ \E n \in 1..Len(t.mq) : t.mq[n].kind = "input" /\ t.mq[n].ws # t.active THEN t
    ELSE RequestFocus(t, t.focus, t.gen)

(***************************************************************************)
(* Observer reports: echoes and user activations                           *)
(***************************************************************************)
\* A report names the key window; for an activation the observer reads the
\* app's focused window. Matching the app alone would take a Command-Tab to
\* another window of the intended app for an echo, and matching a report
\* received before the request would take the user's click for one.
Matches(ev, x) == x.w = ev.w /\ ev.i >= x.i

\* A stale report: focus the current intent again. If a switch is in flight,
\* this request is dropped while the target is hidden and the resume focuses.
Reassert(t) == RequestFocus(t, t.focus, t.gen)

\* The window key before this change has left the screen: macOS re-keyed after
\* it closed, minimized or hid, and the user did not choose this window.
KeyLeft(t, ev) == ev.prev # NoWin /\ ev.prev \in Known(t)

\* The window key before this change is not known to have left, but it may be
\* leaving: WindowServer can report it on screen after macOS keyed the next
\* window. Concealing a window leaves it ordered in, so a window Kosmos
\* concealed can be leaving too.
Undecided(t, ev) == ev.prev \notin {NoWin, ev.w} /\ ~KeyLeft(t, ev)

\* A miss of Kosmos's own request: the app of a window Kosmos asked for kept
\* its key window and reports it again, while that request awaits its echo.
MissedBy(ev, x) == x.w # ev.w /\ AppOfX(x.w) = AppOf[ev.w]
Missed(t, ev) == ev.prev = ev.w /\ \E k \in 1..Len(t.expect) : MissedBy(ev, t.expect[k])
\* The missed request, the oldest to that app since the focus queue runs in
\* order, will never come back: it leaves the expectations, so it cannot take a
\* later report of its window for its echo. Later requests keep theirs.
DropMissed(t, ev) ==
    LET k == CHOOSE k \in 1..Len(t.expect) : MissedBy(ev, t.expect[k]) /\ \A j \in 1..(k - 1) : ~MissedBy(ev, t.expect[j])
    IN [t EXCEPT !.expect = SubSeq(@, 1, k - 1) \o SubSeq(@, k + 1, Len(@))]

\* A user activation is adopted. Within the visible workspace it becomes the
\* focus intent, and is focused again in case a stale request of ours landed
\* after it. On a hidden workspace Kosmos follows it there, unless macOS keyed
\* it because the key window left. A report whose verdict depends on that and
\* is still undecided is held until the departure or the grace ends it
\* (`final`), or a newer activation of a window replaces it. Kosmos's own
\* echoes and reports of no key window leave it held. A report of no key window
\* is not held: if the key window left, its departure focuses.
Hold(t, ev) == [t EXCEPT !.held = <<ev>>]
Adopt(t, ev, final, miss) ==
    LET w == ev.w
        wait == Grace /\ ~final /\ Undecided(t, ev)
    IN IF ev.t < t.lastCmdT THEN Reassert(t)   \* happened before the latest command
       ELSE IF w = NoWin THEN IF KeyLeft(t, ev) THEN Reassert(t) ELSE t   \* a departure focuses
       ELSE IF w \in t.left THEN t   \* a window that left is no one's focus
       ELSE IF miss THEN Reassert(t)   \* retry the missed request
       ELSE IF WsOf[w] \in IF AdoptShown THEN Shown(t) ELSE {t.active}   \* on screen: its display becomes the focused one
            THEN RequestFocus([t EXCEPT !.focus = w, !.active = WsOf[w], !.mru[WsOf[w]] = w, !.gen = t.gen + 1], w, t.gen + 1)
       ELSE IF ev.hid /\ FollowRekeys THEN StartSwitch(t, WsOf[w], w)
       ELSE IF ev.hid /\ ~KeyLeft(t, ev) THEN IF wait THEN Hold(t, ev) ELSE StartSwitch(t, WsOf[w], w)
       ELSE Reassert(t)   \* visible mid-switch, or a re-key after the key window left

RECURSIVE Observe(_, _)
Observe(t, evs) ==
    IF evs = <<>> THEN t
    ELSE LET ev == Head(evs)
             ks == {k \in 1..Len(t.expect) : Matches(ev, t.expect[k])}
             \* A report after the key window a departure waited on ends the wait,
             \* unless it is Kosmos's own echo: then macOS keys nothing more.
             t0 == [t EXCEPT !.seenKey = ev.w, !.waiting = IF ev.prev = @ /\ ks = {} THEN NoWin ELSE @]
             \* A newer activation of a window ends a held report. One that repeats
             \* the held window, after a miss, is the same activation.
             again == t.held # <<>> /\ ev.w = t.held[1].w /\ ev.prev = ev.w
             newer == ev.w # NoWin /\ ev.w \notin t.left
             miss == MissRule /\ ks = {} /\ Missed(t, ev)
             t2 == IF miss THEN DropMissed(t0, ev) ELSE t0
             t1 == IF ks # {}
                   THEN LET k == CHOOSE k \in ks : \A j \in ks : k <= j
                        IN [t0 EXCEPT !.expect = SubSeq(@, k + 1, Len(@))]
                   ELSE IF again THEN t2
                   ELSE Adopt(IF newer THEN [t2 EXCEPT !.held = <<>>] ELSE t2, ev, FALSE, miss)
         IN Observe(t1, Tail(evs))

\* Kosmos learns that w left, and it leaves the model. When it was the focus,
\* the workspace's next window, or Finder on an empty workspace, becomes the
\* focus. That is focused at once for a closed window, as before. For a
\* minimized or hidden one it waits while the key window macOS last reported
\* has left too: macOS's own key change is still on its way, and focusing
\* first could put Kosmos's echo between the departure and that report. The
\* wait ends with the grace (Nudge).
NextWin(k, left) == IF WsWins(k) \ left = {} THEN NoWin ELSE CHOOSE v \in WsWins(k) \ left : TRUE
Depart(t, x) ==
    LET w == x.w
        left == t.left \cup {w}
        t1 == [t EXCEPT !.left = left,
                        !.mru[WsOf[w]] = IF @ = w THEN NextWin(WsOf[w], left) ELSE @]
        t2 == [t1 EXCEPT !.focus = t1.mru[t.active], !.gen = t.gen + 1]
    IN IF t.focus # w THEN t1
       ELSE IF x.closed \/ t.seenKey \notin Known(t1) THEN Reassert(t2)
       ELSE IF WaitBound THEN [t2 EXCEPT !.waiting = t.seenKey] ELSE t2

\* Kosmos learns that w returned at input position x.t and puts it back. It
\* follows w to its workspace, unless a command came after the return: then
\* it keeps its workspace and focus, and focuses w only on an empty workspace.
\* The switch, to the same workspace when Kosmos stays, reveals or conceals w.
Rejoin(t, x) ==
    LET w == x.w
        t1 == [t EXCEPT !.left = @ \ {w}, !.mru[WsOf[w]] = IF @ = NoWin THEN w ELSE @]
    IN IF FollowStale \/ x.t >= t.lastCmdT THEN StartSwitch(t1, WsOf[w], w)
       ELSE StartSwitch(t1, t.active, t1.mru[t.active])

RECURSIVE Hear(_, _)
Hear(t, xs) == IF xs = <<>> THEN t
               ELSE Hear(IF Head(xs).back THEN Rejoin(t, Head(xs)) ELSE Depart(t, Head(xs)), Tail(xs))

RunJob(t, x) ==
    CASE x.kind = "input"  -> RunCommand(t, x)
      [] x.kind = "resume" -> Resume(t, x)
      [] x.kind = "report" -> Observe(t, x.evs)
      [] x.kind = "notice" -> Hear(t, x.evs)

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)
ExecMain ==
    /\ s.mq # <<>>
    /\ s' = RunJob([s EXCEPT !.mq = Tail(@)], Head(s.mq))
    /\ UNCHANGED history

\* A switch leaves out the windows Kosmos knew had left when it planned it: a
\* returning window comes back concealed only if Kosmos concealed it before it
\* left.
ExecBridge ==
    LET x == Head(s.bq)
        t == [s EXCEPT !.bq = Tail(@)]
    IN /\ s.bq # <<>>
       /\ LET keep == {x.k[d] : d \in Displays} IN
          s' = CASE x.op = "reveal"  -> [t EXCEPT !.hidden = [w \in Win |-> IF WsOf[w] \in keep /\ w \notin x.skip
                                                                        THEN FALSE ELSE @[w]],
                                                 !.shown = x.k]
                 [] x.op = "conceal" -> [t EXCEPT !.hidden = [w \in Win |-> IF WsOf[w] \notin keep /\ w \notin x.skip
                                                                        THEN TRUE ELSE @[w]]]
                 [] x.op = "barrier" -> [t EXCEPT !.mq = Append(@, Job("resume", 0, x.g, <<>>, 0))]
       /\ UNCHANGED history

\* The focus queue checks the generation before each call. It never names a
\* hidden window or one that left, which would unminimize it or unhide its
\* app, and skips the call when the target is already key.
ExecFocus ==
    LET x == Head(s.fq)
        t == [s EXCEPT !.fq = Tail(@)]
        skip == x.g # s.gen \/ s.osFocus = x.w \/ (x.w # NoWin /\ (s.hidden[x.w] \/ x.w \in s.gone))
    IN /\ s.fq # <<>>
       /\ \/ s' = IF skip THEN t
                  ELSE KeyChange([t EXCEPT !.expect = Append(@, [w |-> x.w, i |-> t.ne + 1])], x.w, Len(history))
          \* A miss: the app stays on its key window and reports it again. The
          \* request was performed and awaits its echo.
          \/ /\ AllowMiss /\ ~s.missed /\ ~skip
             /\ s.osFocus # NoWin /\ AppOfX(x.w) = AppOf[s.osFocus]
             /\ s' = [t EXCEPT !.missed = TRUE, !.expect = Append(@, [w |-> x.w, i |-> t.ne + 1]),
                               !.evs = Append(@, [w |-> s.osFocus, act |-> FALSE, t |-> Len(history), i |-> s.ne,
                                                  hid |-> s.hidden[s.osFocus], prev |-> s.osFocus])]
       /\ UNCHANGED history

PostReports ==
    /\ s.evs # <<>>
    /\ s' = [s EXCEPT !.mq = Append(@, Job("report", 0, 0, s.evs, 0)), !.evs = <<>>]
    /\ UNCHANGED history

\* Departures and returns reach Kosmos on their own path, before or after the
\* key report.
PostNotices ==
    /\ s.notices # <<>>
    /\ s' = [s EXCEPT !.mq = Append(@, Job("notice", 0, 0, s.notices, 0)), !.notices = <<>>]
    /\ UNCHANGED history

\* WindowServer reports a window gone that macOS already took off the screen.
OrderOut ==
    /\ \E w \in s.lag : s' = [s EXCEPT !.lag = @ \ {w}]
    /\ UNCHANGED history

\* The grace ends and the held report is decided. The grace outlasts
\* WindowServer's delay: the window key before the report is reported gone by
\* then if it left.
Expire ==
    /\ s.held # <<>>
    /\ s.held[1].prev \notin s.lag
    /\ s' = Adopt([s EXCEPT !.held = <<>>], s.held[1], TRUE, FALSE)
    /\ UNCHANGED history

\* The bound of a departure that waited for macOS's report of the next key
\* window ends without one, as when the app keeps no key window: the departure
\* focuses. The bound outlasts macOS's key change after a minimize and the
\* report of it, so neither is on its way.
Nudge ==
    /\ WaitBound
    /\ s.waiting # NoWin
    /\ s.rekey = <<>>
    /\ s.evs = <<>> /\ \A n \in 1..Len(s.mq) : s.mq[n].kind # "report"
    /\ s' = Reassert([s EXCEPT !.waiting = NoWin])
    /\ UNCHANGED history

\* macOS keys the next window once a departure's animation ends.
Rekey ==
    /\ s.rekey # <<>>
    /\ s' = KeyChange([s EXCEPT !.rekey = <<>>], s.rekey[1].w, s.rekey[1].t)
    /\ UNCHANGED history

Fallback ==
    /\ AllowFallback
    /\ s.osFocus # NoWin
    /\ s.hidden[s.osFocus]
    /\ \E v \in (Visible \cup {NoWin}) \ {s.osFocus} : s' = KeyChange(s, v, Len(history))
    /\ UNCHANGED history

\* A user activation of a window a switch is about to conceal makes no claim.
Claim(w) == IF WsOf[w] = s.goal[DisplayOf[WsOf[w]]] \/ s.hidden[w] THEN {w} ELSE {}
Goal(w) == IF s.hidden[w] THEN [s.goal EXCEPT ![DisplayOf[WsOf[w]]] = WsOf[w]] ELSE s.goal

Command ==
    /\ Len(history) < MaxEvents
    /\ \E k \in Workspaces :
         /\ s' = [s EXCEPT !.mq = Append(@, Job("input", k, 0, <<>>, Len(history) + 1)),
                           !.lastWin = {}, !.goal[DisplayOf[k]] = k]
         /\ history' = Append(history, k)

\* A return Kosmos has not handled yet. The model leaves out clicks and
\* Command-Tab until it has: Kosmos would follow the return after them. It also
\* leaves them out during a minimize's animation: the window key before them has
\* left, so they read as macOS's own key change, and Kosmos keeps its workspace.
\* Commands stay in.
Returning == \/ \E n \in 1..Len(s.notices) : s.notices[n].back
             \/ \E n \in 1..Len(s.mq) : s.mq[n].kind = "notice" /\ \E m \in 1..Len(s.mq[n].evs) : s.mq[n].evs[m].back

Click ==
    /\ AllowClicks
    /\ ~Returning /\ s.rekey = <<>>
    /\ Len(history) < MaxEvents
    /\ \E w \in Visible \ {s.osFocus} :
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = Claim(w)]
         /\ history' = Append(history, -1)

CmdTab ==
    /\ AllowCmdTab
    /\ ~Returning /\ s.rekey = <<>>
    /\ Len(history) < MaxEvents
    /\ \E w \in Win \ s.gone :
         /\ AppOf[w] # AppOfX(s.osFocus)
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = Claim(w), !.goal = Goal(w)]
         /\ history' = Append(history, -2)

\* The user or an app keys a specific hidden window, of any app: `open` on a
\* document whose window is concealed, an app's Window menu, the Dock's window
\* list.
Open ==
    /\ AllowOpen
    /\ ~Returning /\ s.rekey = <<>>
    /\ Len(history) < MaxEvents
    /\ \E w \in Win \ s.gone :
         /\ s.hidden[w] /\ w # s.osFocus
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = {w}, !.goal[DisplayOf[WsOf[w]]] = WsOf[w]]
         /\ history' = Append(history, -5)

\* The user closes, minimizes or hides a window after seeing it key, and brings
\* one back after seeing it leave. Kosmos has had the reports before by then:
\* it handles one in milliseconds. macOS keys the next window as a window
\* finishes leaving, before the user can bring it back.
Seen == s.evs = <<>> /\ s.held = <<>> /\ s.rekey = <<>> /\ \A n \in 1..Len(s.mq) : s.mq[n].kind # "report"

\* The key window closes or minimizes, or its app hides with all its windows.
\* macOS keys another window at once, which may be hidden, or none. The
\* departure and the new key window still reach Kosmos in either order, and
\* WindowServer may report the windows gone only later.
AppWins(w) == {v \in Win : AppOf[v] = AppOf[w]}
Leave ==
    /\ AllowLeave
    /\ Len(history) < MaxEvents
    /\ s.osFocus # NoWin
    /\ Seen
    /\ \E out \in {{s.osFocus}, AppWins(s.osFocus) \ s.gone}, closed \in BOOLEAN, quiet \in BOOLEAN, late \in BOOLEAN :
       /\ closed => out = {s.osFocus}   \* a window closes alone; an app hides together
       /\ quiet => AllowQuiet
       \* Late: a minimize keys the next window when its animation ends, after
       \* Kosmos heard of the departure. A close or a hide keys it at once. The
       \* animation needs the window on screen.
       /\ late => AllowLate /\ ~quiet /\ ~closed /\ out = {s.osFocus} /\ s.osFocus \in Visible
       \* Quiet: no window becomes key, and no report says so.
       /\ \E v \in IF quiet THEN {NoWin} ELSE (Win \ (s.gone \cup out)) \cup {NoWin} :
            LET q == SeqOf(out)
                notices == [n \in 1..Len(q) |-> [w |-> q[n], closed |-> closed, back |-> FALSE, t |-> 0]]
                \* The user is on Kosmos's workspace, unless a command or a return is
                \* still on its way there.
                queued == Returning \/ \E n \in 1..Len(s.mq) : s.mq[n].kind = "input"
                t1 == [s EXCEPT !.gone = @ \cup out, !.lag = @ \cup out,
                                !.closed = IF closed THEN @ \cup out ELSE @,
                                !.notices = @ \o notices, !.lastWin = {},
                                !.goal = IF queued THEN @ ELSE s.onDisplay]
            IN /\ s' = CASE quiet -> [t1 EXCEPT !.osFocus = NoWin]
                        [] late  -> [t1 EXCEPT !.rekey = <<[w |-> v, t |-> Len(history) + 1]>>]
                        [] OTHER -> KeyChange(t1, v, Len(history) + 1)
               /\ history' = Append(history, -3)

\* A window that left returns where it was, and macOS keys it: the user
\* unminimizes it, unhides its app, or takes it out of native fullscreen.
Return ==
    /\ AllowReturn
    /\ Len(history) < MaxEvents
    /\ Seen
    /\ \E w \in s.gone \ (s.closed \cup s.lag) :
         /\ s' = KeyChange([s EXCEPT !.gone = @ \ {w}, !.lastWin = {w}, !.goal[DisplayOf[WsOf[w]]] = WsOf[w],
                                     !.notices = Append(@, [w |-> w, closed |-> FALSE, back |-> TRUE,
                                                            t |-> Len(history) + 1])],
                           w, Len(history) + 1)
         /\ history' = Append(history, -4)

Internal == ExecMain \/ ExecBridge \/ ExecFocus \/ PostReports \/ PostNotices \/ OrderOut \/ Expire \/ Nudge \/ Rekey

Next == Internal \/ Fallback \/ Command \/ Click \/ CmdTab \/ Open \/ Leave \/ Return

Spec == Init /\ [][Next]_vars /\ WF_vars(ExecMain) /\ WF_vars(ExecBridge)
                              /\ WF_vars(ExecFocus) /\ WF_vars(PostReports) /\ WF_vars(PostNotices)
                              /\ WF_vars(OrderOut) /\ WF_vars(Expire) /\ WF_vars(Nudge) /\ WF_vars(Rekey)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
Quiescent == s.mq = <<>> /\ s.bq = <<>> /\ s.fq = <<>> /\ s.evs = <<>> /\ s.notices = <<>>
             /\ s.lag = {} /\ s.held = <<>> /\ s.waiting = NoWin /\ s.rekey = <<>>

\* The screen shows Kosmos's workspaces and macOS keys Kosmos's focus.
Converged == Visible = ShownWins(s) \ s.gone /\ s.osFocus = s.focus

ConvergesWhenQuiet == Quiescent => Converged

RECURSIVE LastCommand(_)
LastCommand(h) ==   \* 0 when another input came after the last command
    IF h = <<>> THEN 0
    ELSE IF h[Len(h)] < 0 THEN 0
    ELSE h[Len(h)]

HonorsLastCommand == Quiescent /\ LastCommand(history) # 0 => s.active = LastCommand(history)

\* A click, Command-Tab or return after the last command wins, unless it makes
\* no claim.
HonorsLastActivation == Quiescent /\ s.lastWin # {} => s.focus \in s.lastWin

\* When the key window leaves, each display keeps the workspace the user had on
\* it. The focus may move to another display where macOS keyed a window.
KeepsWorkspaceAfterLeave == Quiescent /\ history # <<>> /\ history[Len(history)] = -3 => s.onDisplay = s.goal

OnDisplay(d) == {w \in Win : DisplayOf[WsOf[w]] = d}

\* Windows of two workspaces are never visible together on a display.
NoMixedFrame == \A d \in Displays : \E k \in Workspaces : Visible \cap OnDisplay(d) \subseteq WsWins(k)

\* No display is empty while the workspace WindowServer last revealed there has windows.
NoBlankFrame == \A d \in Displays : Visible \cap OnDisplay(d) = {} => WsWins(s.shown[d]) = {}

\* Every hidden window can be found from the published record.
RecoveryPath == \A w \in Win : s.hidden[w] => s.recorded

Settles == []<>Quiescent

(***************************************************************************)
(* State view: generations are only compared with the current one.         *)
(***************************************************************************)
Cur(g, c) == g # 0 /\ g = c
ViewQ(q, c) == [n \in 1..Len(q) |-> [q[n] EXCEPT !.g = Cur(q[n].g, c)]]
StateView == <<[s EXCEPT !.sw = 0, !.gen = 0,
                         !.mq = ViewQ(s.mq, s.sw), !.bq = ViewQ(s.bq, s.sw), !.fq = ViewQ(s.fq, s.gen)],
               history>>

TraceView == [history |-> history, active |-> s.active, onDisplay |-> s.onDisplay, focus |-> s.focus,
              osFocus |-> s.osFocus, visible |-> Visible, gone |-> s.gone, left |-> s.left,
              notices |-> s.notices, lag |-> s.lag, held |-> s.held, waiting |-> s.waiting, rekey |-> s.rekey,
              sw |-> s.sw, gen |-> s.gen,
              mq |-> [n \in 1..Len(s.mq) |-> s.mq[n].kind],
              bq |-> [n \in 1..Len(s.bq) |-> s.bq[n].op],
              fq |-> s.fq, expect |-> s.expect, evs |-> s.evs]
=============================================================================
