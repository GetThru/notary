---- MODULE Workflow ----
CONSTANT Users
VARIABLES status, gateway

TypeOK == /\ status \in [Users -> {"cart", "paid", "shipped"}]
          /\ gateway \in {"up", "down"}

Init == /\ status = [u \in Users |-> "cart"]
        /\ gateway = "up"

Pay(u) == /\ status[u] = "cart"
          /\ gateway = "up"
          /\ status' = [status EXCEPT ![u] = "paid"]
          /\ UNCHANGED gateway

Ship(u) == /\ status[u] = "paid"
           /\ status' = [status EXCEPT ![u] = "shipped"]
           /\ UNCHANGED gateway

GatewayDown == /\ gateway = "up"
               /\ gateway' = "down"
               /\ UNCHANGED status

GatewayUp == /\ gateway = "down"
             /\ gateway' = "up"
             /\ UNCHANGED status

Next == \/ \E u \in Users : Pay(u) \/ Ship(u)
        \/ GatewayDown
        \/ GatewayUp

Spec == Init /\ [][Next]_<<status, gateway>>
====
