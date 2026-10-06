# Notary Phase 1.5 (first slice): internal actions + TLCRunner against its own spec

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Notary verifies part of itself. The human-authored `specs/TLCRunner.tla` (watchdog + cancel) must pass `mix notary.verify` in the Notary repo.

**Architecture:** Task 1 adds *internal actions* to the conformance runner (design spec §4.3, §5): the implementation may take internal-action steps on its own at any time, so candidate sets are closed under those edges. Task 2 rewrites `Notary.Tools.TLCRunner` as a process that owns the TLC port, monitors its caller (watchdog), supports cancel, and keeps `run/2` as a blocking wrapper; a fake TLC shell script plus a mapping module connect it to the spec.

**Tech Stack:** Elixir 1.19 / OTP 27, StreamData, bash (fake TLC), TLA+ tools v1.7.4.

**Spec:** `docs/superpowers/specs/2026-09-30-notary-design.md` (§4.3 and §5 updated 2026-10-01). The TLA+ spec `specs/TLCRunner.tla` + `.cfg` is human-authored and locked: **never edit it or `specs/.notary.lock`.**

## Global Constraints

- Branch `phase1.5-dogfood`. Run commands as `nix develop -c <cmd>`; TLC tests need `--include tlc`.
- With no internal actions declared, conformance behaviour must be exactly as before — every existing test passes unchanged.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` (dev and `MIX_ENV=test`) stay clean; test output pristine.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- TDD: show a real failing run before each implementation.

---

### Task 1: Internal actions in `Notary.Conformance`

**Files:**
- Modify: `lib/notary/conformance.ex`, `lib/notary/conformance/runner.ex`
- Create: `test/fixtures/specs/Async.tla`, `test/fixtures/specs/Async.cfg`, `test/fixtures/graphs/Async.dot` (via `test/fixtures/regen_graphs.exs`, add `Async` to its list), `test/support/fixtures/async.ex`, `test/support/fixtures/async_specs.ex`
- Test: `test/notary/conformance_test.exs`, `test/notary/conformance/runner_test.exs`

**Interfaces:**
- `use Notary.Conformance, spec:, observe:, discover:, internal: [String.t()]` (default `[]`); `__notary__/0` gains `internal: [...]`.
- `Notary.Conformance.validate/2` additionally fails `:invalid_mapping` when an internal name is not a graph action, or appears as a key of `actions/0`.
- `Notary.Conformance.Runner` reads `module.__notary__().internal` (use `Map.get(..., :internal, [])`).

**Semantics (exactly spec §5):** `closure(S)` = fixpoint of S ∪ successors(s, a) for every internal action `a`.
- Init: `C := {s ∈ closure(initial) : observed(s) = p0}`; step 0 `allowed` = observed projections of `closure(initial)`.
- Each step, `B := closure(C)`; `E := ⋃ successors(b, name)` for b ∈ B.
- Accepted: `E = ∅` → `:action_not_enabled`; else `C := {t ∈ closure(E) : observed(t) = p'}`, empty → `:illegal_transition`; step `allowed` = observed projections of `closure(E)`.
- Rejected: `C := {t ∈ B : observed(t) = p'}`, empty → `:rejected_with_side_effect`; step `allowed` = observed projections of `B`; step `candidates` = new C.
- With `internal: []` this is identical to today's behaviour (check: the rejected rule reduces to `p' == p` because every state in C already projects to p).
- **Settle (end of a successful walk, only when internal actions are declared):** every 10 ms re-project; `C_now := {t ∈ closure(C) : observed(t) = p_now}`; empty → `:illegal_transition`; if some `t ∈ C_now` has no internal action enabled (ignoring internal self-loops) → done; after `settle_timeout` (`Notary.Config` key `settle_timeout`, default `1_000`, overridable via opts `:settle_timeout`) → fail `:internal_action_stalled` with `details: %{pending: [enabled internal action names], settle_timeout: ms}`. Record the settle observation as a final `Step` with `action: "(settle)"`, `params: nil`, `outcome: :ok`. Add `:internal_action_stalled` to `Failure` kinds with explanation "An internal action the spec requires to happen (weak fairness) never did within settle_timeout.". Settle must go through the existing `notify`/`during` mechanism (label `"settle"`) so `action_timeout` still bounds a hanging `project/1`; make sure settle_timeout < action_timeout is not required (each re-projection is its own `call`).

**Fixture spec `Async`:**
```tla
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
```
`Async.cfg`: `INIT Init`, `NEXT Next`, `INVARIANT TypeOK`, `CHECK_DEADLOCK FALSE`.

Implementation `Notary.Fixtures.AsyncJob` (GenServer): `request/1` replies `:ok` and moves to `:pending` only from `:idle`/`:done` (else `{:error, :busy}`), then completes *asynchronously* via `Process.send_after(self(), :complete, delay)` with `delay` random in `0..3` ms, moving to `:done`; `status/1`. A buggy option `complete_to: :idle` makes completion go to `:idle` instead.

Implementation option `never_complete: true` makes the job stay `:pending` forever (models a missing reaction).

Mappings (`async_specs.ex`): `AsyncSpec` (`internal: ["Complete"]`, actions `%{"Request" => StreamData.constant(%{})}`, rejects on `{:error, :busy}`), `AsyncWrongCompletionSpec` (`complete_to: :idle`, `discover: false`), `AsyncStalledSpec` (`never_complete: true`, `discover: false`), `AsyncInternalAlsoExternalSpec` (`discover: false`, `internal: ["Complete"]` and also lists `"Complete"` in actions/0 → validation error), `AsyncUnknownInternalSpec` (`discover: false`, `internal: ["Nope"]` → validation error).

**Tests:**
- conformance_test: `__notary__` includes `internal`; the two invalid mappings fail `validate/2` with messages naming the offending action.
- runner_test: `AsyncSpec` passes `check(..., seed: 42, max_runs: 200)` — run the file 5x to show it is not flaky; `AsyncWrongCompletionSpec` fails with `kind in [:illegal_transition, :rejected_with_side_effect]` (timing-dependent which); `AsyncStalledSpec` fails `:internal_action_stalled` with `details.pending == ["Complete"]` (use `settle_timeout: 50` in the test); `Config.get(:settle_timeout) == 1_000`; every pre-existing runner test still passes unchanged.
- Update the `Notary.Conformance` moduledoc: document `internal:`.

- [ ] Write fixtures + failing tests (RED), implement, GREEN, run full suite `--include tlc`, commit.

---

### Task 2: `Notary.Tools.TLCRunner` as a supervised-by-nobody process, verified against `specs/TLCRunner.tla`

**Files:**
- Modify: `lib/notary/tools/tlc_runner.ex` (keep `run/2` and `distinct_states/1` signatures; `Notary.TLC` must not need changes)
- Create: `test/support/fake_tlc.sh` (executable, `chmod +x`, committed), `test/support/specs/tlc_runner_spec.ex` (mapping), `test/notary/tools/tlc_runner_process_test.exs`
- Test: existing `test/notary/tlc_test.exs` must pass unchanged.

**Interfaces:**
- `start(tlc_args, opts) :: {:ok, Run.t()}` — `%Notary.Tools.TLCRunner.Run{pid, ref, owner}` (`owner` = the calling process). Spawns the runner process with `spawn` (NOT linked), which opens the port and monitors `owner`. Same opts as `run/2` (`java`, `jar`, `timeout` — may be `:infinity`, `max_states`, `cd`, `tmp_dir`).
- `await(run, timeout \\ :infinity) :: {:ok, result} | {:error, Error.t()}` — only the owner may await. If the runner process dies without replying → `{:error, %Error{kind: :tlc_crashed}}`.
- `cancel(run) :: :ok` — any process may call it; the runner kills TLC and the owner's `await` returns `{:error, %Error{kind: :tlc_cancelled}}`. Cancelling a finished run is a no-op.
- Watchdog: when the runner sees the owner's `:DOWN`, it kills the OS process (same `kill/1` as today) and exits. No reply is sent.
- Timeout: the runner schedules its own `{:deadline, ref}` message (`Process.send_after`, skipped for `:infinity`) and on it behaves as today (`:tlc_timeout`). `@doc false def __expire__(run)` sends that message (test hook for the `Timeout` spec action).
- `run(tlc_args, opts)` = `start` then `await`, same results/errors as today.

**Fake TLC (`test/support/fake_tlc.sh`):** invoked as the `java` executable; the runner passes JVM args first, so the control directory is the **last** argument. It writes its PID to `<dir>/pid`, then loops reading one command per line from the FIFO `<dir>/ctl` (created by the mapping with `mkfifo`): `progress` → increments a counter and prints `<n> distinct states found`; `exit` → `touch <dir>/exited`, exit 0. Any other line is ignored.

**Mapping `Notary.Specs.TLCRunner`** (`use Notary.Conformance, spec: "specs/TLCRunner.tla", internal: ["LimitKill", "Reap"]`):
- `init/0`: temp control dir (under `Notary.Config.work_dir()/tmp`), `mkfifo`, an Agent for `seen` and `result`, and a *caller* process spawned with `spawn` (unlinked) that waits for `{:start, args}`, calls `TLCRunner.start(args, java: fake_tlc_path, jar: "unused", timeout: :infinity, max_states: 2)` (Limit = 2 in the cfg), sends the `Run` back, then `await`s and stores the mapped result in the Agent, then stays alive (`receive` forever) so it remains "alive".
- `actions/0`: `Start`, `Progress`, `Exit`, `Timeout`, `Cancel`, `CallerDies`, all `StreamData.constant(%{})`.
- `action/3` — reject (`{:rejected, reason, ctx}`, no side effect) whenever the spec action's guard is false in the implementation's current observable state; otherwise:
  - `Start`: send `{:start, args}` to the caller; wait (≤ 2s) for the `Run` and for `<dir>/pid` to exist.
  - `Progress`: increment `seen` in the Agent, write `progress\n` to the FIFO. Guard: os alive and seen ≤ 2.
  - `Exit`: write `exit\n`; wait (≤ 2s) until `<dir>/exited` exists and the result is recorded. Guard: os alive and seen ≤ 2.
  - `Timeout`: `TLCRunner.__expire__(run)`; wait for the result. Guard: os alive, caller alive.
  - `Cancel`: `TLCRunner.cancel(run)`; wait for the result. Guard: os alive, caller alive.
  - `CallerDies`: `Process.exit(caller, :kill)`; wait until `Process.alive?` is false. Guard: caller alive and result none.
  - Writing to a FIFO with no reader blocks forever — the guards above prevent that; also never write after `exited`/killed.
- `project/1`: `os` = `"none"` (no pid file) | `"exited"` (marker) | `"alive"` (`kill -0 <pid>` succeeds) | `"killed"`; `caller` = `"alive"`/`"dead"`; `seen` = Agent value; `result` = `"none" | "ok" | "timeout" | "too_many_states" | "cancelled"` from the Agent (map `{:ok, _}` → "ok", Error kinds `:tlc_timeout`/`:too_many_states`/`:tlc_cancelled`).
- `teardown/1`: kill the fake process if alive, remove the control dir.

**Tests:**
- `tlc_runner_process_test.exs` (unit, uses the fake TLC, no Java): start→exit returns `{:ok, %{exit_status: 0}}`; cancel → `:tlc_cancelled` and the OS process is gone; `__expire__` → `:tlc_timeout`; **killing the owner kills the OS process** (poll `kill -0` up to 2s); progress past `max_states` → `:too_many_states`.
- `nix develop -c mix notary.verify` passes in the repo root (lock, check, conformance for TLCRunner). Paste its output in the report.
- Demonstration (not committed): temporarily disable the watchdog (ignore the owner `:DOWN`), run `mix notary.verify`, paste the failing report (expected: `:internal_action_stalled` with pending `["Reap"]`, shrunk to a trace ending `Start, CallerDies` or similar), then restore and confirm green again.

- [ ] RED tests, implement, GREEN, `mix notary.verify` green, full suite `--include tlc` and `--include e2e` once, commit.
