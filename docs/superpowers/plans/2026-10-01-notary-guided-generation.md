# Notary Phase 1.5 slice 2: spec-guided generation, settle points, coverage

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Generated conformance runs reach rare spec paths and pending reactions reliably, and every passing check reports what it covered.

**Architecture:** A pure StreamData generator (`Notary.Conformance.Walk`) walks the spec graph abstractly and emits `{name, params}` steps plus `:settle` points; the runner settles mid-run at `:settle` points; a pure `Notary.Conformance.Coverage` module computes coverage from recorded steps, surfaced through Verify → Report.

**Tech Stack:** Elixir 1.19 / OTP 27, StreamData 1.4.

**Spec:** `docs/superpowers/specs/2026-09-30-notary-design.md` — §4.3 (settle), §5 (run semantics, step 3), §5.1 (walk), §5.2 (coverage). Read them first; they are binding.

## Global Constraints

- Branch `phase1.5-dogfood`; commands as `nix develop -c <cmd>`; TLC tests need `--include tlc`.
- `specs/` and `specs/.notary.lock` are human-authored and locked — never edit them.
- `generation: :uniform` must reproduce today's behaviour exactly (same generator as `Runner.steps_generator/2`, no `:settle` points).
- Existing exact shrunk-trace assertions (Counter Max+1 `Inc`, Bank single `Withdraw 1`, Workflow `[GatewayDown, Pay]`, …) must still hold under the walk; an assertion may change only if the walk finds a different but equally minimal trace — say so in the report, never loosen to "any failure".
- `mix format --check-formatted`, `mix compile --warnings-as-errors` (dev and `MIX_ENV=test`) clean; test output pristine.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. TDD: real failing run before each implementation.

## Existing interfaces (as of 2026-10-01, HEAD f70a162)

- `Notary.Conformance.Runner.check(module, graph, observe, opts) :: {:ok, %{runs, seed}} | {:error, Failure.t()}`; opts `:seed`, `:max_runs`, `:max_steps`, `:action_timeout`, `:settle_timeout`, `:fair` (MapSet of spec-fair action names). It reads `module.__notary__().internal`.
- `Runner.steps_generator(actions_map, max_steps)` — today's uniform generator.
- `Runner.run(module, graph, observe, internal, fair, steps, timeout, settle_timeout)`; worker `walk/9` over `[{name, params}]`; private `closure/3`, `settle/10` (end of run), `settled_state?/3`, `pending_internal/3`.
- `%Notary.Conformance.Step{index, action, params, outcome, projection, candidates, allowed}`; a settle step has `action: "(settle)", params: nil, outcome: :ok`.
- `Notary.Conformance.check/3` computes `fair` via `Notary.Spec.fair_actions/1`; `Conformance.internal_actions/1`, `fair_internal_actions/1`.
- `Notary.Verify.conformance_stage/4` attaches `%{internal:, fair:}`; `Notary.Report.format_stage/2` (+ `internal_suffix/1`) and `stage_json/1` render it.
- `Notary.StateGraph`: `states`, `edges` (`%{{from, action} => [to]}`), `initial`, `actions`, `variables`; `successors/3`, `state/2`, `edges/1`.

---

### Task 1: `Notary.Conformance.Walk` — the spec-guided generator (pure)

**Files:** Create `lib/notary/conformance/walk.ex`, `test/notary/conformance/walk_test.exs`.

**Interface (produces):**
- `Walk.generator(graph, actions, opts) :: StreamData.t([{String.t(), map()} | :settle])` — `actions` is the mapping's `actions/0` map; opts `:internal` ([String.t()], default []), `:fair` (MapSet, default empty), `:max_steps` (default `Notary.Config.get(:max_steps)`).
- `Walk.closure(graph, state_ids, internal) :: [state_id]` (public; Task 2 may reuse it instead of the runner's private copy — keep one implementation).
- `Walk.advance(graph, possible, action, internal) :: possible` — §5.1 possible-set rule (unchanged when the action is enabled nowhere).
- `Walk.shortest_path(graph, from_states, target_state, external_actions) :: [action_name] | nil` — BFS over external-action edges from any of `from_states` (taking closure under internal edges at every node) to `target_state`.

**Behaviour (§5.1):** each generated value = target transition chosen uniformly from `StateGraph.edges/1` (internal included) → shortest external path to its source (skip the target if unreachable via external actions) → the target action (external) or `:settle` (internal) → random continuation up to `max_steps` total items: weights 80 enabled-somewhere-in-P action (uniform among them; if none, fall back to disabled), 15 disabled-everywhere action (if none, enabled), 5 `:settle`; after an emitted action that makes a fair internal action enabled somewhere in P, the next item is `:settle` with probability 1/2. Params: for each emitted action draw from `actions[name]`. Build with `StreamData.bind`/`StreamData.frequency`/`StreamData.member_of`, so all randomness is StreamData's (seed-deterministic) and the result is a list that shrinks as a list. Cache shortest paths per graph+target with `:persistent_term` or a process-dict map keyed by `{:erlang.phash2(graph), target}` (graphs are immutable).

**Tests (no implementation process involved):**
- only keys of `actions` and `:settle` appear; length ≤ max_steps;
- over 200 values for each of `Notary.Fixtures.graph("Counter" | "Bank" | "Workflow")`, every external action appears;
- for `Counter`, over 200 values, the abstract possible set after the value's prefix (fold `advance/4`) contains the `x = 3` state in at least 10% of values (target-driven reachability of the deepest state);
- seed determinism: `Enum.take(StreamData.seeded(gen, 42) |> ...)` (use `StreamData.check_all` with fixed `initial_seed` collecting values, or `ExUnitProperties.pick` with seeds) gives identical lists twice;
- disabled-action rate between 5% and 30% over many values on Bank;
- Async graph with `internal: ["Complete"], fair: MapSet.new(["Complete"])`: `:settle` follows `Request` in ≥ 30% of occurrences; with `fair: MapSet.new()` no forced settles (only the ~5% base rate);
- `shortest_path/4` and `advance/4` unit cases on Counter and Async.

- [ ] RED, implement, GREEN, format/compile, commit.

---

### Task 2: Runner — `:settle` points and `generation:` option

**Files:** Modify `lib/notary/conformance.ex`, `lib/notary/conformance/runner.ex`; tests in `test/notary/conformance/runner_test.exs`, `test/notary/conformance_test.exs`.

**Interfaces:** consumes `Walk.generator/3`, `Walk.closure/3`. Produces: `use Notary.Conformance, ..., generation: :walk | :uniform` (default `:walk`), in `__notary__/0` as `:generation`; `validate/2` rejects other values (`:invalid_mapping`).

**Behaviour (§5 step 3, §4.3):** `Runner.check` builds `Walk.generator(graph, module.actions(), internal:, fair:, max_steps:)` for `:walk`, `steps_generator/2` for `:uniform`. In the worker walk, a `:settle` item: when the mapping has no fair internal actions → skipped, no step recorded, index not advanced; otherwise run the existing settle loop mid-run — success records a `(settle)` step, sets candidates to the settled set, continues with the remaining items; failures as today (`:illegal_transition` / `:internal_action_stalled`, `during` label `"settle"`). End-of-run settle unchanged. Refactor so mid-run and end-of-run settle share one function.

**Tests:** mid-run settle success continues (Async: `[Request, :settle, Request]` sequence via `Runner.run/8` directly passes and records two Request steps around a `(settle)` step); mid-run stall (AsyncStalledSpec with `[Request, :settle, Request]`, `settle_timeout: 50`) fails at the settle step (last step is `(settle)`, index 2); `:settle` with no fair internal actions is a no-op (Counter `[Inc, :settle, Inc]` → exactly two steps after init); `generation: :uniform` mapping uses the old generator (assert `__notary__().generation`, and that a check passes); invalid `generation: :nope` fails validate. **All existing runner tests must pass on the walk default** (see Global Constraints about shrunk traces). Run runner_test 5x for flakiness. `mix notary.verify` still passes.

- [ ] RED, implement, GREEN, full suite `--include tlc`, commit.

---

### Task 3: Coverage — compute, return, report

**Files:** Create `lib/notary/conformance/coverage.ex`, `test/notary/conformance/coverage_test.exs`; modify `lib/notary/conformance/runner.ex`, `lib/notary/verify.ex`, `lib/notary/report.ex`; tests in `test/notary/report_test.exs`, `test/mix/tasks/notary_tasks_test.exs` if JSON shape assertions need it.

**Interfaces (produces):**
- `Coverage.new(graph, observe, internal) :: t()`; `Coverage.add_run(t(), [Step.t()]) :: t()`; `Coverage.summary(t()) :: %{actions: %{reached: n, total: n, unreached: [String.t()]}, states: %{reached, total, unreached: [map()]}, transitions: %{reached, total, unreached: [{map(), String.t(), map()}]}}` (unreached lists capped at 20, sorted).
- `Runner.check/4` success → `{:ok, %{runs, seed, coverage: summary}}` (accumulate inside the `check_all` callback in the calling process, e.g. an Agent started for the check, or the process dictionary keyed by a unique ref; clean it up).

**Rules (§5.2):** totals — actions = all graph action labels that are external keys of `actions/0` or declared internal; states = distinct observed projections of all graph states; transitions = distinct `(obs(from), action, obs(to))` over external-action graph edges. Reached — external action: some step with `outcome: :ok` and that action; internal action: for each recorded step after init, let `C_prev` be the previous step's `candidates` and define the set reachable without internal steps `E` — accepted step: `successors(Walk.closure(graph, C_prev, internal), action)`; settle or rejected step: `C_prev`. If the step's `candidates ∩ E == []`, count every internal action `a` that labels an edge `(u, a, t)` with `u ∈ Walk.closure(graph, E, internal)` and `t ∈` the step's `candidates`. States: every step's `projection`. Transitions: consecutive (prev projection, action, projection) for accepted steps.

**Report:** text adds under a passing conformance stage `    coverage: actions R/T, observed states R/T, transitions R/T`, then `    warning: never reached: A, B` when actions are unreached, and `    warning: N observed states never reached (first: <TLA+ text>)` when states are unreached (use `Report.format_state/1`). Transitions gaps appear only in the coverage line counts. JSON: `"coverage": {...}` on the conformance stage with the summary (projections rendered as TLA+ text maps, transitions as `{"from":…, "action":…, "to":…}`). Status unchanged by gaps.

**Tests:** exact counts — Counter (CounterSpec) after a passing check: actions 2/2, states 4/4; Bank: observed states total 4 (balances 0..3), not 7; Async: internal `Complete` counted reached; a synthetic step list where an action is never accepted → unreached; report text + JSON shapes; warnings present on gaps, stage still `pass`.

- [ ] RED, implement, GREEN, full suite `--include tlc`, commit.

---

### Task 4: Dogfood measurements and docs

**Files:** Modify `README.md` (mapping section: `generation:` option; Limits section: replace the measured miss-rates with the new measurements and mention the coverage report), `priv/templates/AGENTS.md.eex` (one line: read the coverage warnings; don't silence them by changing the mapping), `lib/notary/conformance.ex` moduledoc (`generation:`).

**Measurements (record in the task report; temporary code changes are NOT committed — restore and confirm `git diff` is clean afterwards):**
1. `mix notary.verify --seed S` for S in 1..10: TLCRunner coverage line shows actions 8/8 (all six external actions plus LimitKill and Reap reached) on each — paste the 10 coverage lines.
2. Disable the watchdog in `lib/notary/tools/tlc_runner.ex` (ignore the owner `:DOWN`): verify fails `:internal_action_stalled` (pending `Reap`) on 10/10 seeds.
3. Disable the state-limit kill (`n > max_states + 100`): verify fails on ≥ 9/10 seeds.
4. Time `mix notary.verify` before (on `generation: :uniform`, temporarily) and after: ≤ ~2×.
If a criterion is missed, report DONE_WITH_CONCERNS with the numbers — do not tune the spec, and do not change mapping guards to make numbers look better; tuning the walk's weights within §5.1's stated percentages is allowed if justified.

- [ ] Measure, document, format, commit docs.
