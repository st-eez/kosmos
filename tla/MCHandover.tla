------------------------------ MODULE MCHandover ------------------------------
(* One display and three workspaces, one window on each; workspace 1 shows   *)
(* first.                                                                     *)
EXTENDS Handover
MC_Win == {"w1", "w2", "w3"}
MC_HomeOf == [w \in MC_Win |-> CASE w = "w1" -> 1 [] w = "w2" -> 2 [] OTHER -> 3]
===============================================================================
