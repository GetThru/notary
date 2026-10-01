---- MODULE Counter ----
EXTENDS Naturals
CONSTANT Max
VARIABLE x

TypeOK == x \in 0..Max

Init == x = 0

Inc == /\ x < Max
       /\ x' = x + 1

Reset == x' = 0

Next == Inc \/ Reset

Spec == Init /\ [][Next]_x
====
