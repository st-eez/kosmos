---------------------------------- MODULE MC ----------------------------------
(* Small topology: workspace 1 = {w1, w2}, workspace 2 = {w3}, workspace 3   *)
(* empty. App A owns w1 and w3, app B owns w2.                               *)
EXTENDS Kosmos
MC_Win == {"w1", "w2", "w3"}
MC_WsOf == [w \in MC_Win |-> IF w = "w3" THEN 2 ELSE 1]
MC_AppOf == [w \in MC_Win |-> IF w = "w2" THEN "B" ELSE "A"]
MC_DisplayOf == [k \in Workspaces |-> 1]

(* Two displays: workspaces 1 = {w1} and 2 = {w3} on display 1, workspace 3 = {w2}  *)
(* on display 2. The apps are as above.                                          *)
MD_WsOf == [w \in MC_Win |-> CASE w = "w1" -> 1 [] w = "w3" -> 2 [] OTHER -> 3]
MD_DisplayOf == [k \in Workspaces |-> IF k = 3 THEN 2 ELSE 1]
===============================================================================
