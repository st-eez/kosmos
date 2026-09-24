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
(* window change to the main actor later. Kosmos records the focus it      *)
(* performs. An echo is a report of a requested window received after the  *)
(* request; key changes carry a sequence number (`i`) for that.            *)
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
(* The key window can leave: it closes or minimizes, or its app hides.     *)
(* macOS keys another window at once, possibly a hidden one. That report   *)
(* is not Command-Tab: the window key before it has left the screen, which *)
(* Kosmos reads from WindowServer when the report arrives. Kosmos keeps    *)
(* its workspace and focuses it again. The departure reaches Kosmos        *)
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
    AllowFallback,  \* macOS may re-key when the key window is hidden (not observed)
    AllowLeave,     \* the key window may close or minimize, or its app hide
    AllowReturn,    \* a window that left without closing may return
    FollowRekeys,   \* Kosmos follows a re-key onto a hidden window (the behaviour before this rule)
    FollowStale,    \* Kosmos follows a return received before the latest command (the behaviour before this rule)
    RevealFirst,    \* a switch reveals the incoming windows before concealing the outgoing
    Coalesce        \* a resumed command does not focus while a newer command is queued

ASSUME RevealFirst \in BOOLEAN /\ Coalesce \in BOOLEAN /\ AllowLeave \in BOOLEAN /\ FollowRekeys \in BOOLEAN
ASSUME AllowReturn \in BOOLEAN /\ FollowStale \in BOOLEAN

NoWin == "none"   \* no key window: Finder fronted without windows
AppOfX(w) == IF w = NoWin THEN "finder" ELSE AppOf[w]
WsWins(k) == {w \in Win : WsOf[w] = k}

VARIABLES
    s,        \* the state record
    history   \* user inputs: k = `workspace k`, -1 = click, -2 = Command-Tab, -3 = key window leaves,
              \* -4 = a window returns

vars == <<s, history>>

Job(kind, ws, g, evs, t) == [kind |-> kind, ws |-> ws, g |-> g, evs |-> evs, t |-> t]
Op(op, k, g) == [op |-> op, k |-> k, g |-> g]   \* k: workspace revealed, or kept visible by a conceal
FocusOp(w, g) == [w |-> w, g |-> g]

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
               ne       |-> 0,        \* key changes so far
               shown    |-> 1,        \* WindowServer: workspace of the last executed reveal
               lastCmdT |-> 0,        \* input position of the latest executed command
               lastWin  |-> "",       \* ghost: target of the latest input if it was a click or Command-Tab
               goal     |-> 1,        \* ghost: the workspace the user last asked for
               mq       |-> <<>>,
               bq       |-> <<>>,
               fq       |-> <<>>,
               evs      |-> <<>>,     \* key window changes not yet reported
               expect   |-> <<>>,     \* performed focus requests not yet reported
               gone     |-> {},       \* WindowServer: closed, minimized or hidden with their app
               closed   |-> {},       \* WindowServer: the gone windows that closed and never return
               left     |-> {},       \* Kosmos: departures it has handled
               refocus  |-> FALSE,    \* Kosmos: a re-assert found its focus gone; its departure focuses
               notices  |-> <<>> ]    \* departures and returns not yet reported: [w, closed, back, t]
    /\ history = <<>>

Visible == {w \in Win : ~s.hidden[w] /\ w \notin s.gone}

RECURSIVE SeqOf(_)
SeqOf(S) == IF S = {} THEN <<>> ELSE LET x == CHOOSE x \in S : TRUE IN <<x>> \o SeqOf(S \ {x})

(***************************************************************************)
(* macOS                                                                   *)
(***************************************************************************)
\* `at` is the input position when the key window changed.
KeyChange(t, w, at) ==
    IF t.osFocus = w THEN t
    ELSE [t EXCEPT !.osFocus = w,
                   !.ne = t.ne + 1,
                   !.evs = Append(@, [w |-> w, act |-> AppOfX(t.osFocus) # AppOfX(w), t |-> at, i |-> t.ne + 1,
                                      hid |-> w # NoWin /\ t.hidden[w], prev |-> t.osFocus])]

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

\* Kosmos asks the focus queue for w, unless w left the screen: fronting it
\* would unminimize it or unhide its app. Its departure focuses instead.
RequestFocus(t, w, g) ==
    IF w # NoWin /\ w \in t.gone THEN [t EXCEPT !.refocus = TRUE]
    ELSE [t EXCEPT !.refocus = FALSE, !.fq = Append(@, FocusOp(w, g))]

RunCommand(t, x) ==
    LET t1 == [t EXCEPT !.lastCmdT = x.t]
    IN IF x.ws = t.active THEN t1 ELSE StartSwitch(t1, x.ws, t1.mru[x.ws])

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
KeyLeft(t, ev) == ev.prev # NoWin /\ ev.prev \in t.gone

\* A user activation is adopted. Within the visible workspace it becomes the
\* focus intent, and is focused again in case a stale request of ours landed
\* after it. On a hidden workspace Kosmos follows it there, unless macOS keyed
\* it because the key window left.
Adopt(t, ev) ==
    LET w == ev.w
    IN IF ev.t < t.lastCmdT THEN Reassert(t)   \* happened before the latest command
       ELSE IF w = NoWin THEN IF KeyLeft(t, ev) THEN Reassert(t) ELSE t
       ELSE IF w \in t.left THEN t   \* a window that left is no one's focus
       ELSE IF WsOf[w] = t.active
            THEN RequestFocus([t EXCEPT !.focus = w, !.mru[t.active] = w, !.gen = t.gen + 1], w, t.gen + 1)
       ELSE IF ev.hid /\ (FollowRekeys \/ ~KeyLeft(t, ev)) THEN StartSwitch(t, WsOf[w], w)
       ELSE Reassert(t)   \* visible mid-switch, or a re-key after the key window left

RECURSIVE Observe(_, _)
Observe(t, evs) ==
    IF evs = <<>> THEN t
    ELSE LET ev == Head(evs)
             ks == {k \in 1..Len(t.expect) : Matches(ev, t.expect[k])}
             t1 == IF ks # {}
                   THEN LET k == CHOOSE k \in ks : \A j \in ks : k <= j
                        IN [t EXCEPT !.expect = SubSeq(@, k + 1, Len(@))]
                   ELSE Adopt(t, ev)
         IN Observe(t1, Tail(evs))

\* Kosmos learns that w left, and it leaves the model. When it was the focus,
\* the workspace's next window, or Finder on an empty workspace, becomes the
\* focus. That is focused at once for a closed window, as before, and for a
\* minimized or hidden one only if a re-assert found it gone: otherwise
\* macOS's own key change is still on its way, and focusing first could put
\* Kosmos's echo between the departure and that report.
NextWin(k, left) == IF WsWins(k) \ left = {} THEN NoWin ELSE CHOOSE v \in WsWins(k) \ left : TRUE
Depart(t, x) ==
    LET w == x.w
        left == t.left \cup {w}
        t1 == [t EXCEPT !.left = left,
                        !.mru[WsOf[w]] = IF @ = w THEN NextWin(WsOf[w], left) ELSE @]
        t2 == [t1 EXCEPT !.focus = t1.mru[t.active], !.gen = t.gen + 1]
    IN IF t.focus # w THEN t1
       ELSE IF x.closed \/ t.refocus THEN Reassert([t2 EXCEPT !.refocus = FALSE])
       ELSE t2

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

\* Switches leave out the windows Kosmos knows left: a returning window comes
\* back concealed only if Kosmos concealed it before it left.
ExecBridge ==
    LET x == Head(s.bq)
        t == [s EXCEPT !.bq = Tail(@)]
    IN /\ s.bq # <<>>
       /\ s' = CASE x.op = "reveal"  -> [t EXCEPT !.hidden = [w \in Win |-> IF WsOf[w] = x.k /\ w \notin t.left
                                                                        THEN FALSE ELSE @[w]],
                                                 !.shown = x.k]
                 [] x.op = "conceal" -> [t EXCEPT !.hidden = [w \in Win |-> IF WsOf[w] # x.k /\ w \notin t.left
                                                                        THEN TRUE ELSE @[w]]]
                 [] x.op = "barrier" -> [t EXCEPT !.mq = Append(@, Job("resume", 0, x.g, <<>>, 0))]
       /\ UNCHANGED history

\* The focus queue checks the generation before each call. It never names a
\* hidden window or one that left, which would unminimize it or unhide its
\* app, and skips the call when the target is already key.
ExecFocus ==
    LET x == Head(s.fq)
        t == [s EXCEPT !.fq = Tail(@)]
    IN /\ s.fq # <<>>
       /\ s' = IF x.g # s.gen \/ s.osFocus = x.w \/ (x.w # NoWin /\ (s.hidden[x.w] \/ x.w \in s.gone)) THEN t
               ELSE KeyChange([t EXCEPT !.expect = Append(@, [w |-> x.w, i |-> t.ne + 1])], x.w, Len(history))
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

\* A return Kosmos has not handled yet. The model leaves out clicks and
\* Command-Tab until it has: Kosmos would follow the return after them.
Returning == \/ \E n \in 1..Len(s.notices) : s.notices[n].back
             \/ \E n \in 1..Len(s.mq) : s.mq[n].kind = "notice" /\ \E m \in 1..Len(s.mq[n].evs) : s.mq[n].evs[m].back

Click ==
    /\ AllowClicks
    /\ ~Returning
    /\ Len(history) < MaxEvents
    /\ \E w \in Visible \ {s.osFocus} :
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = Claim(w)]
         /\ history' = Append(history, -1)

CmdTab ==
    /\ AllowCmdTab
    /\ ~Returning
    /\ Len(history) < MaxEvents
    /\ \E w \in Win \ s.gone :
         /\ AppOf[w] # AppOfX(s.osFocus)
         /\ s' = [KeyChange(s, w, Len(history) + 1) EXCEPT !.lastWin = Claim(w), !.goal = Goal(w)]
         /\ history' = Append(history, -2)

\* The user closes, minimizes or hides a window after seeing it key, and brings
\* one back after seeing it leave. Kosmos has had the reports before by then:
\* it handles one in milliseconds. macOS keys the next window as a window
\* finishes leaving, before the user can bring it back.
Seen == s.evs = <<>> /\ \A n \in 1..Len(s.mq) : s.mq[n].kind # "report"

\* The key window closes or minimizes, or its app hides with all its windows.
\* macOS keys another window at once, which may be hidden, or none. The
\* departure and the new key window still reach Kosmos in either order.
AppWins(w) == {v \in Win : AppOf[v] = AppOf[w]}
Leave ==
    /\ AllowLeave
    /\ Len(history) < MaxEvents
    /\ s.osFocus # NoWin
    /\ Seen
    /\ \E out \in {{s.osFocus}, AppWins(s.osFocus) \ s.gone}, closed \in BOOLEAN :
       /\ closed => out = {s.osFocus}   \* a window closes alone; an app hides together
       /\ \E v \in (Win \ (s.gone \cup out)) \cup {NoWin} :
            LET q == SeqOf(out)
                notices == [n \in 1..Len(q) |-> [w |-> q[n], closed |-> closed, back |-> FALSE, t |-> 0]]
            IN /\ s' = KeyChange([s EXCEPT !.gone = @ \cup out, !.closed = IF closed THEN @ \cup out ELSE @,
                                           !.notices = @ \o notices, !.lastWin = ""],
                                 v, Len(history) + 1)
               /\ history' = Append(history, -3)

\* A window that left returns where it was, and macOS keys it: the user
\* unminimizes it, unhides its app, or takes it out of native fullscreen.
Return ==
    /\ AllowReturn
    /\ Len(history) < MaxEvents
    /\ Seen
    /\ \E w \in s.gone \ s.closed :
         /\ s' = KeyChange([s EXCEPT !.gone = @ \ {w}, !.lastWin = w, !.goal = WsOf[w],
                                     !.notices = Append(@, [w |-> w, closed |-> FALSE, back |-> TRUE,
                                                            t |-> Len(history) + 1])],
                           w, Len(history) + 1)
         /\ history' = Append(history, -4)

Internal == ExecMain \/ ExecBridge \/ ExecFocus \/ PostReports \/ PostNotices

Next == Internal \/ Fallback \/ Command \/ Click \/ CmdTab \/ Leave \/ Return

Spec == Init /\ [][Next]_vars /\ WF_vars(ExecMain) /\ WF_vars(ExecBridge)
                              /\ WF_vars(ExecFocus) /\ WF_vars(PostReports) /\ WF_vars(PostNotices)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
Quiescent == s.mq = <<>> /\ s.bq = <<>> /\ s.fq = <<>> /\ s.evs = <<>> /\ s.notices = <<>>

\* The screen shows Kosmos's workspace and macOS keys Kosmos's focus.
Converged == Visible = WsWins(s.active) \ s.gone /\ s.osFocus = s.focus

ConvergesWhenQuiet == Quiescent => Converged

RECURSIVE LastCommand(_)
LastCommand(h) ==   \* 0 when another input came after the last command
    IF h = <<>> THEN 0
    ELSE IF h[Len(h)] < 0 THEN 0
    ELSE h[Len(h)]

HonorsLastCommand == Quiescent /\ LastCommand(history) # 0 => s.active = LastCommand(history)

\* A click, Command-Tab or return after the last command wins, unless it makes
\* no claim.
HonorsLastActivation == Quiescent /\ s.lastWin # "" => s.focus = s.lastWin

\* When the key window leaves, Kosmos stays on the workspace the user was on.
KeepsWorkspaceAfterLeave == Quiescent /\ history # <<>> /\ history[Len(history)] = -3 => s.active = s.goal

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
                         !.mq = ViewQ(s.mq, s.sw), !.bq = ViewQ(s.bq, s.sw), !.fq = ViewQ(s.fq, s.gen)],
               history>>

TraceView == [history |-> history, active |-> s.active, focus |-> s.focus,
              osFocus |-> s.osFocus, visible |-> Visible, gone |-> s.gone, left |-> s.left,
              notices |-> s.notices,
              sw |-> s.sw, gen |-> s.gen,
              mq |-> [n \in 1..Len(s.mq) |-> s.mq[n].kind],
              bq |-> [n \in 1..Len(s.bq) |-> s.bq[n].op],
              fq |-> s.fq, expect |-> s.expect, evs |-> s.evs]
=============================================================================
