---- MODULE Async ----
VARIABLE status
TypeOK == status \in {"idle", "pending", "done"}
Init == status = "idle"
Request == /\ status \in {"idle", "done"}
           /\ status' = "pending"
Complete == /\ status = "pending"
            /\ status' = "done"
Next == Request \/ Complete
Spec == Init /\ [][Next]_status
====
