---- MODULE Inv ----
EXTENDS Naturals
VARIABLE x
Small == x < 2
Init == x = 0
Next == x' = x + 1
====
