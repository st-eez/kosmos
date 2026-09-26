------------------------------ MODULE Handover ------------------------------
(***************************************************************************)
(* Kosmos's hidden windows across its restarts (docs/hiding.md). One      *)
(* display shows one workspace at a time; each window belongs to a fixed  *)
(* workspace (HomeOf) and is concealed while it sits in the holding Space  *)
(* (`held`). The holding Space and the recovery record outlive the Kosmos *)
(* that made them.                                                         *)
(*                                                                         *)
(* A running Kosmos admits each window, then conceals the windows of       *)
(* hidden workspaces and reveals the rest. A batch records each window     *)
(* before its first conceal, and the bridge queue applies the batch's     *)
(* operations one window at a time (Apply). A switch changes the shown    *)
(* workspace for the windows admitted so far. The saved layout keeps the  *)
(* shown workspace, written a moment after the change (WriteLayout), so a *)
(* crash can lose the last switch.                                         *)
(*                                                                         *)
(* Kosmos ends in one of three ways. A plain quit lands the queued         *)
(* batches, writes the layout and restores every concealed window. A quit *)
(* that `kosmos handover` armed lands the batches and writes the layout,  *)
(* then marks the record for the Kosmos that follows and leaves the        *)
(* windows concealed. With Gate, Kosmos takes the arm only when the next  *)
(* build reads its record version. A crash drops the batches not yet       *)
(* applied.                                                                *)
(*                                                                         *)
(* Each Kosmos's guardian runs from before its Kosmos takes the instance  *)
(* lock. Once its Kosmos exits and a record is left, it waits for a       *)
(* successor to take the lock, and leaves the record to that successor    *)
(* (GuardianLeaves). If none comes within the grace, it restores every    *)
(* recorded window (GraceEnds). Without Grace it restores them at once,   *)
(* before any successor can take the lock. A start is on its way after   *)
(* the exit: `prompt` within the grace, `late` after it, as launchd's      *)
(* throttle makes one, or `none`, as after a quit for good or with Launch *)
(* at Login off.                                                           *)
(*                                                                         *)
(* A starting Kosmos restores the layout, then takes the record over       *)
(* (Adopt). It keeps concealed each recorded window the saved layout puts *)
(* on a hidden workspace and restores the rest; without Adopt it restores *)
(* every window, as startup recovery did. A build that cannot read the    *)
(* record takes it for none. On admission, a concealed window whose       *)
(* workspace is shown is revealed (AdmitReveal). A window whose app never *)
(* answers is never admitted, and the backstop reveals it once every      *)
(* other window is admitted (Backstop). That timing is an assumption:     *)
(* Kosmos reveals such windows 5 s after its start, and the windows of a  *)
(* live launch were admitted within 70 ms.                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Win, Workspaces, HomeOf, FirstShown,
    MaxEvents,          \* switches, quits and crashes
    Adopt, Grace, Gate, AdmitReveal, Backstop,
    AllowUnreadable,    \* the next build can read another record version
    AllowHung,          \* a window's app can never answer Accessibility
    AllowLayoutLag      \* a crash can come before the layout write

Incarnations == 1..(MaxEvents + 1)
Phases == {"none", "watch", "grace", "done"}
Ops == {"none", "show", "hide"}

VARIABLES
    held,       \* [Win -> BOOLEAN]: in the holding Space
    recSpace,   \* the record names the holding Space
    recWins,    \* the windows the record names
    mark,       \* the record is marked handed over
    saved,      \* the workspace the saved layout shows
    kos,        \* "down" or "running"
    inc,        \* the running or last Kosmos
    shown,      \* the running Kosmos's shown workspace
    pending,    \* [Win -> Ops]: the operation queued on the bridge for each window
    admitted,   \* windows the running Kosmos admitted
    adopted,    \* windows taken over concealed and not yet admitted
    hung,       \* windows whose app never answers in this run
    stale,      \* the saved layout lacks the last switch
    launch,     \* the start on its way: "none", "prompt" or "late"
    reads,      \* the build that starts next reads the record
    gs,         \* [Incarnations -> Phases]: each Kosmos's guardian
    events,
    gap,        \* ghost: from an exit with a prompt start until the successor's first input
    exitHeld    \* ghost: the windows concealed at that exit

vars == <<held, recSpace, recWins, mark, saved, kos, inc, shown, pending, admitted, adopted, hung, stale,
          launch, reads, gs, events, gap, exitHeld>>

NoOps == [w \in Win |-> "none"]

\* What the operations queued at an exit would leave, once landed.
Landed == [w \in Win |-> IF pending[w] = "none" THEN held[w] ELSE pending[w] = "hide"]

\* The operation that takes w to where workspace k being shown puts it.
Want(w, k) == IF held[w] = (HomeOf[w] # k) THEN "none" ELSE IF HomeOf[w] # k THEN "hide" ELSE "show"

\* Every step restores only windows the record names.
Restore == [w \in Win |-> IF w \in recWins THEN FALSE ELSE held[w]]

Init ==
    /\ held = [w \in Win |-> FALSE]
    /\ recSpace = FALSE /\ recWins = {} /\ mark = FALSE
    /\ saved = FirstShown
    /\ kos = "down" /\ inc = 0 /\ shown = FirstShown
    /\ pending = NoOps /\ admitted = {} /\ adopted = {} /\ hung = {} /\ stale = FALSE
    /\ launch = "prompt" /\ reads = TRUE
    /\ gs = [i \in Incarnations |-> "none"]
    /\ events = 0 /\ gap = FALSE /\ exitHeld = {}

(***************************************************************************)
(* A start: the guardian first, then the lock, then the record.            *)
(***************************************************************************)
Start ==
    /\ kos = "down" /\ launch # "none"
    \* Without the grace, the guardian holds the lock for its recovery first.
    /\ Grace \/ \A i \in Incarnations : gs[i] # "grace"
    /\ inc' = inc + 1
    /\ gs' = [gs EXCEPT ![inc + 1] = "watch"]
    /\ kos' = "running" /\ shown' = saved /\ launch' = "none" /\ reads' = TRUE
    /\ hung' \in IF AllowHung THEN {{}} \cup {{w} : w \in Win} ELSE {{}}
    /\ admitted' = {} /\ pending' = NoOps /\ stale' = FALSE
    /\ IF reads /\ recSpace
       THEN IF Adopt
            THEN LET kept == {w \in recWins : held[w] /\ HomeOf[w] # saved}
                 IN /\ held' = [w \in Win |-> IF w \in recWins THEN w \in kept ELSE held[w]]
                    /\ recWins' = kept /\ recSpace' = (kept # {}) /\ mark' = FALSE
                    /\ adopted' = kept
            ELSE /\ held' = Restore
                 /\ recWins' = {} /\ recSpace' = FALSE /\ mark' = FALSE /\ adopted' = {}
       \* A record of another version reads as none, and the first conceal replaces it.
       ELSE /\ recWins' = {} /\ recSpace' = FALSE /\ mark' = FALSE /\ adopted' = {}
            /\ UNCHANGED held
    /\ UNCHANGED <<saved, events, gap, exitHeld>>

(***************************************************************************)
(* The running Kosmos.                                                     *)
(***************************************************************************)
\* Records the windows `ops` conceals before any conceal is sent.
Queue(ops) ==
    /\ pending' = ops
    /\ recWins' = recWins \cup {w \in Win : ops[w] = "hide"}
    /\ recSpace' = (recSpace \/ \E w \in Win : ops[w] = "hide")

Admit(w) ==
    /\ kos = "running" /\ w \notin admitted \cup hung
    /\ admitted' = admitted \cup {w}
    /\ adopted' = adopted \ {w}
    /\ LET op == IF ~AdmitReveal /\ held[w] /\ HomeOf[w] = shown THEN pending[w] ELSE Want(w, shown)
       IN Queue([pending EXCEPT ![w] = op])
    /\ UNCHANGED <<held, mark, saved, kos, inc, shown, hung, stale, launch, reads, gs, events, gap, exitHeld>>

Apply(w) ==
    /\ kos = "running" /\ pending[w] # "none"
    /\ held' = [held EXCEPT ![w] = pending[w] = "hide"]
    /\ pending' = [pending EXCEPT ![w] = "none"]
    /\ UNCHANGED <<recSpace, recWins, mark, saved, kos, inc, shown, admitted, adopted, hung, stale, launch, reads, gs,
                   events, gap, exitHeld>>

\* The layout's second-later write; without AllowLayoutLag a switch writes it at once.
WriteLayout ==
    /\ kos = "running" /\ stale
    /\ saved' = shown /\ stale' = FALSE
    /\ UNCHANGED <<held, recSpace, recWins, mark, kos, inc, pending, admitted, adopted, hung, shown, launch, reads, gs,
                   events, gap, exitHeld>>

\* Once every window whose app answers is admitted, a window taken over and never
\* admitted shows where it is.
RevealUnadmitted ==
    /\ kos = "running" /\ Backstop /\ adopted # {} /\ Win \ hung \subseteq admitted
    /\ adopted' = {}
    /\ pending' = [w \in Win |-> IF w \in adopted /\ held[w] THEN "show" ELSE pending[w]]
    /\ UNCHANGED <<held, recSpace, recWins, mark, saved, kos, inc, shown, admitted, hung, stale, launch, reads, gs,
                   events, gap, exitHeld>>

Switch(k) ==
    /\ kos = "running" /\ k # shown /\ events < MaxEvents
    /\ events' = events + 1 /\ gap' = FALSE
    /\ shown' = k
    /\ IF AllowLayoutLag THEN stale' = TRUE /\ UNCHANGED saved ELSE saved' = k /\ UNCHANGED stale
    /\ Queue([w \in Win |-> IF w \in admitted THEN Want(w, k) ELSE pending[w]])
    /\ UNCHANGED <<held, mark, kos, inc, admitted, adopted, hung, launch, reads, gs, exitHeld>>

(***************************************************************************)
(* Exits.                                                                  *)
(***************************************************************************)
\* The batches land and the layout is written, then quit recovery restores every window.
Quit ==
    /\ kos = "running" /\ events < MaxEvents
    /\ events' = events + 1 /\ gap' = FALSE
    /\ held' = [w \in Win |-> IF w \in recWins THEN FALSE ELSE Landed[w]]
    /\ recWins' = {} /\ recSpace' = FALSE /\ mark' = FALSE
    /\ saved' = shown /\ stale' = FALSE
    /\ kos' = "down" /\ pending' = NoOps
    \* A quit for good, or an install over a Kosmos that did not take the arm.
    /\ launch' \in {"none", "prompt"} /\ reads' = TRUE
    /\ gs' = [gs EXCEPT ![inc] = "done"]
    /\ UNCHANGED <<inc, shown, admitted, adopted, hung, exitHeld>>

\* `kosmos handover` then SIGTERM, as script/install.sh sends: the batches land, the layout is
\* written, and the record is marked and left.
HandOver ==
    /\ kos = "running" /\ events < MaxEvents
    /\ reads' \in IF AllowUnreadable THEN BOOLEAN ELSE {TRUE}
    /\ Gate => reads'
    /\ events' = events + 1
    /\ held' = Landed /\ pending' = NoOps
    /\ mark' = recSpace
    /\ saved' = shown /\ stale' = FALSE
    /\ kos' = "down"
    /\ launch' \in {"prompt", "late", "none"}
    /\ gs' = [gs EXCEPT ![inc] = IF recSpace THEN "grace" ELSE "done"]
    /\ gap' = (launch' = "prompt") /\ exitHeld' = {w \in Win : Landed[w]}
    /\ UNCHANGED <<recSpace, recWins, inc, shown, admitted, adopted, hung>>

\* launchd starts the same build: at once after a run of 30 s or more, after its throttle
\* otherwise, and never with Launch at Login off.
Crash ==
    /\ kos = "running" /\ events < MaxEvents
    /\ events' = events + 1
    /\ kos' = "down" /\ pending' = NoOps
    /\ launch' \in {"prompt", "late", "none"} /\ reads' = TRUE
    /\ gs' = [gs EXCEPT ![inc] = IF recSpace THEN "grace" ELSE "done"]
    /\ gap' = (launch' = "prompt") /\ exitHeld' = {w \in Win : held[w]}
    /\ UNCHANGED <<held, recSpace, recWins, mark, saved, inc, shown, admitted, adopted, hung, stale>>

(***************************************************************************)
(* Guardians of Kosmos that exited.                                        *)
(***************************************************************************)
\* A Kosmos holds the lock, so the record is its.
GuardianLeaves(i) ==
    /\ gs[i] = "grace" /\ kos = "running"
    /\ gs' = [gs EXCEPT ![i] = "done"]
    /\ UNCHANGED <<held, recSpace, recWins, mark, saved, kos, inc, shown, pending, admitted, adopted, hung, stale,
                   launch, reads, events, gap, exitHeld>>

\* No Kosmos took the lock within the grace: recovery under the lock, then out.
GraceEnds(i) ==
    /\ gs[i] = "grace" /\ kos = "down"
    /\ ~Grace \/ launch # "prompt"
    /\ held' = Restore
    /\ recWins' = {} /\ recSpace' = FALSE /\ mark' = FALSE
    /\ gs' = [gs EXCEPT ![i] = "done"]
    /\ UNCHANGED <<saved, kos, inc, shown, pending, admitted, adopted, hung, stale, launch, reads, events, gap, exitHeld>>

Next ==
    \/ Start \/ WriteLayout \/ RevealUnadmitted \/ Quit \/ HandOver \/ Crash
    \/ \E w \in Win : Admit(w) \/ Apply(w)
    \/ \E k \in Workspaces : Switch(k)
    \/ \E i \in Incarnations : GuardianLeaves(i) \/ GraceEnds(i)

Fairness ==
    /\ WF_vars(Start) /\ WF_vars(WriteLayout) /\ WF_vars(RevealUnadmitted)
    /\ \A w \in Win : WF_vars(Admit(w)) /\ WF_vars(Apply(w))
    /\ \A i \in Incarnations : WF_vars(GuardianLeaves(i)) /\ WF_vars(GraceEnds(i))

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ Fairness

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)
TypeOK ==
    /\ held \in [Win -> BOOLEAN] /\ recSpace \in BOOLEAN /\ recWins \subseteq Win /\ mark \in BOOLEAN
    /\ saved \in Workspaces /\ kos \in {"down", "running"} /\ inc \in 0..(MaxEvents + 1) /\ shown \in Workspaces
    /\ pending \in [Win -> Ops] /\ admitted \subseteq Win /\ adopted \subseteq Win /\ hung \subseteq Win
    /\ stale \in BOOLEAN /\ launch \in {"none", "prompt", "late"} /\ reads \in BOOLEAN
    /\ gs \in [Incarnations -> Phases] /\ events \in 0..MaxEvents /\ gap \in BOOLEAN /\ exitHeld \subseteq Win

\* Recovery finds every concealed window from the record.
RecordedBeforeHide == \A w \in Win : held[w] => recSpace /\ w \in recWins

\* With no Kosmos running, none on its way and every guardian done, nothing is concealed.
NeverStranded ==
    kos = "down" /\ launch = "none" /\ (\A i \in Incarnations : gs[i] \in {"none", "done"})
        => \A w \in Win : ~held[w]

\* Across a restart whose start comes within the grace, each window concealed at the exit
\* stays concealed while the saved layout keeps its workspace hidden, until the next input,
\* unless its app never answers.
KeepsHidden == gap => \A w \in exitHeld \ hung : HomeOf[w] # saved => held[w]

\* Once the running Kosmos has admitted every window it can and its batches have landed,
\* exactly the admitted windows of hidden workspaces are concealed.
Settled ==
    /\ kos = "running" /\ Win \ hung \subseteq admitted /\ \A w \in Win : pending[w] = "none"
    /\ ~(Backstop /\ adopted # {})
ConvergesWhenSettled == Settled => \A w \in Win : held[w] = (w \in admitted /\ HomeOf[w] # shown)

Quiescent == kos = "down" /\ launch = "none" /\ \A i \in Incarnations : gs[i] \in {"none", "done"}
Stabilizes == <>[](Settled \/ Quiescent)
=============================================================================
