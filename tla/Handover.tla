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
(* crash can lose the last switch. Kosmos conceals only while its         *)
(* guardian is ready; here it admits nothing and takes no switch while    *)
(* the guardian is not.                                                    *)
(*                                                                         *)
(* Kosmos ends in one of three ways. A plain quit lands the queued         *)
(* batches, writes the layout and restores every concealed window. A quit *)
(* that `kosmos handover` armed lands the batches and writes the layout,  *)
(* then leaves the windows concealed. With Gate, each arm replaces the    *)
(* last and stands only when the build it names reads the record. With    *)
(* Expiry, the arm lapses once its moment passes; without, it goes stale   *)
(* and stays, and the build that starts after its quit is any build. With *)
(* ReadyGate, an armed quit hands over only while the guardian is ready.  *)
(* A crash drops the batches not yet applied.                              *)
(*                                                                         *)
(* Once a Kosmos exits and a record is left, its guardian waits for a     *)
(* successor, and leaves the record to a Kosmos that names itself in the  *)
(* lock file (GuardianLeaves). With KosmosOnly it leaves for nothing else; *)
(* without, it leaves for any holder of the lock, as a Kosmos not yet      *)
(* named or a probe. If no Kosmos names itself within the grace, the       *)
(* guardian restores every recorded window under the lock (GraceEnds).    *)
(* Without Grace it restores them at once, before any successor can take  *)
(* the lock. A start is on its way after the exit: `prompt` names itself  *)
(* within the grace of every guardian waiting, `late` comes after it, as  *)
(* launchd's throttle makes one, or `none`, as after a quit for good or    *)
(* with Launch at Login off. The guardians waiting all act alike, so the  *)
(* model counts them.                                                      *)
(*                                                                         *)
(* A start takes the lock (Lock), spawns its guardian (GuardianStart),     *)
(* names itself in the lock file (Name) and takes the record over         *)
(* (TakeOver), and it can crash between any two. With ReadyGate it names  *)
(* itself and takes over only with its guardian ready, and otherwise      *)
(* restores every recorded window first (Recover); without Adopt it       *)
(* always recovers, as startup recovery did. The take-over keeps each     *)
(* recorded window concealed. A build that cannot read the record finds   *)
(* nothing recorded. On admission, a concealed window whose workspace is  *)
(* shown is revealed (AdmitReveal). The backstop reveals every window     *)
(* taken over and not yet admitted, at any point after the take-over, as  *)
(* Kosmos does 5 s after it (Backstop).                                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Win, Workspaces, HomeOf, FirstShown,
    MaxEvents,              \* switches, exits, guardian deaths and probes, together
    Adopt, Grace, Gate, Expiry, KosmosOnly, ReadyGate, AdmitReveal, Backstop,
    AllowUnreadable,        \* the next build can read another record version
    AllowHung,              \* a window's app can never answer Accessibility
    AllowLayoutLag,         \* a crash can come before the layout write
    AllowGuardianFailure,   \* a guardian can fail to start, or die while its Kosmos runs
    AllowProbe              \* another process can hold the instance lock

Ops == {"none", "show", "hide"}

VARIABLES
    held,       \* [Win -> BOOLEAN]: in the holding Space
    recSpace,   \* the record names the holding Space
    recWins,    \* the windows the record names
    saved,      \* the workspace the saved layout shows
    kos,        \* "down", or how far the Kosmos got: "locked", "guarded", "named", "running"
    guard,      \* its guardian: "none" before the spawn, "watch" once ready, "failed" when it
                \* never got ready, "dead" when it died after, until the respawn
    waiting,    \* guardians of Kosmos that exited, in their grace
    shown,      \* the running Kosmos's shown workspace
    pending,    \* [Win -> Ops]: the operation queued on the bridge for each window
    admitted,   \* windows the running Kosmos admitted
    adopted,    \* windows taken over concealed and not yet admitted
    hung,       \* windows whose app never answers in this run
    stale,      \* the saved layout lacks the last switch
    arm,        \* "none", "fresh" within its moment, or "stale" past it
    armReads,   \* the build the arm names reads the record
    launch,     \* the start on its way: "none", "prompt" or "late"
    reads,      \* the build that starts next reads the record
    probe,      \* another process holds the lock
    events,
    gap,        \* ghost: from an exit with a prompt start until the successor's first input
    exitHeld,   \* ghost: the windows concealed at that exit
    revealed    \* ghost: the windows of exitHeld the backstop revealed

vars == <<held, recSpace, recWins, saved, kos, guard, waiting, shown, pending, admitted, adopted, hung, stale,
          arm, armReads, launch, reads, probe, events, gap, exitHeld, revealed>>

NoOps == [w \in Win |-> "none"]
Running == kos = "running"

\* What the operations queued at an exit would leave, once landed.
Landed == [w \in Win |-> IF pending[w] = "none" THEN held[w] ELSE pending[w] = "hide"]

\* The operation that takes w to where workspace k being shown puts it.
Want(w, k) == IF held[w] = (HomeOf[w] # k) THEN "none" ELSE IF HomeOf[w] # k THEN "hide" ELSE "show"

\* Every step restores only windows the record names.
Restore == [w \in Win |-> IF w \in recWins THEN FALSE ELSE held[w]]

\* The guardians waiting once the Kosmos exits: its own joins them while ready and a record
\* is left.
Exited == waiting + (IF guard = "watch" /\ recSpace THEN 1 ELSE 0)

NoGap == gap' = FALSE /\ exitHeld' = {} /\ revealed' = {}

Init ==
    /\ held = [w \in Win |-> FALSE]
    /\ recSpace = FALSE /\ recWins = {}
    /\ saved = FirstShown
    /\ kos = "down" /\ guard = "none" /\ waiting = 0 /\ shown = FirstShown
    /\ pending = NoOps /\ admitted = {} /\ adopted = {} /\ hung = {} /\ stale = FALSE
    /\ arm = "none" /\ armReads = TRUE
    /\ launch = "prompt" /\ reads = TRUE /\ probe = FALSE
    /\ events = 0 /\ gap = FALSE /\ exitHeld = {} /\ revealed = {}

(***************************************************************************)
(* A start, step by step.                                                  *)
(***************************************************************************)
\* Without the grace, a guardian holds the lock for its recovery first.
Lock ==
    /\ kos = "down" /\ launch # "none" /\ ~probe
    /\ Grace \/ waiting = 0
    /\ kos' = "locked" /\ shown' = saved
    /\ hung' \in IF AllowHung THEN {{}} \cup {{w} : w \in Win} ELSE {{}}
    /\ admitted' = {} /\ adopted' = {} /\ pending' = NoOps /\ stale' = FALSE
    /\ UNCHANGED <<held, recSpace, recWins, saved, guard, waiting, arm, armReads, launch, reads, probe, events,
                   gap, exitHeld, revealed>>

GuardianStart ==
    /\ kos = "locked"
    /\ kos' = "guarded"
    /\ guard' \in IF AllowGuardianFailure THEN {"watch", "failed"} ELSE {"watch"}
    /\ UNCHANGED <<held, recSpace, recWins, saved, waiting, shown, pending, admitted, adopted, hung, stale, arm,
                   armReads, launch, reads, probe, events, gap, exitHeld, revealed>>

\* The guardians waiting may leave from here on.
Name ==
    /\ kos = "guarded" /\ Adopt /\ (guard = "watch" \/ ~ReadyGate)
    /\ kos' = "named" /\ launch' = "none"
    /\ UNCHANGED <<held, recSpace, recWins, saved, guard, waiting, shown, pending, admitted, adopted, hung, stale,
                   arm, armReads, reads, probe, events, gap, exitHeld, revealed>>

\* Recovery sparing every recorded window, which restores only windows not concealed here.
\* A record of another version reads as none, and the first conceal replaces it.
TakeOver ==
    /\ kos = "named"
    /\ kos' = "running"
    /\ LET kept == IF reads /\ recSpace THEN {w \in recWins : held[w]} ELSE {}
       IN /\ recWins' = kept /\ recSpace' = (kept # {}) /\ adopted' = kept
    /\ UNCHANGED <<held, saved, guard, waiting, shown, pending, admitted, hung, stale, arm, armReads, launch, reads,
                   probe, events, gap, exitHeld, revealed>>

\* Startup recovery, then the name. A flash after a guardian that failed to start is excused.
Recover ==
    /\ kos = "guarded" /\ (~Adopt \/ (ReadyGate /\ guard # "watch"))
    /\ held' = IF reads THEN Restore ELSE held
    /\ recWins' = {} /\ recSpace' = FALSE
    /\ kos' = "running" /\ launch' = "none"
    /\ IF guard # "watch" THEN NoGap ELSE UNCHANGED <<gap, exitHeld, revealed>>
    /\ UNCHANGED <<saved, guard, waiting, shown, pending, admitted, adopted, hung, stale, arm, armReads, reads, probe,
                   events>>

(***************************************************************************)
(* The running Kosmos.                                                     *)
(***************************************************************************)
\* Records the windows `ops` conceals before any conceal is sent.
Queue(ops) ==
    /\ pending' = ops
    /\ recWins' = recWins \cup {w \in Win : ops[w] = "hide"}
    /\ recSpace' = (recSpace \/ \E w \in Win : ops[w] = "hide")

Admit(w) ==
    /\ Running /\ guard = "watch" /\ w \notin admitted \cup hung
    /\ admitted' = admitted \cup {w}
    /\ adopted' = adopted \ {w}
    /\ LET op == IF ~AdmitReveal /\ held[w] /\ HomeOf[w] = shown THEN pending[w] ELSE Want(w, shown)
       IN Queue([pending EXCEPT ![w] = op])
    /\ UNCHANGED <<held, saved, kos, guard, waiting, shown, hung, stale, arm, armReads, launch, reads, probe, events,
                   gap, exitHeld, revealed>>

Apply(w) ==
    /\ Running /\ pending[w] # "none"
    /\ held' = [held EXCEPT ![w] = pending[w] = "hide"]
    /\ pending' = [pending EXCEPT ![w] = "none"]
    /\ UNCHANGED <<recSpace, recWins, saved, kos, guard, waiting, shown, admitted, adopted, hung, stale, arm, armReads,
                   launch, reads, probe, events, gap, exitHeld, revealed>>

\* The layout's second-later write; without AllowLayoutLag a switch writes it at once.
WriteLayout ==
    /\ Running /\ stale
    /\ saved' = shown /\ stale' = FALSE
    /\ UNCHANGED <<held, recSpace, recWins, kos, guard, waiting, shown, pending, admitted, adopted, hung, arm, armReads,
                   launch, reads, probe, events, gap, exitHeld, revealed>>

\* A window taken over and not yet admitted shows where it is.
RevealUnadmitted ==
    /\ Running /\ Backstop /\ adopted # {}
    /\ adopted' = {}
    /\ pending' = [w \in Win |-> IF w \in adopted /\ held[w] THEN "show" ELSE pending[w]]
    /\ revealed' = IF gap THEN revealed \cup {w \in adopted : held[w]} ELSE {}
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, guard, waiting, shown, admitted, hung, stale, arm, armReads,
                   launch, reads, probe, events, gap, exitHeld>>

Switch(k) ==
    /\ Running /\ guard = "watch" /\ k # shown /\ events < MaxEvents
    /\ events' = events + 1 /\ NoGap
    /\ shown' = k
    /\ IF AllowLayoutLag THEN stale' = TRUE /\ UNCHANGED saved ELSE saved' = k /\ UNCHANGED stale
    /\ Queue([w \in Win |-> IF w \in admitted THEN Want(w, k) ELSE pending[w]])
    /\ UNCHANGED <<held, kos, guard, waiting, admitted, adopted, hung, arm, armReads, launch, reads, probe>>

\* `kosmos handover [record version]`, where the build the version names reads the record, or not.
Arm ==
    /\ Running
    /\ \E v \in IF AllowUnreadable THEN BOOLEAN ELSE {TRUE} :
          IF Gate /\ ~v THEN arm' = "none" /\ armReads' = TRUE ELSE arm' = "fresh" /\ armReads' = v
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, guard, waiting, shown, pending, admitted, adopted, hung, stale,
                   launch, reads, probe, events, gap, exitHeld, revealed>>

Expire ==
    /\ arm = "fresh"
    /\ IF Expiry THEN arm' = "none" /\ armReads' = TRUE ELSE arm' = "stale" /\ UNCHANGED armReads
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, guard, waiting, shown, pending, admitted, adopted, hung, stale,
                   launch, reads, probe, events, gap, exitHeld, revealed>>

\* A guardian's death while its Kosmos runs; Kosmos respawns it a second later.
GuardianDies ==
    /\ AllowGuardianFailure /\ Running /\ guard = "watch" /\ events < MaxEvents
    /\ guard' = "dead" /\ events' = events + 1
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, waiting, shown, pending, admitted, adopted, hung, stale, arm,
                   armReads, launch, reads, probe, gap, exitHeld, revealed>>

Respawn ==
    /\ Running /\ guard \in {"failed", "dead"}
    /\ guard' = "watch"
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, waiting, shown, pending, admitted, adopted, hung, stale, arm,
                   armReads, launch, reads, probe, events, gap, exitHeld, revealed>>

(***************************************************************************)
(* Exits.                                                                  *)
(***************************************************************************)
Handing == arm # "none" /\ (guard = "watch" \/ ~ReadyGate)

\* The batches land and the layout is written, then quit recovery restores every window.
Quit ==
    /\ Running /\ ~Handing /\ events < MaxEvents
    /\ events' = events + 1 /\ NoGap
    /\ held' = [w \in Win |-> IF w \in recWins THEN FALSE ELSE Landed[w]]
    /\ recWins' = {} /\ recSpace' = FALSE
    /\ saved' = shown /\ stale' = FALSE
    /\ kos' = "down" /\ guard' = "none" /\ pending' = NoOps /\ arm' = "none" /\ armReads' = TRUE
    \* A quit for good, or an install over a Kosmos that did not take the arm.
    /\ launch' \in {"none", "prompt"} /\ reads' = TRUE
    /\ UNCHANGED <<waiting, shown, admitted, adopted, hung, probe>>

\* The armed quit, as script/install.sh's SIGTERM right after its arm: the batches land, the
\* layout is written, and the record is left. While the arm is fresh, the build that starts
\* next is the one it named.
HandOver ==
    /\ Running /\ Handing /\ events < MaxEvents
    /\ events' = events + 1
    /\ held' = Landed /\ pending' = NoOps
    /\ saved' = shown /\ stale' = FALSE
    /\ kos' = "down" /\ guard' = "none" /\ waiting' = Exited
    /\ reads' \in IF arm = "fresh" THEN {armReads} ELSE IF AllowUnreadable THEN BOOLEAN ELSE {TRUE}
    /\ arm' = "none" /\ armReads' = TRUE
    /\ launch' \in {"prompt", "late", "none"}
    /\ gap' = (launch' = "prompt")
    /\ exitHeld' = IF gap' THEN {w \in Win : Landed[w]} ELSE {}
    /\ revealed' = {}
    /\ UNCHANGED <<recSpace, recWins, shown, admitted, adopted, hung, probe>>

\* At any step of a start or a run, except in the second a dead guardian takes to respawn:
\* a crash then leaves the windows concealed since with no guardian, a ceiling that
\* predates the handover. launchd starts the same build: at once after a run of 30 s or
\* more, after its throttle otherwise, and never with Launch at Login off.
Crash ==
    /\ kos # "down" /\ guard # "dead" /\ events < MaxEvents
    /\ events' = events + 1
    /\ kos' = "down" /\ guard' = "none" /\ waiting' = Exited /\ pending' = NoOps
    /\ arm' = "none" /\ armReads' = TRUE
    /\ launch' \in {"prompt", "late", "none"} /\ reads' = TRUE
    /\ gap' = (launch' = "prompt")
    /\ exitHeld' = IF gap' THEN {w \in Win : held[w]} ELSE {}
    /\ revealed' = {}
    /\ UNCHANGED <<held, recSpace, recWins, saved, shown, admitted, adopted, hung, stale, probe>>

(***************************************************************************)
(* Guardians of Kosmos that exited, and another holder of the lock.        *)
(***************************************************************************)
GuardianLeaves ==
    /\ waiting > 0
    /\ kos \in {"named", "running"} \/ (~KosmosOnly /\ (probe \/ kos \in {"locked", "guarded"}))
    /\ waiting' = waiting - 1
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, guard, shown, pending, admitted, adopted, hung, stale, arm,
                   armReads, launch, reads, probe, events, gap, exitHeld, revealed>>

\* No Kosmos named itself within the grace: recovery under the lock, then out.
GraceEnds ==
    /\ waiting > 0 /\ kos = "down" /\ ~probe
    /\ ~Grace \/ launch # "prompt"
    /\ held' = Restore
    /\ recWins' = {} /\ recSpace' = FALSE
    /\ waiting' = waiting - 1
    /\ UNCHANGED <<saved, kos, guard, shown, pending, admitted, adopted, hung, stale, arm, armReads, launch, reads,
                   probe, events, gap, exitHeld, revealed>>

\* As `kosmos-probe survive-kill`, which takes the lock and names nothing.
ProbeTakes ==
    /\ AllowProbe /\ ~probe /\ kos = "down" /\ events < MaxEvents
    /\ probe' = TRUE /\ events' = events + 1 /\ NoGap
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, guard, waiting, shown, pending, admitted, adopted, hung, stale,
                   arm, armReads, launch, reads>>

ProbeReleases ==
    /\ probe
    /\ probe' = FALSE
    /\ UNCHANGED <<held, recSpace, recWins, saved, kos, guard, waiting, shown, pending, admitted, adopted, hung, stale,
                   arm, armReads, launch, reads, events, gap, exitHeld, revealed>>

Next ==
    \/ Lock \/ GuardianStart \/ Name \/ TakeOver \/ Recover
    \/ WriteLayout \/ RevealUnadmitted \/ Arm \/ Expire \/ GuardianDies \/ Respawn
    \/ Quit \/ HandOver \/ Crash
    \/ \E w \in Win : Admit(w) \/ Apply(w)
    \/ \E k \in Workspaces : Switch(k)
    \/ GuardianLeaves \/ GraceEnds \/ ProbeTakes \/ ProbeReleases

Fairness ==
    /\ WF_vars(Lock) /\ WF_vars(GuardianStart) /\ WF_vars(Name) /\ WF_vars(TakeOver) /\ WF_vars(Recover)
    /\ WF_vars(WriteLayout) /\ WF_vars(RevealUnadmitted) /\ WF_vars(Respawn)
    /\ \A w \in Win : WF_vars(Admit(w)) /\ WF_vars(Apply(w))
    /\ WF_vars(GuardianLeaves) /\ WF_vars(GraceEnds) /\ WF_vars(ProbeReleases)

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ Fairness

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)
TypeOK ==
    /\ held \in [Win -> BOOLEAN] /\ recSpace \in BOOLEAN /\ recWins \subseteq Win /\ saved \in Workspaces
    /\ kos \in {"down", "locked", "guarded", "named", "running"} /\ guard \in {"none", "watch", "failed", "dead"}
    /\ waiting \in 0..MaxEvents /\ shown \in Workspaces /\ pending \in [Win -> Ops] /\ admitted \subseteq Win
    /\ adopted \subseteq Win /\ hung \subseteq Win /\ stale \in BOOLEAN /\ arm \in {"none", "fresh", "stale"}
    /\ armReads \in BOOLEAN /\ launch \in {"none", "prompt", "late"} /\ reads \in BOOLEAN /\ probe \in BOOLEAN
    /\ events \in 0..MaxEvents /\ gap \in BOOLEAN /\ exitHeld \subseteq Win /\ revealed \subseteq Win

\* Recovery finds every concealed window from the record.
RecordedBeforeHide == \A w \in Win : held[w] => recSpace /\ w \in recWins

\* With no Kosmos running, none on its way, no other holder of the lock and no guardian
\* waiting, nothing is concealed.
Quiescent == kos = "down" /\ launch = "none" /\ ~probe /\ waiting = 0
NeverStranded == Quiescent => \A w \in Win : ~held[w]

\* Across a restart whose start comes within the grace, each window concealed at the exit
\* stays concealed while the saved layout keeps its workspace hidden, until the next input,
\* unless the backstop reveals it or the next Kosmos's guardian fails to start.
KeepsHidden == gap => \A w \in exitHeld \ revealed : HomeOf[w] # saved => held[w]

\* Once the running Kosmos has admitted every window it can and its batches have landed,
\* exactly the admitted windows of hidden workspaces are concealed.
Settled ==
    /\ Running /\ Win \ hung \subseteq admitted /\ \A w \in Win : pending[w] = "none"
    /\ ~(Backstop /\ adopted # {})
ConvergesWhenSettled == Settled => \A w \in Win : held[w] = (w \in admitted /\ HomeOf[w] # shown)

Stabilizes == <>[](Settled \/ Quiescent)
=============================================================================
