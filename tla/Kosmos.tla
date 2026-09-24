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
(* macOS keys exactly the window it is asked to, and reports every key     *)
(* window change to the main actor later. The main actor knows the key     *)
(* window only from reports (`seen`), which lag, so it requests every      *)
(* focus. The focus queue checks the real key window when it runs a        *)
(* request, skips one whose window is already key, and records the echo it *)
(* expects just before each call it makes. An echo is a report of a        *)
(* requested window received after that record; key changes carry a       *)
(* sequence number (`i`) for that.                                         *)
(*                                                                         *)
(* Focus follows mouse: when the pointer rests in a window WindowServer    *)
(* shows, Kosmos focuses it if it is a window of Kosmos's shown workspace. *)
(* A hover focus counts as a command.                                      *)
(*                                                                         *)
(* Any other report is the user's (a click or Command-Tab). A report of a  *)
(* user activation that happened before the latest command is stale: the   *)
(* command wins and its focus is requested again. Each user input and each *)
(* key change carries its position in the input history (`t`) to express   *)
(* "happened before"; the implementation stamps hotkeys and observer       *)
(* callbacks on receipt.                                                   *)
(*                                                                         *)
(* A fresh report of a window on the visible workspace becomes the focus.  *)
(* Only Command-Tab reaches a hidden window, so Kosmos follows a report    *)
(* into another workspace only if the window was hidden when it became     *)
(* key. A visible window of another workspace can only be key mid-switch,  *)
(* from a macOS re-key or a user activation of a window about to be     *)
(* concealed; the switch wins.                                             *)
(*                                                                         *)
(* Two generations: `sw` names the latest switch and gates its resume;     *)
(* `gen` names the latest focus intent and gates focus requests. Adopting  *)
(* a window on the visible workspace starts a new intent and leaves a      *)
(* switch in flight to resume.                                             *)
(*                                                                         *)
(* With SplitQueue, a focus request runs as separate steps of the focus    *)
(* queue and the target app's worker. The queue reads whether the app is   *)
(* front and hands the worker a job, then waits for it, or for BusyApp may *)
(* give up after its 30 ms timeout. The worker skips a stale request or a  *)
(* window key already, then raises it, bringing it to the front of its     *)
(* app. Inside the front app the key record changes nothing unless the     *)
(* window is frontmost, so the worker keys: with RaiseKeys the raise keys  *)
(* the window, and otherwise the key record the worker posts after it      *)
(* does. For a background app the queue posts the key record that          *)
(* activates it, unless the worker is keying it. Each side records the     *)
(* echo only right before its own call that changes the key window. A      *)
(* raise in a background app changes only the app's own focused window,    *)
(* which the app reports as a focus change when RaiseReports; so may a     *)
(* background app that opens a window (AllowBackground). SplitRules =      *)
(* "d1be665" instead models the rules robust had at d1be665.               *)
(*                                                                         *)
(* Workspaces are laid out while hidden, so a switch writes no frames and  *)
(* frames are not modelled.                                                *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Win,            \* windows
    Workspaces,     \* workspace 1 is visible initially
    WsOf,           \* [Win -> Workspaces]
    AppOf,          \* [Win -> apps]
    MaxEvents,      \* bound on user inputs
    AllowClicks,    \* the user may click a visible window
    AllowCmdTab,    \* the user may Command-Tab to any other app's window
    AllowHover,     \* the pointer may rest in a visible window (focus follows mouse)
    AllowFallback,  \* macOS may re-key when the key window is hidden (not observed)
    RevealFirst,    \* a switch reveals the incoming windows before concealing the outgoing
    Coalesce,       \* a resumed command does not focus while a newer command is queued
    SkipOnReport,   \* main skips a request for the key window macOS last reported (Kosmos
                    \* before the focus queue checked the key window)
    SplitQueue,     \* a focus request runs as the focus queue's and the app worker's steps
    BusyApp,        \* with SplitQueue, the app whose worker can outlast the queue's wait
    RaiseReports,   \* with SplitQueue, raising a background app's window makes it report
                    \* a focus change
    RaiseKeys,      \* with SplitQueue, AXRaise alone keys a window inside the front app;
                    \* otherwise the key record after the raise does
    SplitRules,     \* with SplitQueue, "record-at-call" (the design) or "d1be665" (robust
                    \* at d1be665, for comparison)
    AllowBackground \* a background app may change its own focused window without coming
                    \* front

ASSUME RevealFirst \in BOOLEAN /\ Coalesce \in BOOLEAN /\ SkipOnReport \in BOOLEAN
ASSUME SplitQueue \in BOOLEAN /\ RaiseReports \in BOOLEAN /\ RaiseKeys \in BOOLEAN
ASSUME SplitRules \in {"record-at-call", "d1be665"} /\ AllowBackground \in BOOLEAN

NoWin == "none"   \* no key window: Finder fronted without windows
AppOfX(w) == IF w = NoWin THEN "finder" ELSE AppOf[w]
WsWins(k) == {w \in Win : WsOf[w] = k}
Apps == {AppOf[w] : w \in Win}
NoReq == [r |-> 0]

VARIABLES
    s,        \* the state record
    history   \* user inputs: k = `workspace k`, -1 = click, -2 = Command-Tab, -3 = hover,
              \* -4 = a background app's focused window changed

vars == <<s, history>>

\* `ws` holds the window for a hover job.
Job(kind, ws, g, evs, t) == [kind |-> kind, ws |-> ws, g |-> g, evs |-> evs, t |-> t]
Op(op, k, g) == [op |-> op, k |-> k, g |-> g]   \* k: workspace revealed, or kept visible by a conceal

InitMru(f) == [k \in Workspaces |->
                 IF k = 1 THEN f ELSE IF WsWins(k) = {} THEN NoWin ELSE CHOOSE w \in WsWins(k) : TRUE]

Init ==
    /\ \E f \in WsWins(1) :
         s = [ start    |-> f,
               active   |-> 1,        \* Kosmos: visible workspace
               focus    |-> f,        \* Kosmos: focused window, NoWin on an empty workspace
               mru      |-> InitMru(f),
               sw       |-> 0,        \* latest switch
               gen      |-> 0,        \* current focus intent
               hidden   |-> [w \in Win |-> WsOf[w] # 1],   \* WindowServer: in the holding Space
               recorded |-> TRUE,     \* holding Space id published before any hide
               osFocus  |-> f,        \* macOS key window
               seen     |-> f,        \* Kosmos: the key window macOS last reported
               ne       |-> 0,        \* key changes so far
               shown    |-> 1,        \* WindowServer: workspace of the last executed reveal
               lastCmdT |-> 0,        \* input position of the latest executed command
               lastWin  |-> "",       \* ghost: target of the latest input if it was a click or Command-Tab
               goal     |-> 1,        \* ghost: the workspace the user last asked for
               mq       |-> <<>>,
               bq       |-> <<>>,
               fq       |-> <<>>,
               evs      |-> <<>>,     \* key window changes not yet reported
               expect   |-> <<>>,     \* focus requests whose echo has not come back
               \* SplitQueue only:
               afocus   |-> [a \in Apps |-> IF AppOf[f] = a THEN f ELSE CHOOSE w \in Win : AppOf[w] = a],
                                      \* each app's own focused window, its key window while front
               atop     |-> [a \in Apps |-> IF AppOf[f] = a THEN f ELSE CHOOSE w \in Win : AppOf[w] = a],
                                      \* each app's frontmost window
               fcur     |-> NoReq,    \* the request the focus queue is running
               wq       |-> [a \in Apps |-> <<>>],   \* each app worker's jobs
               kr       |-> <<>>,     \* KeyRequest phase by request number
               jdone    |-> {} ]      \* requests whose worker job has finished
    /\ history = <<>>

Visible == {w \in Win : ~s.hidden[w]}

(***************************************************************************)
(* macOS                                                                   *)
(***************************************************************************)
\* `at` is the input position when the key window changed.
KeyChange(t, w, at) ==
    IF t.osFocus = w THEN t
    ELSE [t EXCEPT !.osFocus = w,
                   !.afocus = IF w = NoWin THEN @ ELSE [@ EXCEPT ![AppOf[w]] = w],
                   !.ne = t.ne + 1,
                   !.evs = Append(@, [w |-> w, act |-> AppOfX(t.osFocus) # AppOfX(w), t |-> at, i |-> t.ne + 1,
                                      hid |-> w # NoWin /\ t.hidden[w], bg |-> FALSE])]

\* A background app's own focused window changes, and the app reports it as a focus
\* change although the key window stays where it is. Kosmos checks the front process when
\* such a report arrives (`bg`), which the model takes to be when the app sends it; a
\* report that waits behind a busy worker can be judged by a newer front process.
BackgroundFocus(t, w, at) ==
    [t EXCEPT !.afocus[AppOf[w]] = w,
              !.ne = t.ne + 1,
              !.evs = Append(@, [w |-> w, act |-> FALSE, t |-> at, i |-> t.ne + 1, hid |-> t.hidden[w], bg |-> TRUE])]

(***************************************************************************)
(* The switch protocol                                                     *)
(***************************************************************************)
\* Model changes happen at once on the main actor; WindowServer work is queued.
StartSwitch(t, k, target) ==
    LET reveal == Op("reveal", k, 0)
        conceal == Op("conceal", k, 0)
        ops == IF RevealFirst THEN <<reveal, conceal>> ELSE <<conceal, reveal>>
        mru1 == IF t.focus # NoWin THEN [t.mru EXCEPT ![t.active] = t.focus] ELSE t.mru
    IN [t EXCEPT !.sw = t.sw + 1,
                 !.gen = t.gen + 1,
                 !.active = k,
                 !.focus = target,
                 !.mru = [mru1 EXCEPT ![k] = target],
                 !.bq = t.bq \o ops \o <<Op("barrier", k, t.sw + 1)>>]

\* A focus request from the main actor (Controller.requestFocus).
Request(t, w, g) ==
    IF SkipOnReport /\ w = t.seen THEN t
    ELSE [t EXCEPT !.fq = Append(@, [w |-> w, g |-> g, c |-> w # NoWin /\ t.hidden[w]])]

\* The main actor records the echo of a call about to be made (Controller.performing); `r`
\* names the request, so d1be665's drop can forget it.
Record(t, w, r) == [t EXCEPT !.expect = Append(@, [w |-> w, i |-> t.ne + 1, r |-> r])]
Forget(t, r) ==
    LET ks == {k \in 1..Len(t.expect) : t.expect[k].r = r}
    IN IF ks = {} THEN t
       ELSE LET k == CHOOSE k \in ks : TRUE
            IN [t EXCEPT !.expect = SubSeq(@, 1, k - 1) \o SubSeq(@, k + 1, Len(@))]

RunCommand(t, x) ==
    LET t1 == [t EXCEPT !.lastCmdT = x.t]
    IN IF x.ws = t.active THEN t1 ELSE StartSwitch(t1, x.ws, t1.mru[x.ws])

\* The barrier confirmed the reveal. Focus the intent unless it is stale, or a
\* newer command is already queued (coalescing a burst).
Resume(t, x) ==
    IF x.g # t.sw THEN t
    ELSE IF Coalesce /\ \E n \in 1..Len(t.mq) : t.mq[n].kind = "input" /\ t.mq[n].ws # t.active THEN t
    ELSE Request(t, t.focus, t.gen)

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
Reassert(t) == Request(t, t.focus, t.gen)

\* A user activation is adopted. Within the visible workspace it becomes the
\* focus intent, and is focused again in case a stale request of ours landed
\* after it. On a hidden workspace Kosmos follows it there.
Adopt(t, ev) ==
    LET w == ev.w
    IN IF ev.t < t.lastCmdT THEN Reassert(t)   \* happened before the latest command
       ELSE IF w = NoWin THEN t
       ELSE IF WsOf[w] = t.active
            THEN Request([t EXCEPT !.focus = w, !.mru[t.active] = w, !.gen = t.gen + 1], w, t.gen + 1)
       ELSE IF ev.hid THEN StartSwitch(t, WsOf[w], w)
       ELSE Reassert(t)   \* visible mid-switch: a re-key, or a click on a window being concealed

\* With record-at-call rules, a report from an app that is not front (`bg`) consumes an echo
\* it matches, but is no key window report: unmatched it is ignored, and it never counts
\* as the last report.
RECURSIVE Observe(_, _)
Observe(t, evs) ==
    IF evs = <<>> THEN t
    ELSE IF Head(evs).w = t.seen THEN Observe(t, Tail(evs))   \* a repeat of the last report
    ELSE LET ev == Head(evs)
             bg == ev.bg /\ SplitRules = "record-at-call"
             t0 == IF bg THEN t ELSE [t EXCEPT !.seen = ev.w]
             ks == {k \in 1..Len(t0.expect) : Matches(ev, t0.expect[k])}
             t1 == IF ks # {}
                   THEN LET k == CHOOSE k \in ks : \A j \in ks : k <= j
                        IN [t0 EXCEPT !.expect = SubSeq(@, k + 1, Len(@))]
                   ELSE IF bg THEN t0
                   ELSE Adopt(t0, ev)
         IN Observe(t1, Tail(evs))

\* A hover focus is a command for a window of the shown workspace: reports of user
\* activations before it are stale, and it is requested like any focus. A window of
\* another workspace, visible only mid-switch, leaves focus alone.
RunHover(t, x) ==
    LET w == x.ws
    IN IF WsOf[w] # t.active THEN t
       ELSE Request([t EXCEPT !.lastCmdT = x.t, !.focus = w, !.mru[t.active] = w, !.gen = t.gen + 1],
                    w, t.gen + 1)

RunJob(t, x) ==
    CASE x.kind = "input"  -> RunCommand(t, x)
      [] x.kind = "hover"  -> RunHover(t, x)
      [] x.kind = "resume" -> Resume(t, x)
      [] x.kind = "report" -> Observe(t, x.evs)

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)
ExecMain ==
    /\ s.mq # <<>>
    /\ s' = RunJob([s EXCEPT !.mq = Tail(@)], Head(s.mq))
    /\ UNCHANGED history

ExecBridge ==
    LET x == Head(s.bq)
        t == [s EXCEPT !.bq = Tail(@)]
    IN /\ s.bq # <<>>
       /\ s' = CASE x.op = "reveal"  -> [t EXCEPT !.hidden = [w \in Win |-> IF WsOf[w] = x.k THEN FALSE ELSE @[w]],
                                                 !.shown = x.k]
                 [] x.op = "conceal" -> [t EXCEPT !.hidden = [w \in Win |-> IF WsOf[w] # x.k THEN TRUE ELSE @[w]]]
                 [] x.op = "barrier" -> [t EXCEPT !.mq = Append(@, Job("resume", 0, x.g, <<>>, 0))]
       /\ UNCHANGED history

\* The focus queue checks the generation before each call, never names a hidden window,
\* and skips a request whose window is already key, judged from the real key window
\* when the request runs. It records the echo it expects just before each call it makes,
\* so a request it skips leaves no expectation behind.
ExecFocus ==
    LET x == Head(s.fq)
        t == [s EXCEPT !.fq = Tail(@)]
    IN /\ ~SplitQueue
       /\ s.fq # <<>>
       /\ s' = IF x.g # s.gen \/ s.osFocus = x.w \/ (x.w # NoWin /\ s.hidden[x.w]) THEN t
               ELSE KeyChange(Record(t, x.w, 0), x.w, Len(history))
       /\ UNCHANGED history

(***************************************************************************)
(* The focus request in the implementation's steps (SplitQueue)            *)
(***************************************************************************)
\* The queue takes a request. A stale one, or one whose window was concealed when it was
\* requested, does nothing. Finder with no window is keyed at once. Otherwise the queue
\* reads whether the target's app is front and hands the worker its job.
FocusStart ==
    LET x == Head(s.fq)
        t == [s EXCEPT !.fq = Tail(@)]
        a == AppOfX(x.w)
        r == Len(s.kr) + 1
        front == AppOfX(s.osFocus) = a
    IN /\ SplitQueue
       /\ s.fcur = NoReq
       /\ s.fq # <<>>
       /\ s' = IF x.g # s.gen \/ x.c THEN t
               ELSE IF x.w = NoWin THEN IF s.osFocus = NoWin THEN t ELSE KeyChange(Record(t, NoWin, 0), NoWin, Len(history))
               ELSE [t EXCEPT !.kr = Append(@, "pending"),
                              !.wq[a] = Append(@, [r |-> r, w |-> x.w, g |-> x.g, front |-> front, st |-> "start"]),
                              !.fcur = [r |-> r, w |-> x.w, g |-> x.g, front |-> front, st |-> "wait"]]
       /\ UNCHANGED history

\* The key record: it activates a background app with the named window, leaving the
\* stacking order alone. Inside the front app it keys the window only when a raise has made
\* it the app's frontmost window (`kosmos-probe raise`), and changes nothing otherwise.
KeyRecord(t, a, w) ==
    IF AppOfX(t.osFocus) # a \/ t.atop[a] = w THEN KeyChange(t, w, Len(history)) ELSE t

\* AXRaise brings the window to the front of its app. Inside the front app it also keys
\* the window when RaiseKeys; in a background app it changes the app's own focused window,
\* reported when RaiseReports.
Raise(t, a, w) ==
    LET u == [t EXCEPT !.atop[a] = w]
    IN IF AppOfX(t.osFocus) = a THEN (IF RaiseKeys THEN KeyChange(u, w, Len(history)) ELSE u)
       ELSE IF t.afocus[a] = w THEN u
       ELSE IF RaiseReports THEN BackgroundFocus(u, w, Len(history))
       ELSE [u EXCEPT !.afocus[a] = w]

\* The queue stops waiting: the job finished, or, for BusyApp, 30 ms passed.
\* record-at-call: for a front app the queue only moves on; the worker keys. For a
\* background app, unless the request went stale, the app came front meanwhile, or the
\* worker is keying it, the queue records and posts the key record.
\* d1be665: a pending request is recorded by the queue; then the key record follows.
FocusDecide ==
    LET c == s.fcur
        t == [s EXCEPT !.fcur = NoReq]
        ph == s.kr[c.r]
    IN /\ SplitQueue
       /\ c # NoReq
       /\ c.st = "wait"
       /\ c.r \in s.jdone \/ AppOf[c.w] = BusyApp
       /\ s' = IF SplitRules = "record-at-call"
               THEN IF c.front \/ c.g # s.gen \/ AppOfX(s.osFocus) = AppOf[c.w] \/ ph = "raising" THEN t
                    ELSE [KeyRecord(Record(t, c.w, c.r), AppOf[c.w], c.w) EXCEPT !.kr[c.r] = "sent"]
               ELSE CASE ph = "skipped" -> t
                      [] ph = "pending" -> [Record(s, c.w, c.r) EXCEPT !.kr[c.r] = "recorded", !.fcur.st = "key"]
                      [] OTHER -> [s EXCEPT !.fcur.st = "key"]
       /\ UNCHANGED history

\* d1be665 only: the queue posts the key record after its decision.
FocusKey ==
    LET c == s.fcur
    IN /\ SplitQueue
       /\ c # NoReq
       /\ c.st = "key"
       /\ s' = KeyRecord([s EXCEPT !.fcur = NoReq], AppOf[c.w], c.w)
       /\ UNCHANGED history

Finish(t, a, j) == [t EXCEPT !.wq[a] = Tail(@), !.jdone = @ \cup {j.r}]

\* The worker's job starts: a stale request ends.
WorkerStart(a) ==
    LET j == Head(s.wq[a])
        ph == s.kr[j.r]
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "start"
       /\ s' = IF SplitRules = "d1be665" /\ ph = "pending" /\ j.g # s.gen THEN Finish([s EXCEPT !.kr[j.r] = "skipped"], a, j)
               ELSE IF SplitRules = "d1be665" /\ ph = "skipped" THEN Finish(s, a, j)
               ELSE IF SplitRules = "record-at-call" /\ j.g # s.gen THEN Finish(s, a, j)
               ELSE [s EXCEPT !.wq[a][1].st = "read"]
       /\ UNCHANGED history

\* The worker reads the app's focused window when the queue found the app front.
\* record-at-call: a stale request, or a window key already, ends.
\* d1be665 (KeyRequest.workerDecides): pending and stale or key already is skipped,
\* pending otherwise is recorded; recorded by the queue: stale ends, dropping the record
\* if the app was front; key already drops; otherwise raise.
WorkerRead(a) ==
    LET j == Head(s.wq[a])
        ph == s.kr[j.r]
        stale == j.g # s.gen
        already == j.front /\ s.afocus[a] = j.w
        raise(t) == [t EXCEPT !.wq[a][1].st = "raise"]
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "read"
       /\ s' = IF SplitRules = "record-at-call"
               THEN IF stale \/ already THEN Finish(s, a, j) ELSE raise(s)
               ELSE CASE ph = "pending" /\ (stale \/ already) -> Finish([s EXCEPT !.kr[j.r] = "skipped"], a, j)
                      [] ph = "pending" -> raise([Record(s, j.w, j.r) EXCEPT !.kr[j.r] = "recorded"])
                      [] stale /\ j.front -> Finish(Forget(s, j.r), a, j)
                      [] stale -> Finish(s, a, j)
                      [] already -> Finish(Forget(s, j.r), a, j)
                      [] OTHER -> raise(s)
       /\ UNCHANGED history

\* Just before AXRaise, under the request's lock.
\* record-at-call: a stale request, or one the queue has keyed, raises nothing. In the front
\* app the worker tells the queue it is keying; when RaiseKeys the raise keys the window
\* and the worker records just before it, and otherwise the key record after the raise
\* does. In a background app it raises without a record; the queue's key record keys it.
\* d1be665: the generation is rechecked; a stale request raises nothing, and its record is
\* dropped if the app was front.
WorkerRaise(a) ==
    LET j == Head(s.wq[a])
        t == Finish(s, a, j)
        stale == j.g # s.gen
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "raise"
       /\ s' = IF SplitRules = "record-at-call"
               THEN IF stale \/ s.kr[j.r] = "sent" THEN t
                    ELSE IF AppOfX(s.osFocus) = a
                         THEN IF RaiseKeys THEN [Raise(Record(t, j.w, j.r), a, j.w) EXCEPT !.kr[j.r] = "raising"]
                              ELSE [Raise(s, a, j.w) EXCEPT !.kr[j.r] = "raising", !.wq[a][1].st = "key"]
                    ELSE Raise(t, a, j.w)
               ELSE IF stale THEN (IF j.front THEN Forget(t, j.r) ELSE t)
               ELSE Raise(t, a, j.w)
       /\ UNCHANGED history

\* record-at-call without RaiseKeys: after a raise inside the front app, a current request
\* records and posts the key record, which keys the raised window; a stale one ends.
WorkerKey(a) ==
    LET j == Head(s.wq[a])
        t == Finish(s, a, j)
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "key"
       /\ s' = IF j.g # s.gen THEN t ELSE KeyRecord(Record(t, j.w, j.r), a, j.w)
       /\ UNCHANGED history

Worker(a) == WorkerStart(a) \/ WorkerRead(a) \/ WorkerRaise(a) \/ WorkerKey(a)

PostReports ==
    /\ s.evs # <<>>
    /\ s' = [s EXCEPT !.mq = Append(@, Job("report", 0, 0, s.evs, 0)), !.evs = <<>>]
    /\ UNCHANGED history

Fallback ==
    /\ AllowFallback
    /\ s.osFocus # NoWin
    /\ s.hidden[s.osFocus]
    /\ \E v \in (Visible \cup {NoWin}) \ {s.osFocus} : s' = KeyChange(s, v, Len(history))
    /\ UNCHANGED history

\* A user activation of a window a switch is about to conceal makes no claim.
Claim(w) == IF WsOf[w] = s.goal \/ s.hidden[w] THEN w ELSE ""
Goal(w) == IF s.hidden[w] THEN WsOf[w] ELSE s.goal

Command ==
    /\ Len(history) < MaxEvents
    /\ \E k \in Workspaces :
         /\ s' = [s EXCEPT !.mq = Append(@, Job("input", k, 0, <<>>, Len(history) + 1)),
                           !.lastWin = "", !.goal = k]
         /\ history' = Append(history, k)

Click ==
    /\ AllowClicks
    /\ Len(history) < MaxEvents
    /\ \E w \in Visible \ {s.osFocus} :
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = Claim(w), !.atop[AppOf[w]] = w]
         /\ history' = Append(history, -1)

CmdTab ==
    /\ AllowCmdTab
    /\ Len(history) < MaxEvents
    /\ \E w \in Win :
         /\ AppOf[w] # AppOfX(s.osFocus)
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = Claim(w), !.goal = Goal(w),
                                                            !.atop[AppOf[w]] = w]
         /\ history' = Append(history, -2)

\* The pointer comes to rest in a visible window. Focus follows mouse never moves the
\* key window by itself; Kosmos's hover job does.
Hover ==
    /\ AllowHover
    /\ Len(history) < MaxEvents
    /\ \E w \in Visible :
         /\ s' = [s EXCEPT !.mq = Append(@, Job("hover", w, 0, <<>>, Len(history) + 1)), !.lastWin = Claim(w)]
         /\ history' = Append(history, -3)

\* A background app changes its own focused window, as when it opens a window, without
\* coming front; keystrokes still go to the front app's key window.
UserBackground ==
    /\ AllowBackground
    /\ Len(history) < MaxEvents
    /\ \E w \in Win :
         /\ AppOf[w] # AppOfX(s.osFocus)
         /\ s.afocus[AppOf[w]] # w
         /\ s' = BackgroundFocus(s, w, Len(history) + 1)
         /\ history' = Append(history, -4)

Internal == ExecMain \/ ExecBridge \/ ExecFocus \/ PostReports
            \/ FocusStart \/ FocusDecide \/ FocusKey \/ \E a \in Apps : Worker(a)

Next == Internal \/ Fallback \/ Command \/ Click \/ CmdTab \/ Hover \/ UserBackground

Spec == Init /\ [][Next]_vars /\ WF_vars(ExecMain) /\ WF_vars(ExecBridge)
                              /\ WF_vars(ExecFocus) /\ WF_vars(PostReports)
                              /\ WF_vars(FocusStart) /\ WF_vars(FocusDecide) /\ WF_vars(FocusKey)
                              /\ \A a \in Apps : WF_vars(Worker(a))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
Quiescent == s.mq = <<>> /\ s.bq = <<>> /\ s.fq = <<>> /\ s.evs = <<>>
             /\ s.fcur = NoReq /\ \A a \in Apps : s.wq[a] = <<>>

\* The screen shows Kosmos's workspace and macOS keys Kosmos's focus.
Converged == Visible = WsWins(s.active) /\ s.osFocus = s.focus

ConvergesWhenQuiet == Quiescent => Converged

RECURSIVE LastCommand(_)
LastCommand(h) ==   \* 0 when a click or Command-Tab came after the last command
    IF h = <<>> THEN 0
    ELSE IF h[Len(h)] < 0 THEN 0
    ELSE h[Len(h)]

HonorsLastCommand == Quiescent /\ LastCommand(history) # 0 => s.active = LastCommand(history)

\* A click or Command-Tab after the last command wins, unless it makes no claim.
HonorsLastActivation == Quiescent /\ s.lastWin # "" => s.focus = s.lastWin

\* Windows of two workspaces are never visible together.
NoMixedFrame == \E k \in Workspaces : Visible \subseteq WsWins(k)

\* The screen is never empty while the workspace WindowServer last revealed has windows.
NoBlankFrame == Visible = {} => WsWins(s.shown) = {}

\* Every hidden window can be found from the published record.
RecoveryPath == \A w \in Win : s.hidden[w] => s.recorded

Settles == []<>Quiescent

(***************************************************************************)
(* State view: generations are only compared with the current one.         *)
(***************************************************************************)
Cur(g, c) == g # 0 /\ g = c
ViewQ(q, c) == [n \in 1..Len(q) |-> [q[n] EXCEPT !.g = Cur(q[n].g, c)]]
StateView == <<[s EXCEPT !.sw = 0, !.gen = 0,
                         !.mq = ViewQ(s.mq, s.sw), !.bq = ViewQ(s.bq, s.sw), !.fq = ViewQ(s.fq, s.gen),
                         !.wq = [a \in Apps |-> ViewQ(s.wq[a], s.gen)]],
               history>>

TraceView == [history |-> history, active |-> s.active, focus |-> s.focus,
              osFocus |-> s.osFocus, visible |-> Visible, sw |-> s.sw, gen |-> s.gen,
              mq |-> [n \in 1..Len(s.mq) |-> s.mq[n].kind],
              bq |-> [n \in 1..Len(s.bq) |-> s.bq[n].op],
              fq |-> s.fq, expect |-> s.expect, evs |-> s.evs, seen |-> s.seen,
              afocus |-> s.afocus, atop |-> s.atop, fcur |-> s.fcur, wq |-> s.wq, kr |-> s.kr]
=============================================================================
