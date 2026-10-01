----------------------------- MODULE TLCRunner -----------------------------
\* Outlaw.Tools.TLCRunner: runs one TLC model check as an OS process.
\*
\* Each run has its own runner process (not linked to the caller) that owns
\* the TLC port: it reads TLC's output, enforces the state limit and the
\* timeout, and sends the result to the caller. It also watches the caller:
\* if the caller dies mid-run, it kills the Java process (Reap), so TLC is
\* never orphaned (the bug deferred from Phase 1 as ruling R10).
\*
\* External effects (modeled as actions, driven by stubs in the mapping):
\*   Progress   - TLC reports one more distinct state
\*   Exit       - TLC finishes on its own
\*   Timeout    - the wall clock passes the deadline
\*   CallerDies - the calling Elixir process crashes
\*
\* The caller can also stop a run on purpose (Cancel).
EXTENDS Naturals

CONSTANT Limit          \* max distinct states before the runner kills TLC

VARIABLES os,           \* the Java OS process
          caller,       \* the Elixir process that started the run
          seen,         \* distinct states TLC has reported so far
          result        \* the result delivered to the caller

vars == <<os, caller, seen, result>>

TypeOK == /\ os \in {"none", "alive", "exited", "killed"}
          /\ caller \in {"alive", "dead"}
          /\ seen \in 0..(Limit + 1)
          /\ result \in {"none", "ok", "timeout", "too_many_states", "cancelled"}

Init == /\ os = "none"
        /\ caller = "alive"
        /\ seen = 0
        /\ result = "none"

\* The caller starts TLC.
Start == /\ os = "none"
         /\ caller = "alive"
         /\ os' = "alive"
         /\ UNCHANGED <<caller, seen, result>>

\* TLC reports progress (external).
Progress == /\ os = "alive"
            /\ seen <= Limit
            /\ seen' = seen + 1
            /\ UNCHANGED <<os, caller, result>>

\* The runner process sees the count pass the limit and kills TLC. Modeled
\* only while the caller is alive; once it dies, Reap is what stops TLC.
LimitKill == /\ os = "alive"
             /\ caller = "alive"
             /\ seen > Limit
             /\ os' = "killed"
             /\ result' = "too_many_states"
             /\ UNCHANGED <<caller, seen>>

\* TLC finishes on its own (external). The runner reads every output line
\* before the exit status, so an over-limit run is always killed first.
Exit == /\ os = "alive"
        /\ seen <= Limit
        /\ os' = "exited"
        /\ result' = IF caller = "alive" THEN "ok" ELSE result
        /\ UNCHANGED <<caller, seen>>

\* The deadline passes (external); the runner process kills TLC and reports
\* the timeout. Modeled only while the caller is alive (see LimitKill).
Timeout == /\ os = "alive"
           /\ caller = "alive"
           /\ os' = "killed"
           /\ result' = "timeout"
           /\ UNCHANGED <<caller, seen>>

\* The caller stops the run on purpose.
Cancel == /\ os = "alive"
          /\ caller = "alive"
          /\ os' = "killed"
          /\ result' = "cancelled"
          /\ UNCHANGED <<caller, seen>>

\* The calling Elixir process crashes (external).
CallerDies == /\ caller = "alive"
              /\ result = "none"
              /\ caller' = "dead"
              /\ UNCHANGED <<os, seen, result>>

\* The runner process notices the dead caller (watchdog) and kills TLC.
Reap == /\ caller = "dead"
        /\ os = "alive"
        /\ os' = "killed"
        /\ UNCHANGED <<caller, seen, result>>

Next == \/ Start \/ Progress \/ LimitKill \/ Exit
        \/ Timeout \/ Cancel \/ CallerDies \/ Reap

Spec == Init /\ [][Next]_vars /\ WF_vars(Reap)

\* --- Safety -------------------------------------------------------------

\* A result is only returned once TLC is no longer running.
NoResultWhileRunning == result # "none" => os # "alive"

\* "ok" is never returned for a run that exceeded the limit.
LimitRespected == result = "ok" => seen <= Limit

\* A cancelled run really was stopped, not left running or finished.
CancelStops == result = "cancelled" => os = "killed"

\* --- Liveness -----------------------------------------------------------

\* A dead caller never leaves TLC running forever.
NoOrphans == caller = "dead" ~> os # "alive"
=============================================================================
