------------------------------- MODULE Kosmos -------------------------------
(***************************************************************************)
(* Kosmos's workspace switch (docs/overview.md, section 4.3, and           *)
(* docs/focus.md) at the level of its queues:                              *)
(*                                                                         *)
(*   mq  the main actor's jobs: commands, barrier resumptions, observer    *)
(*       reports. A job runs to completion.                                *)
(*   bq  the bridge queue: reveal and conceal operations on the holding    *)
(*       Space, and the barrier read that resumes the command.             *)
(*   fq  the focus queue: front a window, or key Kosmos's own window with  *)
(*       no workspace window for an empty workspace. Each request carries  *)
(*       its generation and is dropped when a newer intent exists.         *)
(*                                                                         *)
(* macOS keys the window it is asked to, and reports every key window      *)
(* change to the main actor later. Kosmos records the focus it performs.   *)
(* An echo is a report of a requested window received after the request;   *)
(* key changes carry a sequence number (`i`) for that.                     *)
(*                                                                         *)
(* Focus follows mouse: when the pointer rests in a window WindowServer    *)
(* shows, Kosmos focuses it if it is a window of a workspace Kosmos shows. *)
(* A hover focus counts as a command.                                      *)
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
(* workspace's next window, or Kosmos's own window. A closed focus is      *)
(* replaced at once.                                                       *)
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
(*                                                                         *)
(* With SplitQueue, a focus request runs as the steps the implementation   *)
(* takes. The queue reads whether the target's app is front and hands the  *)
(* app's worker a job, and waits for it, or for BusyApp may give up after  *)
(* its 30 ms timeout. For a front app the worker skips a stale request or  *)
(* a window key already, then records and raises the window, which keys it *)
(* (RaiseKeys); the app performs the raise later (WorkerLand). For a       *)
(* background app the worker's job only orders the request behind the      *)
(* app's earlier jobs; the queue records and posts the key record, which   *)
(* activates the app with the window but leaves it where it sits in the    *)
(* app's stacking order, and then the worker raises it (PostRaise). With   *)
(* KeyOldFirst the app can first key its last key window, while that is    *)
(* still its focused window, and the named one a step later, as Preview    *)
(* and Ghostty did live. Each side records the echo only right before its  *)
(* own call that changes the key window. The raise after the key record    *)
(* changes it only when the user keyed another window of the app first, so *)
(* its record goes once the worker has seen the raise done                 *)
(* (PostRaiseEcho). Reports come as the implementation takes them. An      *)
(* app's focus notification reaches its observer callback some time after  *)
(* the change (NoteDelay). The activation read runs on the app's worker,   *)
(* queued when the main thread notices the activation, also some time      *)
(* after it happens (NoticeDelay), and reads whatever window the app has   *)
(* by then. Each report is stamped, and checked against the front app and  *)
(* the hidden windows, when its callback or notice runs. Both run before   *)
(* the user's next input, and an app's callbacks run before its activation *)
(* read. Kosmos follows either into another workspace when its window was  *)
(* hidden at its stamp (NoteFollows): a notification reports a window      *)
(* opened inside the front app. A notification from an app Kosmos          *)
(* activated waits for that activation's read (HoldNotes), and a notice    *)
(* records that its app had already lost the front to Kosmos's activation  *)
(* (NoticeCheck). A background app can change its own focused window       *)
(* (AllowBackground, and a raise landing there, which it reports:          *)
(* RaiseReports). While no window is key after a departure, the app whose  *)
(* window closed or minimized stays front, and the departure is evidence   *)
(* that the next key change is macOS's own for a second, which passes once *)
(* Kosmos has every report (Age). ActFrontCheck, LateNoteCheck,            *)
(* RaiseTimeout, BackgroundRaise, ReadsByWindow and SplitRules = "d1be665" *)
(* each run a rule the implementation had, and turning off HoldNotes,      *)
(* NoticeCheck, NoteFollows or PostRaise, on ReassertTakes, or             *)
(* PostRaiseEcho other than "done", a rule the spec had, for configs that  *)
(* fail as expected.                                                       *)
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
    AllowHover,     \* the pointer may rest in a visible window (focus follows mouse)
    AllowFallback,  \* macOS may re-key when the key window is hidden (not observed)
    AllowLeave,     \* the key window may close or minimize, or its app hide
    AllowMiss,      \* fronting another window of the key app may leave its key window, once
    AllowQuiet,     \* a departure may leave no key window and no report of one
    AllowLate,      \* macOS may key the next window after Kosmos hears of the departure, as after a minimize
    AllowReturn,    \* a window that left without closing may return
    AllowBackground,\* a background app may change its own focused window without coming front
    FollowRekeys,   \* Kosmos follows a re-key onto a hidden window (the behaviour before this rule)
    FollowStale,    \* Kosmos follows a return received before the latest command (the behaviour before this rule)
    Grace,          \* Kosmos holds a report until it knows whether the key window before it left
    MissRule,       \* Kosmos takes a repeat of a hidden key window during its request to that app for a miss
    AdoptShown,     \* Kosmos adopts a window of any shown workspace, where it adopted the focused workspace's alone
    WaitBound,      \* a departure's wait for macOS's report of the next key window has a bound
    RevealFirst,    \* a switch reveals the incoming windows before concealing the outgoing
    Coalesce,       \* a resumed command does not focus while a newer command is queued
    SplitQueue,     \* a focus request runs as the focus queue's and the app worker's steps
    BusyApp,        \* with SplitQueue, the app whose worker can outlast the queue's wait
    RaiseReports,   \* with SplitQueue, raising a background app's window makes it report a
                    \* focus change (measured: `kosmos-probe keying`)
    RaiseKeys,      \* with SplitQueue, AXRaise alone keys a window inside the front app
                    \* (measured); otherwise the key record after the raise does
    SplitRules,     \* with SplitQueue, "record-at-call" (the design) or "d1be665" (robust
                    \* at d1be665, for comparison)
    ActFrontCheck,  \* with SplitQueue, the activation read reports only while its app is
                    \* front (robust at e7539e9)
    BackgroundRaise,\* with SplitQueue, the worker raises a window of a background app before
                    \* the queue's key record
    LateNoteCheck,  \* with SplitQueue, an app's focus notification is checked against the
                    \* front app when its worker delivers it, not when the app sends it
    RaiseTimeout,   \* with SplitQueue, the worker stops waiting for a busy app's AXRaise,
                    \* which still lands later
    NoteDelay,      \* with SplitQueue, an app's focus notification reaches its observer
                    \* callback after the change, and is stamped and checked there
    NoticeDelay,    \* with SplitQueue, the main thread notices an app's activation after it
                    \* happens, and stamps it and queues the activation read then
    HoldNotes,      \* with SplitQueue, a notification from an app Kosmos activated waits for
                    \* that activation's read
    NoticeCheck,    \* with SplitQueue, the main thread notes when an activation it notices
                    \* has already lost the front to Kosmos's
    NoteFollows,    \* with SplitQueue, a focus notification of a window hidden at its stamp is
                    \* followed, as an activation read is
    ReassertTakes,  \* with SplitQueue, a report Kosmos reasserts over counts as the last one
                    \* taken for the user's
    PostRaise,      \* with SplitQueue, the worker raises a background app's window after the
                    \* queue's key record, once the app is front
    PostRaiseEcho,  \* with SplitQueue, the echo that raise leaves: "none"; "kept", recorded just
                    \* before it until a report matches it; or "done", recorded just before it
                    \* until the worker has seen the raise done
    KeyOldFirst,    \* with SplitQueue, a key record can activate a background app with the window
                    \* key when the app was last front, while that is still its focused window, and
                    \* key the named window a step later (live)
    ReadsByWindow   \* with SplitQueue, an activation read matches a record of the window it
                    \* reads, as a notification does (the implementation before change 25)

ASSUME RevealFirst \in BOOLEAN /\ Coalesce \in BOOLEAN /\ AllowLeave \in BOOLEAN /\ FollowRekeys \in BOOLEAN
ASSUME AllowReturn \in BOOLEAN /\ FollowStale \in BOOLEAN /\ Grace \in BOOLEAN
ASSUME AllowMiss \in BOOLEAN /\ MissRule \in BOOLEAN /\ AllowQuiet \in BOOLEAN /\ WaitBound \in BOOLEAN
ASSUME AllowOpen \in BOOLEAN /\ AllowLate \in BOOLEAN /\ AdoptShown \in BOOLEAN /\ AllowHover \in BOOLEAN
ASSUME SplitQueue \in BOOLEAN /\ RaiseReports \in BOOLEAN /\ RaiseKeys \in BOOLEAN
ASSUME SplitRules \in {"record-at-call", "d1be665"} /\ AllowBackground \in BOOLEAN /\ ActFrontCheck \in BOOLEAN
ASSUME BackgroundRaise \in BOOLEAN /\ LateNoteCheck \in BOOLEAN /\ RaiseTimeout \in BOOLEAN
ASSUME NoteDelay \in BOOLEAN /\ NoticeDelay \in BOOLEAN /\ HoldNotes \in BOOLEAN /\ NoticeCheck \in BOOLEAN
ASSUME NoteFollows \in BOOLEAN /\ ReassertTakes \in BOOLEAN /\ PostRaise \in BOOLEAN
ASSUME PostRaiseEcho \in {"none", "kept", "done"} /\ KeyOldFirst \in BOOLEAN /\ ReadsByWindow \in BOOLEAN

\* No workspace window is key: Kosmos keyed its own window for an empty workspace, or macOS
\* left no key window after a departure. Both report no window.
NoWin == "none"
AppOfX(w) == IF w = NoWin THEN "kosmos" ELSE AppOf[w]
\* The front process. With no window key it is Kosmos, or with SplitQueue the app whose key
\* window left while it stayed front.
FrontApp(t) == IF t.osFocus = NoWin THEN t.bare ELSE AppOf[t.osFocus]
WsWins(k) == {w \in Win : WsOf[w] = k}
Apps == {AppOf[w] : w \in Win}
NoReq == [r |-> 0]
NoEv == [w |-> ""]
Displays == {DisplayOf[k] : k \in Workspaces}
\* The first workspace of each display is shown initially.
InitShown == [d \in Displays |-> CHOOSE k \in Workspaces : DisplayOf[k] = d /\ \A j \in Workspaces : DisplayOf[j] = d => k <= j]
Shown(t) == {t.onDisplay[d] : d \in Displays}
ShownWins(t) == UNION {WsWins(k) : k \in Shown(t)}

VARIABLES
    s,        \* the state record
    history   \* user inputs: k = `workspace k`, -1 = click, -2 = Command-Tab, -3 = key window leaves,
              \* -4 = a window returns, -5 = a hidden window opened, -6 = hover,
              \* -7 = a background app's focused window changed

vars == <<s, history>>

\* `ws` holds the window for a hover job.
Job(kind, ws, g, evs, t) == [kind |-> kind, ws |-> ws, g |-> g, evs |-> evs, t |-> t]
\* k: the workspace each display shows once the switch is done, which a reveal
\* shows and a conceal keeps visible. skip: the windows Kosmos knew had left when
\* it planned the switch, which it leaves out.
Op(op, k, g, skip) == [op |-> op, k |-> k, g |-> g, skip |-> skip]
\* c: with SplitQueue, the window was concealed when Kosmos requested it.
FocusOp(w, g, c) == [w |-> w, g |-> g, c |-> c]

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
               bare     |-> "kosmos", \* macOS: the front process while no window is key
               ne       |-> 0,        \* key changes so far
               shown    |-> InitShown, \* WindowServer: the workspaces of the last executed reveal
               lastCmdT |-> 0,        \* input position of the latest executed command
               lastWin  |-> {},       \* ghost: the windows the latest input claims if it was a click, Command-Tab, return or hover
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
               seenPrev |-> NoWin,    \* Kosmos: the key window before it (SplitQueue)
               missed   |-> FALSE,    \* macOS: a focus request already missed
               waiting  |-> NoWin,    \* Kosmos: a departure waits for macOS's report after this key window
               rekey    |-> <<>>,     \* macOS: the key change it makes when a departure's animation ends: [w, t]
               notices  |-> <<>>,     \* departures and returns not yet reported: [w, closed, back, t]
               \* SplitQueue only:
               afocus   |-> [a \in Apps |-> IF AppOf[f] = a THEN f ELSE CHOOSE w \in Win : AppOf[w] = a],
                                      \* each app's own focused window, its key window while front
               atop     |-> [a \in Apps |-> IF AppOf[f] = a THEN f ELSE CHOOSE w \in Win : AppOf[w] = a],
                                      \* each app's frontmost window
               fcur     |-> NoReq,    \* the request the focus queue is running
               wq       |-> [a \in Apps |-> <<>>],   \* each app worker's jobs
               kr       |-> <<>>,     \* KeyRequest phase by request number
               late     |-> [a \in Apps |-> <<>>],   \* raises a busy app will still land
               nq       |-> [a \in Apps |-> <<>>],   \* each app's notifications its observer callback
                                                     \* has not run for yet (NoteDelay)
               an       |-> <<>>,     \* activations the main thread has not noticed yet (NoticeDelay)
               clk      |-> 0,        \* stamps for records and report deliveries
               lastRep  |-> -1,       \* stamp of the last report taken for the user's
               kact     |-> -1,       \* stamp of Kosmos's latest activation record
               jdone    |-> {},       \* requests whose worker job has finished
               noteHeld |-> [a \in Apps |-> NoEv],   \* Kosmos: a notification waiting for its
                                                     \* app's activation read (HoldNotes)
               lastAmb  |-> FALSE,    \* ghost: the activation read of the latest input found another window
               lastLost |-> FALSE,    \* ghost: the notification of the latest input's change inside the
                                      \* front app ran after its app lost the front
               lastMis  |-> FALSE,    \* ghost: a switch changed whether the window of a user's
                                      \* change was hidden before its notice or callback ran,
                                      \* and Kosmos has not settled since
               aged     |-> {},       \* Kosmos: departures older than its second of evidence
               lastEarly |-> FALSE,   \* ghost: the latest input came within that second of a
                                      \* departure of the key window Kosmos last heard of
               lastRaced |-> FALSE,   \* ghost: the user keyed a window of an app whose raise
                                      \* Kosmos decided and the app has not performed
               named    |-> [a \in Apps |-> NoWin],   \* macOS: the window a key record named, which
                                                     \* its app keys after its own (KeyOldFirst)
               lastKey  |-> [a \in Apps |-> IF AppOf[f] = a THEN f ELSE CHOOSE w \in Win : AppOf[w] = a],
                                      \* macOS: each app's window key when it was last front,
                                      \* which a key record activates it with (KeyOldFirst)
               lowTop   |-> {} ]      \* ghost: apps whose raise after a key record found the app
                                      \* not yet keying the named window, until one of their
                                      \* windows comes to their front
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
\* With SplitQueue a key change is reported by the app's focused window notification, if
\* that window changed, and by the activation read, if the app came front
\* (Apps.activated), which runs on the app's worker. The notification is stamped and
\* checked against the front app when it is sent, or with NoteDelay when its observer
\* callback runs (ObserverPost), on a thread that never waits on an app; with LateNoteCheck
\* it waits behind the worker's jobs as the activation read does, and is stamped and
\* checked when the worker delivers it. `hs` keeps which windows were hidden when the
\* activation was noticed: whether the window the read finds was hidden then is judged by
\* the report's stamp. A split report's `prev` is set when Kosmos classifies it, as the
\* key window Kosmos last heard of.
Item(st, w, at, ts) == [r |-> 0, w |-> w, g |-> 0, front |-> FALSE, st |-> st, t |-> at, ts |-> ts, bg |-> FALSE,
                        hs |-> [v \in Win |-> FALSE], ko |-> FALSE]
Ev(w, act, at, i, hid, prev, bg, ts, ko) ==
    [w |-> w, act |-> act, t |-> at, i |-> i, hid |-> hid, prev |-> prev, bg |-> bg, ts |-> ts, ko |-> ko]
\* `o` says where the change came from, for the ghosts: a background app's own change
\* (`bg`), a user's input (`user`), and a change inside the front app, which no activation
\* read reports (`lone`).
Note(t, w, at, o) ==
    IF LateNoteCheck
    THEN [t EXCEPT !.wq[AppOf[w]] = Append(@, Item("note", w, at, 0))]
    ELSE IF NoteDelay
    THEN [t EXCEPT !.nq[AppOf[w]] = Append(@, [w |-> w, t |-> at, o |-> o, ehid |-> t.hidden[w], lost |-> FALSE])]
    ELSE [t EXCEPT !.evs = Append(@, Ev(w, FALSE, at, 0, t.hidden[w], NoWin, o.bg, t.clk, FALSE)),
                   !.clk = t.clk + 1]
\* When the main thread notices an activation, the app has already lost the front to an
\* activation Kosmos recorded (NoticeCheck).
Overtaken(t, a) ==
    /\ NoticeCheck /\ FrontApp(t) # a
    /\ \E k \in 1..Len(t.expect) : t.expect[k].kind = "act" /\ AppOfX(t.expect[k].w) = FrontApp(t)
\* The main thread notices the activation (Apps.activated), stamps it, and queues the read
\* on the app's worker.
ActItem(t, a, w, at) ==
    [t EXCEPT !.wq[a] = Append(@, [Item("act", w, at, t.clk) EXCEPT !.hs = t.hidden, !.ko = Overtaken(t, a)]),
              !.clk = t.clk + 1]
Notice(t, a, w, at, user) ==
    IF NoticeDelay THEN [t EXCEPT !.an = Append(@, [a |-> a, w |-> w, t |-> at, user |-> user,
                                                    ehid |-> w # NoWin /\ t.hidden[w]])]
    ELSE ActItem(t, a, w, at)
KeyChangeBy(t, w, at, user) ==
    IF t.osFocus = w THEN t
    ELSE LET a == AppOfX(w)
             activated == FrontApp(t) # a
             \* ghost: the app that loses the front has changes whose callbacks have not run
             lose == {b \in Apps : activated /\ b = FrontApp(t)}
             u == [t EXCEPT !.osFocus = w, !.bare = "kosmos", !.rekey = <<>>, !.ne = t.ne + 1,
                            !.afocus = IF ~SplitQueue \/ w = NoWin THEN @ ELSE [@ EXCEPT ![a] = w],
                            !.lastKey = IF KeyOldFirst /\ w # NoWin THEN [@ EXCEPT ![a] = w] ELSE @,
                            !.nq = [b \in Apps |-> IF b \in lose
                                                   THEN [n \in 1..Len(t.nq[b]) |-> [t.nq[b][n] EXCEPT !.lost = TRUE]]
                                                   ELSE t.nq[b]]]
         IN IF ~SplitQueue \/ (w = NoWin /\ ~NoticeDelay)
            THEN [u EXCEPT !.evs = Append(@, Ev(w, activated, at, t.ne + 1, w # NoWin /\ t.hidden[w],
                                                t.osFocus, FALSE, t.clk, FALSE)),
                           !.clk = IF SplitQueue THEN t.clk + 1 ELSE @]
            ELSE IF w = NoWin THEN Notice(u, a, w, at, user)
            ELSE LET v == IF t.afocus[a] # w THEN Note(u, w, at, [bg |-> FALSE, user |-> user, lone |-> ~activated])
                          ELSE u
                 IN IF activated THEN Notice(v, a, w, at, user) ELSE v
KeyChange(t, w, at) == KeyChangeBy(t, w, at, FALSE)

\* macOS keys a window it chose, or the user keyed: that window is the front of its app.
Top(t, w) == IF SplitQueue /\ w # NoWin THEN [t EXCEPT !.atop[AppOf[w]] = w, !.lowTop = @ \ {AppOf[w]}] ELSE t

\* A background app's own focused window changes, and the app reports it as a focus
\* change although the key window stays where it is.
BackgroundFocus(t, w, at) ==
    Note([t EXCEPT !.afocus[AppOf[w]] = w, !.ne = t.ne + 1], w, at, [bg |-> TRUE, user |-> FALSE, lone |-> FALSE])

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
    ELSE [t EXCEPT !.fq = Append(@, FocusOp(w, g, SplitQueue /\ w # NoWin /\ t.hidden[w]))]

\* The main actor records the echo of a call about to be made (Controller.performing); `r`
\* names the request, so d1be665's drop can forget it. A call for a window of the front app
\* changes it inside the app, reported by the app's notification (`note`); any other
\* activates its app, reported by the activation read (`act`).
Record(t, w, r) ==
    LET kind == IF w # NoWin /\ FrontApp(t) = AppOf[w] THEN "note" ELSE "act"
    IN [t EXCEPT !.expect = Append(@, [w |-> w, i |-> t.ne + 1, r |-> r, ts |-> t.clk, kind |-> kind]),
                 !.kact = IF kind = "act" THEN t.clk ELSE @,
                 !.clk = t.clk + 1]
ForgetIf(t, P(_)) ==
    LET ks == {k \in 1..Len(t.expect) : P(t.expect[k])}
    IN IF ks = {} THEN t
       ELSE LET k == CHOOSE k \in ks : TRUE
            IN [t EXCEPT !.expect = SubSeq(@, 1, k - 1) \o SubSeq(@, k + 1, Len(@))]
Forget(t, r) == LET P(x) == x.r = r IN ForgetIf(t, P)

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
\* With SplitQueue a report is stamped when its callback or notice runs, as the
\* implementation stamps it, and matches a record taken before that; otherwise by the key
\* change's index. An activation read reports whatever window the app has by then, so with
\* SplitQueue it is the echo of the activation Kosmos recorded for that app, whichever
\* window it names: Kosmos records an activation only just before making it. It is never
\* the echo of a change inside the front app. With ReadsByWindow it matches as a
\* notification does.
Matches(ev, x) ==
    IF ~SplitQueue THEN x.w = ev.w /\ ev.i >= x.i
    ELSE IF ev.act /\ ~ReadsByWindow THEN x.kind = "act" /\ AppOfX(x.w) = AppOfX(ev.w) /\ ev.ts > x.ts
    ELSE x.w = ev.w /\ ev.ts > x.ts

\* A stale report: focus the current intent again. If a switch is in flight,
\* this request is dropped while the target is hidden and the resume focuses.
Reassert(t) == RequestFocus(t, t.focus, t.gen)

\* The window key before this change has left the screen: macOS re-keyed after
\* it closed, minimized or hid, and the user did not choose this window. With
\* SplitQueue that is the key window Kosmos last heard of, and the departure counts
\* for a second (Age).
KeyLeft(t, ev) == ev.prev # NoWin /\ ev.prev \in Known(t) \ t.aged

\* The window key before this change is not known to have left, but it may be
\* leaving: WindowServer can report it on screen after macOS keyed the next
\* window. Concealing a window leaves it ordered in, so a window Kosmos
\* concealed can be leaving too.
Undecided(t, ev) == ev.prev \notin {NoWin, ev.w} /\ ~KeyLeft(t, ev)

\* A miss of Kosmos's own request: the app of a window Kosmos asked for kept
\* its key window and reports it again, while that request awaits its echo.
MissedBy(ev, x) == x.w # ev.w /\ AppOfX(x.w) = AppOfX(ev.w)
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
\* With SplitQueue, a report Kosmos adopts or follows is the last one taken for the
\* user's (with ReassertTakes, so is one it reasserts over). A focus notification of a
\* window hidden at its stamp follows as an activation read does: the user opened a hidden
\* window of the front app. Without NoteFollows only an activation read follows.
Hold(t, ev) == [t EXCEPT !.held = <<ev>>]
Adopt(t, ev, final, miss) ==
    LET w == ev.w
        wait == Grace /\ ~final /\ Undecided(t, ev)
        t0 == IF SplitQueue /\ ReassertTakes THEN [t EXCEPT !.lastRep = ev.ts] ELSE t
        taken == IF SplitQueue THEN [t EXCEPT !.lastRep = ev.ts] ELSE t
        follows == ~SplitQueue \/ ev.act \/ NoteFollows
    IN IF ev.t < t.lastCmdT THEN Reassert(t0)   \* happened before the latest command
       ELSE IF w = NoWin THEN IF KeyLeft(t, ev) THEN Reassert(t0) ELSE t0   \* a departure focuses
       ELSE IF w \in t.left THEN t0   \* a window that left is no one's focus
       ELSE IF miss THEN Reassert(t0)   \* retry the missed request
       ELSE IF WsOf[w] \in IF AdoptShown THEN Shown(t) ELSE {t.active}   \* on screen: its display becomes the focused one
            THEN RequestFocus([taken EXCEPT !.focus = w, !.active = WsOf[w], !.mru[WsOf[w]] = w, !.gen = t.gen + 1], w, t.gen + 1)
       ELSE IF ev.hid /\ follows /\ FollowRekeys THEN StartSwitch(taken, WsOf[w], w)
       ELSE IF ev.hid /\ follows /\ ~KeyLeft(t, ev) THEN IF wait THEN Hold(t, ev) ELSE StartSwitch(taken, WsOf[w], w)
       ELSE Reassert(t0)   \* visible mid-switch, or a re-key after the key window left

\* A report stamped before the last one taken for the user's, or before the report held
\* for the grace, was overtaken by it: with SplitQueue reports of different apps arrive out
\* of order. A newer activation of a window ends a held report.
UserReport(t, ev, miss) ==
    IF SplitQueue /\ (ev.ts < t.lastRep \/ (t.held # <<>> /\ ev.ts < t.held[1].ts)) THEN t
    ELSE LET newer == ev.w # NoWin /\ ev.w \notin t.left
         IN Adopt(IF newer THEN [t EXCEPT !.held = <<>>] ELSE t, ev, FALSE, miss)

Holds(t, ev) ==
    /\ HoldNotes /\ ~ev.act /\ ev.w # NoWin
    /\ \E k \in 1..Len(t.expect) : t.expect[k].kind = "act" /\ AppOfX(t.expect[k].w) = AppOf[ev.w]
                                  /\ ev.ts > t.expect[k].ts

\* One report as the main actor takes it, before SplitQueue.
ObserveOne(t, ev) ==
    LET ks == {k \in 1..Len(t.expect) : Matches(ev, t.expect[k])}
        \* A report after the key window a departure waited on ends the wait,
        \* unless it is Kosmos's own echo: then macOS keys nothing more.
        t0 == [t EXCEPT !.seenKey = ev.w, !.waiting = IF ev.prev = @ /\ ks = {} THEN NoWin ELSE @]
        \* A newer activation of a window ends a held report. One that repeats
        \* the held window, after a miss, is the same activation.
        again == t.held # <<>> /\ ev.w = t.held[1].w /\ ev.prev = ev.w
        miss == MissRule /\ ks = {} /\ Missed(t, ev)
        t2 == IF miss THEN DropMissed(t0, ev) ELSE t0
    IN IF ks # {}
       THEN LET k == CHOOSE k \in ks : \A j \in ks : k <= j
            IN [t0 EXCEPT !.expect = SubSeq(@, k + 1, Len(@))]
       ELSE IF again THEN t2
       ELSE UserReport(t2, ev, miss)

\* One report with SplitQueue. Its `prev` is the key window Kosmos last heard of, as the
\* implementation knows it: reports of different apps can arrive out of order.
\* With record-at-call rules, a report from an app that is not front (`bg`) consumes an echo
\* it matches, but is no key window report: unmatched it is ignored, and then it does not
\* count as the last report. An activation read of an app no longer front was overtaken by
\* a later activation. Unless that was Kosmos's own, recorded after this activation or
\* already in front when this one was noticed, the later one's report decides.
ObserveSplit(t, ev0) ==
    LET \* A report that repeats the window Kosmos last heard of, as an activation read after
        \* its app's notification of the same change does, has the window before that.
        ev == [ev0 EXCEPT !.prev = IF ev0.w = t.seenKey THEN t.seenPrev ELSE t.seenKey]
        bg == /\ ev.bg /\ SplitRules = "record-at-call"
              /\ (ev.act /\ ~ActFrontCheck => ev.ts > t.kact /\ ~ev.ko)
        ks == {k \in 1..Len(t.expect) : Matches(ev, t.expect[k])}
        k == CHOOSE k \in ks : \A j \in ks : k <= j
        \* An activation's echo is its activation read: the app's notification of the same
        \* window only joins it, and leaves the record for it.
        joins == ks # {} /\ ~ev.act /\ t.expect[k].kind = "act"
        a == AppOfX(ev.w)
        \* A read of another window than the key record named, with no notification held for its
        \* app, ran before the app keyed the named window after its last key window
        \* (KeyOldFirst): the record then waits for that window's notification. A held
        \* notification is the user's change, which the read finds.
        waits == ks # {} /\ ev.act /\ t.expect[k].kind = "act" /\ ev.w # t.expect[k].w /\ t.noteHeld[a] = NoEv
        tk == IF bg THEN t ELSE [t EXCEPT !.seenKey = ev.w, !.seenPrev = ev.prev,
                                          !.waiting = IF ev.prev = @ /\ ks = {} THEN NoWin ELSE @]
        \* Reports of one app wait behind its worker, so an echo can come after the echo of
        \* a later request: only the matched record goes.
        t2 == IF joins THEN tk
              ELSE IF waits THEN [tk EXCEPT !.expect[k].kind = "note"]
              ELSE [tk EXCEPT !.expect = SubSeq(@, 1, k - 1) \o SubSeq(@, k + 1, Len(@))]
        \* The activation read that is the echo of Kosmos's activation settles the
        \* notification held for its app.
        settles == ks # {} /\ ev.act /\ ev.w # NoWin /\ ~joins
        h == IF settles THEN t.noteHeld[a] ELSE NoEv
        t3 == IF settles THEN [t2 EXCEPT !.noteHeld[a] = NoEv] ELSE t2
        \* A repeat of the held window after a miss. Inside the front app the worker's raise
        \* keys the window, so requests do not miss, and a repeat of the window Kosmos last
        \* heard of can be the other report of one activation, or a newer one.
        again == MissRule /\ t.held # <<>> /\ ev.w = t.held[1].w /\ ev0.w = t.seenKey
        miss == MissRule /\ ks = {} /\ Missed(t, [ev EXCEPT !.prev = t.seenKey])
        tm == IF miss THEN DropMissed(tk, ev) ELSE tk
    IN IF ks # {}
       \* The app's window the read found is the held notification's: the user changed it
       \* after Kosmos's activation.
       THEN IF h # NoEv /\ h.w = ev.w THEN UserReport(t3, h, FALSE)
            \* An echo can land after a newer intent, as a busy app's late raise does: the
            \* intent is requested again.
            ELSE IF ~joins /\ ~waits /\ ev.w # t3.focus THEN Reassert(t3) ELSE t3
       ELSE IF bg THEN t
       \* A notification from an app Kosmos activated, before that activation's read: a
       \* change the user made after the activation, or one the app made in the background
       \* before it, whose callback ran after. The read tells.
       ELSE IF Holds(t, ev) THEN [tk EXCEPT !.noteHeld[a] = ev]
       ELSE IF again THEN tm
       ELSE UserReport(tm, ev, miss)

\* The worker saw a raise after a key record done: its record goes unless a report used it.
Raised(t, r) == LET P(x) == x.r = r /\ x.kind = "note" IN ForgetIf(t, P)

RECURSIVE Observe(_, _)
Observe(t, evs) ==
    IF evs = <<>> THEN t
    ELSE Observe(IF "raised" \in DOMAIN Head(evs) THEN Raised(t, Head(evs).raised)
                 ELSE IF SplitQueue THEN ObserveSplit(t, Head(evs)) ELSE ObserveOne(t, Head(evs)), Tail(evs))

\* Kosmos learns that w left, and it leaves the model. When it was the focus,
\* the workspace's next window, or Kosmos's own on an empty workspace, becomes the
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

\* A hover focus is a command for a window of a shown workspace: reports of user
\* activations before it are stale, and it is requested like any focus. A window of
\* another workspace, visible only mid-switch, leaves focus alone.
RunHover(t, x) ==
    LET w == x.ws
    IN IF WsOf[w] \notin (IF AdoptShown THEN Shown(t) ELSE {t.active}) THEN t
       ELSE RequestFocus([t EXCEPT !.lastCmdT = x.t, !.focus = w, !.active = WsOf[w], !.mru[WsOf[w]] = w,
                                   !.gen = t.gen + 1], w, t.gen + 1)

RunJob(t, x) ==
    CASE x.kind = "input"  -> RunCommand(t, x)
      [] x.kind = "hover"  -> RunHover(t, x)
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
    IN /\ ~SplitQueue
       /\ s.fq # <<>>
       /\ \/ s' = IF skip THEN t
                  ELSE KeyChange([t EXCEPT !.expect = Append(@, [w |-> x.w, i |-> t.ne + 1])], x.w, Len(history))
          \* A miss: the app stays on its key window and reports it again. The
          \* request was performed and awaits its echo.
          \/ /\ AllowMiss /\ ~s.missed /\ ~skip
             /\ s.osFocus # NoWin /\ AppOfX(x.w) = AppOf[s.osFocus]
             /\ s' = [t EXCEPT !.missed = TRUE, !.expect = Append(@, [w |-> x.w, i |-> t.ne + 1]),
                               !.evs = Append(@, Ev(s.osFocus, FALSE, Len(history), s.ne, s.hidden[s.osFocus],
                                                    s.osFocus, FALSE, 0, FALSE))]
       /\ UNCHANGED history

(***************************************************************************)
(* The focus request in the implementation's steps (SplitQueue)            *)
(***************************************************************************)
\* The queue takes a request. A stale one, one whose window was concealed when it was
\* requested, or one whose window left does nothing. Kosmos's own window is keyed at once.
\* Otherwise the queue reads whether the target's app is front and hands the worker its job.
FocusStart ==
    LET x == Head(s.fq)
        t == [s EXCEPT !.fq = Tail(@)]
        a == AppOfX(x.w)
        r == Len(s.kr) + 1
        front == FrontApp(s) = a
    IN /\ SplitQueue
       /\ s.fcur = NoReq
       /\ s.fq # <<>>
       /\ s' = IF x.g # s.gen \/ x.c \/ x.w \in s.gone THEN t
               ELSE IF x.w = NoWin THEN IF s.osFocus = NoWin THEN t ELSE KeyChange(Record(t, NoWin, 0), NoWin, Len(history))
               ELSE [t EXCEPT !.kr = Append(@, "pending"),
                              !.wq[a] = Append(@, [r |-> r, w |-> x.w, g |-> x.g, front |-> front, st |-> "start"]),
                              !.fcur = [r |-> r, w |-> x.w, g |-> x.g, front |-> front, st |-> "wait"]]
       /\ UNCHANGED history

\* The key record: it activates a background app with the named window, leaving the
\* stacking order alone (`kosmos-probe keying`: keyed, and on top 0 times in 10). Inside
\* the front app it keys the window only when a raise has made it the app's frontmost
\* window, and changes nothing otherwise.
KeyRecord(t, a, w) ==
    IF FrontApp(t) # a \/ t.atop[a] = w THEN KeyChange(t, w, Len(history)) ELSE t

\* With KeyOldFirst the key record can activate a background app with the window that was
\* key when the app was last front, and the app keys the named window a step later
\* (KeyNamed). Live, Preview reported its main window and then the hovered one, and Ghostty
\* its last key window, concealed on another workspace, and then the requested one: the
\* activation read ran between the two. The spec does this only while that window is still
\* the app's focused window, so the first key changes nothing the app notifies. After a raise
\* in the background the two differ, no probe has shown which the app keys first, and the
\* notification of a first key would read as the user's change (docs/focus.md).
KeyRecords(t, a, w) ==
    {KeyRecord(t, a, w)}
    \cup IF KeyOldFirst /\ FrontApp(t) # a /\ t.lastKey[a] = t.afocus[a] /\ t.lastKey[a] \notin {w} \cup t.gone
          THEN {[KeyChange(t, t.lastKey[a], Len(history)) EXCEPT !.named[a] = w]}
          ELSE {}

\* The app keys the window its key record named: inside the app while it is still front, and
\* as its own focused window once another app came front.
KeyNamed(a) ==
    LET w == s.named[a]
        t == [s EXCEPT !.named[a] = NoWin]
    IN /\ SplitQueue
       /\ w # NoWin
       /\ s' = IF w \in s.gone THEN t
               ELSE IF FrontApp(s) = a THEN KeyChange(t, w, Len(history))
               ELSE IF s.afocus[a] # w THEN BackgroundFocus(t, w, Len(history))
               ELSE t
       /\ UNCHANGED history

\* AXRaise brings the window to the front of its app. Inside the front app it also keys
\* the window when RaiseKeys; in a background app it changes the app's own focused window,
\* reported when RaiseReports. A window that left is not raised.
Raise(t, a, w) ==
    LET u == [t EXCEPT !.atop[a] = w, !.lowTop = @ \ {a}]
    IN IF w \in t.gone THEN t
       ELSE IF FrontApp(t) = a THEN (IF RaiseKeys THEN KeyChange(u, w, Len(history)) ELSE u)
       ELSE IF t.afocus[a] = w THEN u
       ELSE IF RaiseReports THEN BackgroundFocus(u, w, Len(history))
       ELSE [u EXCEPT !.afocus[a] = w]

\* The queue stops waiting: the job finished, or, for BusyApp, 30 ms passed.
\* record-at-call: for a front app the queue only moves on; the worker keys. For a
\* background app, unless the request went stale, its window left, the app came front
\* meanwhile, or the worker is keying it, the queue records and posts the key record, and
\* with PostRaise hands the worker the raise that follows it. An app handles key records in
\* order, so one keys the named window of the one before it first.
\* d1be665: a pending request is recorded by the queue; then the key record follows.
FocusDecide ==
    LET c == s.fcur
        t == [s EXCEPT !.fcur = NoReq]
        ph == s.kr[c.r]
        a == AppOf[c.w]
        post(u) == IF PostRaise
                   THEN [u EXCEPT !.wq[a] = Append(@, [r |-> c.r, w |-> c.w, g |-> c.g, front |-> TRUE, st |-> "post"])]
                   ELSE u
    IN /\ SplitQueue
       /\ c # NoReq
       /\ c.st = "wait"
       /\ c.r \in s.jdone \/ a = BusyApp
       /\ s.named[a] = NoWin
       /\ IF SplitRules = "record-at-call"
          THEN IF c.front \/ c.g # s.gen \/ c.w \in s.gone \/ FrontApp(s) = a \/ ph = "raising" THEN s' = t
               ELSE \E u \in KeyRecords([Record(t, c.w, c.r) EXCEPT !.kr[c.r] = "sent"], a, c.w) : s' = post(u)
          ELSE s' = CASE ph = "skipped" -> t
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
\* record-at-call: a stale request, one the queue has keyed, or one whose window left raises
\* nothing. In the front app the worker tells the queue it is keying; when RaiseKeys the
\* raise keys the window and the worker records just before it, and otherwise the key record
\* after the raise does. A job for a background app does nothing, unless BackgroundRaise.
\* d1be665: the generation is rechecked; a stale request raises nothing, and its record is
\* dropped if the app was front.
\* The raise itself lands in the next step (WorkerLand).
WorkerRaise(a) ==
    LET j == Head(s.wq[a])
        t == Finish(s, a, j)
        stale == j.g # s.gen
        land(u) == [u EXCEPT !.wq[a][1].st = "land"]
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "raise"
       /\ s' = IF SplitRules = "record-at-call"
               THEN IF stale \/ s.kr[j.r] = "sent" \/ j.w \in s.gone THEN t
                    \* Without BackgroundRaise a job for a background app only orders: the
                    \* queue's key record keys it, and an app someone else brought front meanwhile
                    \* keeps the window they chose.
                    ELSE IF ~j.front /\ ~BackgroundRaise THEN t
                    ELSE IF FrontApp(s) = a
                         THEN IF RaiseKeys THEN land([Record(s, j.w, j.r) EXCEPT !.kr[j.r] = "raising"])
                              ELSE land([s EXCEPT !.kr[j.r] = "raising"])
                    ELSE IF ~j.front THEN land(s)
                    ELSE t
               ELSE IF stale THEN (IF j.front THEN Forget(t, j.r) ELSE t)
               ELSE land(s)
       /\ UNCHANGED history

\* The raise after the queue's key record (PostRaise), when the worker gets to it: only
\* while the app is front and the target is its focused window, so it never re-keys over
\* a window the user chose since. The target is key then, so the raise keys nothing unless
\* the user keys another window of the app before it lands. Unless PostRaiseEcho is "none"
\* the worker records just before it. The ceiling docs/focus.md names: the worker finds the
\* app with its last key window before the app keys the named one (KeyOldFirst), skips
\* the raise, and the window can stay behind its app's others (`lowTop`).
IsPost(j) == s.kr[j.r] = "sent"
WorkerPost(a) ==
    LET j == Head(s.wq[a])
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "post"
       /\ s' = IF FrontApp(s) # a \/ s.afocus[a] # j.w \/ j.w \in s.gone
               THEN [Finish(s, a, j) EXCEPT !.lowTop = IF s.named[a] = j.w THEN @ \cup {a} ELSE @]
               ELSE [(IF PostRaiseEcho # "none" THEN Record(s, j.w, j.r) ELSE s) EXCEPT !.wq[a][1].st = "land"]
       /\ UNCHANGED history

\* The app performs AXRaise, and the front app when it does decides what it changes. An
\* idle app answers; its worker then posts the key record when RaiseKeys is off. A busy
\* app may not answer before the AX timeout: the worker moves on, keeping its record, and
\* the raise still lands when the app gets to it (LateLand).
WorkerLand(a) ==
    LET j == Head(s.wq[a])
        t == Finish(s, a, j)
        after == IF ~RaiseKeys /\ SplitRules = "record-at-call" /\ s.kr[j.r] = "raising" THEN "key"
                 ELSE IF IsPost(j) /\ PostRaiseEcho = "done" THEN "posted"
                 ELSE "done"
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "land"
       /\ \/ s' = IF after = "done" THEN Raise(t, a, j.w) ELSE [Raise(s, a, j.w) EXCEPT !.wq[a][1].st = after]
          \/ /\ RaiseTimeout /\ a = BusyApp
             /\ s' = [t EXCEPT !.late[a] = Append(@, j.w)]
       /\ UNCHANGED history

\* The raise after a key record has returned, and the worker reads the app's focused window,
\* by when the app's observer callbacks for the raise have run (PostRaiseEcho = "done"). It
\* tells the main actor, behind their reports, which forgets the raise's record unless a
\* report used it: the raise changed nothing.
WorkerPosted(a) ==
    LET j == Head(s.wq[a])
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "posted"
       /\ s.nq[a] = <<>>
       /\ s' = [Finish(s, a, j) EXCEPT !.evs = Append(@, [raised |-> j.r])]
       /\ UNCHANGED history

LateLand(a) ==
    /\ SplitQueue
    /\ s.late[a] # <<>>
    /\ s' = Raise([s EXCEPT !.late[a] = Tail(@)], a, Head(s.late[a]))
    /\ UNCHANGED history

\* The worker delivers the app's focused window notification (LateNoteCheck): stamped now,
\* and marked when the app is not front now.
WorkerNote(a) ==
    LET j == Head(s.wq[a])
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "note"
       /\ s' = [s EXCEPT !.wq[a] = Tail(@), !.clk = s.clk + 1,
                         !.evs = Append(@, Ev(j.w, FALSE, j.t, 0, s.hidden[j.w], NoWin, FrontApp(s) # a,
                                              s.clk, FALSE))]
       /\ UNCHANGED history

\* The activation read (Apps.activated): the app's focused window now, stamped when the
\* activation was noticed on the main thread. With ActFrontCheck it is no key report once
\* the app is no longer front. The app's observer callbacks for the changes it reads have
\* run: the read waits for main's notice and a round trip to the app, and each callback
\* only stamps, checks and posts.
WorkerAct(a) ==
    LET j == Head(s.wq[a])
        w == s.afocus[a]
    IN /\ SplitQueue
       /\ s.wq[a] # <<>>
       /\ j.st = "act"
       /\ s.nq[a] = <<>>
       /\ s' = [s EXCEPT !.wq[a] = Tail(@),
                         \* ghost: the read finds another window than the activation keyed, as when
                         \* Kosmos keyed that app again before the read ran; if the activation was
                         \* the user's, no report says what they chose, and it makes no claim. With
                         \* KeyOldFirst Kosmos's key record can activate the app with the user's
                         \* window and key its own after the read.
                         !.lastAmb = @ \/ ((w # j.w \/ s.named[a] # NoWin) /\ j.w \in s.lastWin),
                         !.evs = Append(@, Ev(w, TRUE, j.t, 0, j.hs[w], NoWin, FrontApp(s) # a, j.ts, j.ko))]
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

Worker(a) == WorkerStart(a) \/ WorkerRead(a) \/ WorkerRaise(a) \/ WorkerPost(a) \/ WorkerLand(a)
             \/ WorkerPosted(a) \/ WorkerKey(a) \/ WorkerNote(a) \/ WorkerAct(a) \/ LateLand(a)

\* The app's observer callback runs for its oldest notification: stamped now, and marked
\* when the app is not front now.
ObserverPost(a) ==
    LET n == Head(s.nq[a])
        bg == FrontApp(s) # a
    IN /\ SplitQueue
       /\ s.nq[a] # <<>>
       /\ s' = [s EXCEPT !.nq[a] = Tail(@), !.clk = s.clk + 1,
                         !.evs = Append(@, Ev(n.w, FALSE, n.t, 0, s.hidden[n.w], NoWin, bg, s.clk, FALSE)),
                         \* ghost: the user's change inside the front app is reported after another
                         \* app came front, or once its app is front again; nothing tells it from a
                         \* background app's own change
                         !.lastLost = @ \/ ((bg \/ n.lost) /\ n.o.user /\ n.o.lone /\ n.w \in s.lastWin),
                         \* ghost: a switch revealed or concealed the window of the user's change
                         \* before the callback; whether it was hidden is judged by the stamp
                         !.lastMis = @ \/ (n.o.user /\ s.hidden[n.w] # n.ehid)]
       /\ UNCHANGED history

\* Kosmos's own window reports with the notice, from its own main thread.
ActNotice ==
    LET n == Head(s.an)
        t == [s EXCEPT !.an = Tail(@)]
    IN /\ SplitQueue
       /\ s.an # <<>>
       /\ s' = IF n.w = NoWin
               THEN [t EXCEPT !.evs = Append(@, Ev(NoWin, TRUE, n.t, 0, FALSE, NoWin, FrontApp(s) # "kosmos",
                                                   s.clk, Overtaken(s, "kosmos"))),
                              !.clk = s.clk + 1]
               \* ghost: a switch revealed or concealed the window the user activated before
               \* the notice; whether it was hidden is judged by the notice's stamp
               ELSE [ActItem(t, n.a, n.w, n.t) EXCEPT !.lastMis = @ \/ (n.user /\ s.hidden[n.w] # n.ehid)]
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

\* Reports of key changes that have not reached the main actor's queue: observer
\* callbacks, activation notices and reads.
InFlight == s.evs # <<>> \/ s.an # <<>>
            \/ \E a \in Apps : s.nq[a] # <<>> \/ s.named[a] # NoWin
                            \/ \E n \in 1..Len(s.wq[a]) : s.wq[a][n].st \in {"act", "note"}

\* The bound of a departure that waited for macOS's report of the next key
\* window ends without one, as when the app keeps no key window: the departure
\* focuses. The bound outlasts macOS's key change after a minimize and the
\* report of it, so neither is on its way.
Nudge ==
    /\ WaitBound
    /\ s.waiting # NoWin
    /\ s.rekey = <<>>
    /\ ~InFlight /\ \A n \in 1..Len(s.mq) : s.mq[n].kind # "report"
    /\ s' = Reassert([s EXCEPT !.waiting = NoWin])
    /\ UNCHANGED history

\* macOS keys the next window once a departure's animation ends.
Rekey ==
    LET x == s.rekey[1]
        u == Top(KeyChange([s EXCEPT !.rekey = <<>>], x.w, x.t), x.w)
    IN /\ s.rekey # <<>>
       /\ s' = IF x.w = NoWin THEN [u EXCEPT !.bare = x.a] ELSE u
       /\ UNCHANGED history

Fallback ==
    /\ AllowFallback
    /\ s.osFocus # NoWin
    /\ s.hidden[s.osFocus]
    /\ \E v \in (Visible \cup {NoWin}) \ {s.osFocus} : s' = Top(KeyChange(s, v, Len(history)), v)
    /\ UNCHANGED history

\* Observer callbacks and activation notices only stamp, check and post, so each runs
\* before the user's next input. An app keys the window its key record named within
\* milliseconds, before it too.
Noticed == s.an = <<>> /\ \A a \in Apps : s.nq[a] = <<>> /\ s.named[a] = NoWin

Quiescent == s.mq = <<>> /\ s.bq = <<>> /\ s.fq = <<>> /\ s.evs = <<>> /\ s.notices = <<>>
             /\ s.lag = {} /\ s.held = <<>> /\ s.waiting = NoWin /\ s.rekey = <<>>
             /\ s.an = <<>> /\ s.fcur = NoReq
             /\ \A a \in Apps : s.wq[a] = <<>> /\ s.late[a] = <<>> /\ s.nq[a] = <<>> /\ s.named[a] = NoWin

\* A misjudged activation can decide what later inputs lead to until Kosmos settles.
Misjudged == s.lastMis /\ ~Quiescent

\* The ghosts that exempt the latest input start again with each input.
Fresh(t) == [t EXCEPT !.lastAmb = FALSE, !.lastLost = FALSE, !.lastMis = Misjudged, !.lastRaced = FALSE,
                      !.lastEarly = SplitQueue /\ t.seenKey \in t.gone \ t.aged]

\* The user keys a window of an app whose raise Kosmos decided, after the worker's read and
\* before the app performs it. A change to the raised window reads as the raise's echo: its
\* callback runs after the worker's record. After a change to another window the raise keys
\* its own again, and its report reads as the user's when the user's change to the raised
\* window used the record up.
Races(w) == SplitQueue /\ w # NoWin
            /\ \E n \in 1..Len(s.wq[AppOf[w]]) : s.wq[AppOf[w]][n].st \in {"raise", "land"}

\* A user activation of a window a switch is about to conceal makes no claim.
Claim(w) == IF WsOf[w] = s.goal[DisplayOf[WsOf[w]]] \/ s.hidden[w] THEN {w} ELSE {}
Goal(w) == IF s.hidden[w] THEN [s.goal EXCEPT ![DisplayOf[WsOf[w]]] = WsOf[w]] ELSE s.goal

Command ==
    /\ Len(history) < MaxEvents
    /\ Noticed
    /\ \E k \in Workspaces :
         /\ s' = [Fresh(s) EXCEPT !.mq = Append(@, Job("input", k, 0, <<>>, Len(history) + 1)),
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
    /\ Noticed
    /\ \E w \in Visible \ {s.osFocus} :
         /\ s' = [Top(KeyChangeBy(Fresh(s), w, Len(history) + 1, TRUE), w) EXCEPT !.lastWin = Claim(w),
                                                                                  !.lastRaced = Races(w)]
         /\ history' = Append(history, -1)

CmdTab ==
    /\ AllowCmdTab
    /\ ~Returning /\ s.rekey = <<>>
    /\ Len(history) < MaxEvents
    /\ Noticed
    /\ \E w \in Win \ s.gone :
         /\ AppOf[w] # FrontApp(s)
         /\ s' = [Top(KeyChangeBy(Fresh(s), w, Len(history) + 1, TRUE), w) EXCEPT !.lastWin = Claim(w),
                                                                                  !.goal = Goal(w)]
         /\ history' = Append(history, -2)

\* The user or an app keys a specific hidden window, of any app: `open` on a
\* document whose window is concealed, an app's Window menu, the Dock's window
\* list.
Open ==
    /\ AllowOpen
    /\ ~Returning /\ s.rekey = <<>>
    /\ Len(history) < MaxEvents
    /\ Noticed
    /\ \E w \in Win \ s.gone :
         /\ s.hidden[w] /\ w # s.osFocus
         /\ s' = [Top(KeyChangeBy(Fresh(s), w, Len(history) + 1, TRUE), w) EXCEPT !.lastWin = {w},
                                                                                  !.goal[DisplayOf[WsOf[w]]] = WsOf[w],
                                                                                  !.lastRaced = Races(w)]
         /\ history' = Append(history, -5)

\* The pointer comes to rest in a visible window. Focus follows mouse never moves the
\* key window by itself; Kosmos's hover job does.
Hover ==
    /\ AllowHover
    /\ ~Returning /\ s.rekey = <<>>
    /\ Len(history) < MaxEvents
    /\ Noticed
    /\ \E w \in Visible :
         /\ s' = [Fresh(s) EXCEPT !.mq = Append(@, Job("hover", w, 0, <<>>, Len(history) + 1)), !.lastWin = Claim(w)]
         /\ history' = Append(history, -6)

\* The user closes, minimizes or hides a window after seeing it key, and brings
\* one back after seeing it leave. Kosmos has had the reports before by then:
\* it handles one in milliseconds. macOS keys the next window as a window
\* finishes leaving, before the user can bring it back.
Seen == s.evs = <<>> /\ s.held = <<>> /\ s.rekey = <<>> /\ (\A n \in 1..Len(s.mq) : s.mq[n].kind # "report")
        /\ ~InFlight /\ \A a \in Apps : s.noteHeld[a] = NoEv

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
                \* A window that closes or minimizes leaves its app front.
                stay == IF SplitQueue /\ out = {s.osFocus} THEN AppOf[s.osFocus] ELSE "kosmos"
                t1 == [Fresh(s) EXCEPT !.gone = @ \cup out, !.lag = @ \cup out, !.aged = @ \ out,
                                       !.closed = IF closed THEN @ \cup out ELSE @,
                                       !.notices = @ \o notices, !.lastWin = {},
                                       !.goal = IF queued THEN @ ELSE s.onDisplay]
                u == Top(KeyChange(t1, v, Len(history) + 1), v)
            IN /\ s' = CASE quiet -> [t1 EXCEPT !.osFocus = NoWin, !.bare = stay]
                        [] late  -> [t1 EXCEPT !.rekey = <<[w |-> v, t |-> Len(history) + 1, a |-> stay]>>]
                        [] OTHER -> IF v = NoWin THEN [u EXCEPT !.bare = stay] ELSE u
               /\ history' = Append(history, -3)

\* A window that left returns where it was, and macOS keys it: the user
\* unminimizes it, unhides its app, or takes it out of native fullscreen.
Return ==
    /\ AllowReturn
    /\ Len(history) < MaxEvents
    /\ Seen
    /\ \E w \in s.gone \ (s.closed \cup s.lag) :
         /\ s' = Top(KeyChangeBy([Fresh(s) EXCEPT !.gone = @ \ {w}, !.aged = @ \ {w}, !.lastWin = {w},
                                                  !.goal[DisplayOf[WsOf[w]]] = WsOf[w],
                                                  !.notices = Append(@, [w |-> w, closed |-> FALSE, back |-> TRUE,
                                                                         t |-> Len(history) + 1]),
                                                  !.lastRaced = Races(w)],
                                 w, Len(history) + 1, TRUE), w)
         /\ history' = Append(history, -4)

\* A background app changes its own focused window, as when it opens a window, without
\* coming front; keystrokes still go to the front app's key window.
UserBackground ==
    /\ AllowBackground
    /\ Len(history) < MaxEvents
    /\ \E w \in Win \ s.gone :
         /\ AppOf[w] # FrontApp(s)
         /\ s.afocus[AppOf[w]] # w
         /\ s' = BackgroundFocus(s, w, Len(history) + 1)
         /\ history' = Append(history, -7)

\* A second passes after Kosmos has had every report: a departure is no longer evidence that
\* the next key change was macOS's own (SplitQueue). Without SplitQueue a report's `prev` is
\* the window really key before it.
Age ==
    /\ SplitQueue /\ Seen
    /\ \E w \in Known(s) \ s.aged : s' = [s EXCEPT !.aged = @ \cup {w}]
    /\ UNCHANGED history

Internal == ExecMain \/ ExecBridge \/ ExecFocus \/ PostReports \/ PostNotices \/ OrderOut \/ Expire \/ Nudge \/ Rekey
            \/ Age
            \/ ActNotice \/ FocusStart \/ FocusDecide \/ FocusKey \/ \E a \in Apps : Worker(a) \/ ObserverPost(a) \/ KeyNamed(a)

Next == Internal \/ Fallback \/ Command \/ Click \/ CmdTab \/ Open \/ Leave \/ Return \/ Hover \/ UserBackground

Spec == Init /\ [][Next]_vars /\ WF_vars(ExecMain) /\ WF_vars(ExecBridge)
                              /\ WF_vars(ExecFocus) /\ WF_vars(PostReports) /\ WF_vars(PostNotices)
                              /\ WF_vars(OrderOut) /\ WF_vars(Expire) /\ WF_vars(Nudge) /\ WF_vars(Rekey)
                              /\ WF_vars(ActNotice) /\ WF_vars(FocusStart) /\ WF_vars(FocusDecide) /\ WF_vars(FocusKey)
                              /\ \A a \in Apps : WF_vars(Worker(a)) /\ WF_vars(ObserverPost(a)) /\ WF_vars(KeyNamed(a))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
\* The screen shows Kosmos's workspaces and macOS keys Kosmos's focus.
Converged == Visible = ShownWins(s) \ s.gone /\ s.osFocus = s.focus

ConvergesWhenQuiet == Quiescent => Converged /\ \A a \in Apps : s.noteHeld[a] = NoEv

\* The key window is the front of its app (SplitQueue): a background app keyed by the key
\* record alone stays behind its other windows. The ceiling of the raise after it is exempt.
FocusOnTop == Quiescent /\ SplitQueue /\ s.osFocus # NoWin /\ AppOf[s.osFocus] \notin s.lowTop
              => s.atop[AppOf[s.osFocus]] = s.osFocus

RECURSIVE LastCommand(_)
LastCommand(h) ==   \* 0 when another input came after the last command
    IF h = <<>> THEN 0
    ELSE IF h[Len(h)] < 0 THEN 0
    ELSE h[Len(h)]

HonorsLastCommand == Quiescent /\ LastCommand(history) # 0 => s.active = LastCommand(history)

\* A click, Command-Tab, return or hover after the last command wins, unless it makes no
\* claim, or one of the races and limits docs/focus.md lists hid what the user chose.
HonorsLastActivation == Quiescent /\ s.lastWin # {} /\ ~s.lastAmb /\ ~s.lastLost /\ ~s.lastMis /\ ~s.lastRaced
                        /\ ~s.lastEarly
                        => s.focus \in s.lastWin

\* Without exempting a click lost to a callback that ran after Kosmos activated another app.
HonorsLastClick == Quiescent /\ s.lastWin # {} /\ ~s.lastAmb /\ ~s.lastMis /\ ~s.lastRaced /\ ~s.lastEarly
                   => s.focus \in s.lastWin

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
                         !.mq = ViewQ(s.mq, s.sw), !.bq = ViewQ(s.bq, s.sw), !.fq = ViewQ(s.fq, s.gen),
                         !.fcur = IF @ = NoReq THEN @ ELSE [@ EXCEPT !.g = Cur(@, s.gen)],
                         !.wq = [a \in Apps |-> ViewQ(s.wq[a], s.gen)]],
               history>>

TraceView == [history |-> history, active |-> s.active, onDisplay |-> s.onDisplay, focus |-> s.focus,
              osFocus |-> s.osFocus, bare |-> s.bare, visible |-> Visible, gone |-> s.gone, left |-> s.left,
              notices |-> s.notices, lag |-> s.lag, held |-> s.held, waiting |-> s.waiting, rekey |-> s.rekey,
              sw |-> s.sw, gen |-> s.gen,
              mq |-> [n \in 1..Len(s.mq) |-> s.mq[n].kind],
              bq |-> [n \in 1..Len(s.bq) |-> s.bq[n].op],
              fq |-> s.fq, expect |-> s.expect, evs |-> s.evs, seenKey |-> s.seenKey,
              afocus |-> s.afocus, atop |-> s.atop, fcur |-> s.fcur, wq |-> s.wq, kr |-> s.kr, late |-> s.late,
              nq |-> s.nq, an |-> s.an, clk |-> s.clk, kact |-> s.kact, noteHeld |-> s.noteHeld,
              lastWin |-> s.lastWin, goal |-> s.goal, lastRep |-> s.lastRep, hidden |-> s.hidden,
              named |-> s.named, lastKey |-> s.lastKey, lowTop |-> s.lowTop]
=============================================================================
