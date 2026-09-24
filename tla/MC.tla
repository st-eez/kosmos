---------------------------------- MODULE MC ----------------------------------
(* Small topology: workspace 1 = {w1, w2}, workspace 2 = {w3}, workspace 3   *)
(* empty. App A owns w1 and w3, app B owns w2.                               *)
EXTENDS Kosmos
MC_Win == {"w1", "w2", "w3"}
MC_WsOf == [w \in MC_Win |-> IF w = "w3" THEN 2 ELSE 1]
MC_AppOf == [w \in MC_Win |-> IF w = "w2" THEN "B" ELSE "A"]
===============================================================================
