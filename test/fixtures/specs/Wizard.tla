---- MODULE Wizard ----
\* A three-step checkout wizard: enter an address, review payment, done.
\* Pay must only be possible on the payment step, after an address exists.
VARIABLES step, address

vars == <<step, address>>

TypeOK == /\ step \in {"address", "payment", "done"}
          /\ address \in BOOLEAN

Init == /\ step = "address"
        /\ address = FALSE

EnterAddress == /\ step = "address"
                /\ address' = TRUE
                /\ UNCHANGED step

Continue == /\ step = "address"
            /\ address
            /\ step' = "payment"
            /\ UNCHANGED address

Back == /\ step = "payment"
        /\ step' = "address"
        /\ UNCHANGED address

Pay == /\ step = "payment"
       /\ address
       /\ step' = "done"
       /\ UNCHANGED address

StartOver == /\ step = "done"
             /\ step' = "address"
             /\ address' = FALSE

Next == EnterAddress \/ Continue \/ Back \/ Pay \/ StartOver

Spec == Init /\ [][Next]_vars
====
