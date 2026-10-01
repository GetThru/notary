---- MODULE Bank ----
EXTENDS Naturals
CONSTANT MaxBal
VARIABLES balance, lastOp

TypeOK == /\ balance \in 0..MaxBal
          /\ lastOp \in {"none", "deposit", "withdraw"}

Init == balance = 0 /\ lastOp = "none"

Deposit(a) == /\ balance + a <= MaxBal
              /\ balance' = balance + a
              /\ lastOp' = "deposit"

Withdraw(a) == /\ a <= balance
               /\ balance' = balance - a
               /\ lastOp' = "withdraw"

Next == \E a \in 1..2 : Deposit(a) \/ Withdraw(a)

Spec == Init /\ [][Next]_<<balance, lastOp>>
====
