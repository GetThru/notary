# Outlaw — Design Spec

**Date:** 2026-09-30
**Status:** Draft for review

> Any behavior not in the spec is outlawed.

## 1. Purpose

Outlaw is an Elixir library that makes TLA+ specifications the contract between a
human and an LLM:

1. The **human** writes a TLA+ spec for a feature.
2. **TLC** model-checks the spec (invariants, deadlock, liveness).
3. The **LLM** reads the spec and implements it in Elixir, plus a small mapping
   module connecting spec to code.
4. Outlaw **generates conformance property tests** from the spec's state graph and
   verifies the implementation behaves as the spec says.

Scope: Elixir projects only. Specs are authored by humans; LLMs never edit them.

### Success criteria

- `mix outlaw.verify` is the single command a human, LLM, or CI runs; it exits
  non-zero on any spec or conformance failure, and `--json` output is sufficient
  for an LLM to diagnose and fix the implementation without further tooling.
- A deliberately buggy implementation of each fixture spec fails with a shrunk,
  minimal action sequence that pinpoints the first divergent step.
- Features spanning multiple processes, Ecto-backed contexts, multiple actors,
  and (Phase 2) LiveView UIs can be verified, not just single functions.
- Outlaw verifies parts of itself with its own specs (Phase 1.5 onward).

## 2. Core approach: the TLC state graph as oracle

TLC exhaustively explores the spec under small constants and dumps the full
reachable state graph (`-dump dot,actionlabels`). Outlaw parses it into an
Elixir graph. A StreamData property test then drives the real implementation
through random action sequences; after each step it projects the
implementation's state into spec variables and checks that the transition is an
edge in the graph labeled with that action.

Consequences:
- Outlaw never interprets TLA+ itself — TLC is the only evaluator.
- Action parameters are never recovered from TLC; they come from generators in
  the mapping module, and the graph checks the resulting (before, after) pair.
- The spec's state space must be finite and modest (small constants), which is
  standard TLC practice. Generators draw from the same bounds.

Rejected alternatives: a TLA+ interpreter in Elixir (reimplements TLC), and
Apalache/TLC-simulation trace replay (traces lack action parameters; no explicit
graph). Apalache is a v2 candidate as an optional symbolic checker or per-step
oracle to lift the small-constants limit.

## 3. Architecture

Outlaw is a Hex package used as a `:dev`/`:test` dependency.

| Module | Responsibility |
|---|---|
| `Outlaw.Tools` | Locate/install `tla2tools.jar` and Java; configuration of paths. |
| `Outlaw.Tools.TLCRunner` | Process owning a TLC OS port: start, stream output, timeout, cancel, report crash. |
| `Outlaw.TLC` | Run model checking; parse TLC output into `{:ok, stats}` or `{:violation, kind, trace}` where kind ∈ `:invariant \| :deadlock \| :liveness \| :assertion`. |
| `Outlaw.Value` | Parse TLC value syntax into Elixir terms (see §3.1). |
| `Outlaw.StateGraph` | Parse TLC DOT dump into states + action-labeled edges; indexes for `initial_states/1` and `successors(graph, state, action)`. |
| `Outlaw.Cache` | Store/load parsed graphs in `_build/outlaw/<Spec>-<hash>.graph`, keyed by SHA-256 of the `.tla` + `.cfg` contents and the TLC version. |
| `Outlaw.Lock` | Read/write `specs/.outlaw.lock`; detect specs changed since last lock. |
| `Outlaw.Conformance` | `use` macro and behaviour for mapping modules (see §4). |
| `Outlaw.Conformance.Runner` | The StreamData property: drive, project, check, shrink, report. |
| `Outlaw.Report` | Human-readable and JSON rendering of results and failures. |
| `Outlaw.Viewer` | Generate the self-contained HTML graph viewer and Mermaid output (§6). |
| `Outlaw.Conformance.LiveView` | Phase 2. LiveView driving/projection helpers (§8). |

### 3.1 TLC values

`Outlaw.Value` parses:

| TLA+ | Elixir |
|---|---|
| integers | integer |
| `TRUE` / `FALSE` | `true` / `false` |
| `"str"` | binary |
| model values (`u1`) | `{:model_value, "u1"}` |
| `{a, b}` | `MapSet` |
| `<<a, b>>` | list |
| `[f \|-> v, ...]` | map with binary keys |
| `(k1 :> v1 @@ k2 :> v2)` | map keyed by parsed keys |

Unparseable input returns `{:error, {:unparseable_value, raw}}` and surfaces as an
Outlaw bug report containing the raw text.

For comparison, the mapping module's `project/1` returns Elixir terms in this
same representation. Helpers `Outlaw.Value.set/1` and `model/1` build them. Note
TLC prints any function with domain `1..n` as a sequence, so such values are
lists. Verified against TLC 2.19 (tla2tools v1.7.4, the pinned version).

### 3.2 Project layout (user's project)

```
specs/
  AGENTS.md                    # generated once by outlaw.new; LLM rules (§7)
  .outlaw.lock                 # committed; spec hashes
  Bank.tla                     # human-authored, pure TLA+
  Bank.cfg                     # TLC model: small CONSTANTS, INVARIANTs, PROPERTIES
test/outlaw/
  bank_spec.ex                 # mapping module (LLM-written, human-reviewed)
  bank_conformance_test.exs    # generated: Outlaw.Conformance.assert_conforms(Bank.Spec)
```

`test/outlaw/*.ex` is added to `elixirc_paths(:test)` per the install docs.

### 3.3 Configuration

```elixir
config :outlaw,
  specs_dir: "specs",
  tla2tools_path: nil,     # default: _build/outlaw/tla2tools.jar
  java: "java",
  tlc_timeout: :timer.minutes(5),
  max_states: 100_000,
  max_runs: 100,           # StreamData runs per spec
  max_steps: 50,           # max actions per run
  action_timeout: 5_000
```

## 4. Mapping modules (conformance contract)

```elixir
defmodule Bank.Spec do
  use Outlaw.Conformance,
    spec: "specs/Bank.tla",
    observe: ["balance"]          # optional; default: all spec variables

  @impl true
  def init do
    {:ok, pid} = Bank.start_link()
    {:ok, pid}
  end

  @impl true
  def actions do
    %{
      "Deposit"  => StreamData.fixed_map(%{amt: StreamData.integer(1..3)}),
      "Withdraw" => StreamData.fixed_map(%{amt: StreamData.integer(1..3)})
    }
  end

  @impl true
  def action("Deposit", %{amt: a}, pid) do
    :ok = Bank.deposit(pid, a)
    {:ok, pid}
  end

  def action("Withdraw", %{amt: a}, pid) do
    case Bank.withdraw(pid, a) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:rejected, reason, pid}
    end
  end

  @impl true
  def project(pid), do: %{"balance" => Bank.balance(pid)}

  @impl true
  def teardown(pid), do: GenServer.stop(pid)   # optional
end
```

Callbacks:
- `init() :: {:ok, ctx}` — start the system under test for one run.
- `actions() :: %{action_name => StreamData.t(params)}` — names must exist as edge
  labels in the graph (validated up front).
- `action(name, params, ctx) :: {:ok, ctx} | {:rejected, reason, ctx}`.
- `project(ctx) :: %{var_name => value}` — must return exactly the observed vars.
- `teardown(ctx) :: any` — optional.

`project/1` is a refinement mapping: concrete state (process state, DB rows) →
abstract spec variables. Specs may be as abstract as the feature warrants.

### 4.1 Unobserved variables

With `observe:` set, only listed variables are compared. Because a projected
state may then match several spec states, the runner tracks a **set of candidate
spec states**, narrowing it each step. Failure = candidate set becomes empty.

### 4.2 External effects

No special machinery. Time, network, third-party failures are modeled as spec
actions (e.g. `Tick`, `PaymentDeclined`); the mapping's `action/3` for them
drives a stub (Mox expectation, Agent-backed fake). The `outlaw.new` template and
docs demonstrate the pattern.

### 4.3 Internal actions (Phase 1.5)

Some spec actions are performed by the implementation *on its own*, in reaction
to an event, not on request: a GenServer handling a message, a watchdog reaping a
process, a limit check killing a run. The mapping cannot invoke these, and
checking state right after the triggering step would race the reaction.

`use Outlaw.Conformance, spec: ..., internal: ["LimitKill", "Reap"]` declares
them. Internal actions must exist in the graph and must not appear in
`actions/0` (validated, `:invalid_mapping`). The runner never generates them;
instead it treats the implementation as free to take any number of internal
steps at any time (§5, `closure`).

Fairness comes from the spec, not a blanket assumption that every declared
internal action is fair. `Outlaw.Spec.fair_actions/1` scans the spec's `.tla`
text (TLA comments -- `\*` to end of line, `(* ... *)` blocks -- stripped
first) for `WF_<sub>(Name...)` / `SF_<sub>(Name...)` occurrences and returns
the set of `Name`s: `WF_vars(Reap)`, `WF_<<x, y>>(Reap)`, `WF_vars(Pay(u))` and
`\A u \in U : WF_vars(Pay(u))` all count (only the identifier immediately
inside the outer parentheses is taken). A name that isn't actually a graph
action (e.g. `WF_vars(Next)` -- `Next` is the whole-step formula, not an edge
label) is harmless: `Outlaw.Conformance.check/3` only keeps its intersection
with the mapping's declared `internal:` actions. Only that intersection --
the *fair* internal actions -- must eventually fire; a declared internal
action the spec doesn't mark fair (e.g. `LimitKill` in `specs/TLCRunner.tla`,
which has `WF_vars(Reap)` but nothing naming `LimitKill`) is never required to
happen.

At the end of every run that declares internal actions, and at every `:settle`
point the generator places mid-run (§5.1), the runner *settles*:
it re-projects every 10 ms for up to `settle_timeout` (config, default
1_000 ms) until the implementation reaches a candidate state where no fair
internal action is enabled (self-loops ignored) -- `closure` itself still
considers every declared internal action, fair or not, regardless of
fairness. A projection outside `closure(C)` fails `:illegal_transition` (this
is checked even when no internal action is fair); timing out fails
`:internal_action_stalled` with the still-enabled *fair* internal actions in
the details. This is a bounded, runtime form of liveness for reactions only --
full liveness remains TLC's job on the spec.

Asynchrony can make a run non-repeatable, so shrinking may stop at a longer
trace. Mappings should make external actions synchronous where they can (e.g.
wait for an acknowledgement before returning `{:ok, ctx}`).

## 5. Conformance run semantics

Per StreamData run. `closure(S)` is every state reachable from `S` through zero
or more edges labelled with an internal action (§4.3); with no internal actions
it is `S` itself, and the rules below reduce to the Phase 1 semantics.

1. Load graph (cache or TLC). `C := closure(initial_states(graph))`.
2. `init/0`; `p := project(ctx)`; `C := {s ∈ C : observed(s) = p}`. Empty → fail
   (`:init_mismatch`).
3. Generate a sequence (length ≤ `max_steps`) of `{name, params}` steps and
   `:settle` points (§5.1). A `:settle` point settles (§4.3) mid-run: on
   success it records a `(settle)` step, sets `C` to the settled candidates and
   continues; with no fair internal actions declared it is a no-op and records
   nothing. For each `{name, params}` step, with `B := closure(C)`:
   - `E := {t : s ∈ B, t ∈ successors(graph, s, name)}`.
   - Call `action(name, params, ctx)` under `action_timeout`.
   - **Accepted while `E = ∅`**: fail (`:action_not_enabled`) — the
     implementation performed an action the spec forbids here.
   - **Accepted** `{:ok, ctx}` otherwise: `p' := project(ctx)`;
     `C := {t ∈ closure(E) : observed(t) = p'}`. Empty → fail
     (`:illegal_transition`).
   - **Rejected** `{:rejected, _, ctx}`: `p' := project(ctx)`;
     `C := {t ∈ B : observed(t) = p'}` (an internal step may have happened
     meanwhile). Empty → fail (`:rejected_with_side_effect`).
4. If internal actions are declared: settle (§4.3).
5. `teardown/1`.

On failure StreamData shrinks to the shortest failing sequence. The report shows,
per step: action + params, implementation projection, candidate spec states, and
marks the first divergent step. A failure viewer HTML is written to
`_build/outlaw/<Spec>-failure.html`.

Invariants need no separate runtime check: every state in the graph already
satisfies them (TLC verified), so matching the graph implies them.

### 5.1 Spec-guided generation (Phase 1.5)

Sequences come from `Outlaw.Conformance.Walk`, which walks the spec's graph
abstractly (`use Outlaw.Conformance, generation: :uniform` keeps the Phase 1
generator: uniform picks from `actions/0`, no `:settle` points).

- **Possible set.** The walk tracks `P`, the spec states the run could be in:
  `P := closure(initial)`; after emitting action `a`,
  `P := closure(successors(P, a))`, or `P` unchanged if `a` is enabled nowhere in
  `P` (the implementation must reject it).
- **Target.** Each generated value first picks a transition `(s, a, t)`
  uniformly among all graph edges (internal ones included) and emits the
  shortest external-action path from `closure(initial)` to `s` (BFS over the
  graph; paths cached per graph and target), then `a` if external, or a
  `:settle` point if `a` is internal.
- **Continue.** Then a random walk up to `max_steps`: ~80% an action enabled
  somewhere in `P` (uniform), ~15% an action disabled everywhere in `P` (guard
  testing), ~5% a `:settle` point — 50% immediately after a step that makes a
  fair internal action enabled somewhere in `P`.
- **Params.** Every emitted action takes a value from its `actions/0` params
  generator. The walk cannot choose params that lead to a particular edge, so
  for parameterised actions targeting is by action name only.
- **Reproducibility and shrinking.** All randomness is StreamData's, so `--seed`
  reproduces the sequences; a value is a plain list of steps and `:settle`
  points and shrinks like any list (removing steps may turn later actions into
  disabled ones, which still test guards).

### 5.2 Coverage

Each passing `check` reports coverage accumulated over all its runs (a failing
check reports its failure instead; a passing check never shrinks, so every
counted execution is an original run):

- **Actions** — an external action is reached when a step accepted it. An
  internal action is reached when, after a step or settle, no new candidate
  lies in the set reachable without internal steps; every internal edge into
  the new candidates from that closure then counts.
- **Observed states** — distinct projections seen in steps, out of the distinct
  projections (on the observed variables) of all graph states.
- **Observed transitions** — distinct `(projection before, action, projection
  after)` triples of accepted steps, out of the distinct triples of all
  external graph edges.

Text reports add `coverage: actions 9/9, observed states 29/29, transitions
52/57` under the conformance stage, plus `warning: never reached: LimitKill` /
`warning: N observed states never reached (first: ...)` lines for gaps. JSON adds
`"coverage": {"actions" | "states" | "transitions": {"reached", "total",
"unreached"}}` (`unreached` capped at 20 entries, states as TLA+ text). Gaps are
warnings only; they never change a stage's status.

**Not checked at conformance time (documented limits):**
- Liveness/fairness — proven by TLC on the spec only.
- "Rejected but the spec allowed it with these exact params" — the graph's edge
  labels carry no params, so over-strict implementations can pass. v1 limit.
- Real concurrency races inside the implementation — actions are driven
  sequentially; TLC proves the design across all interleavings, but code-level
  races are v2 (runtime trace validation).

## 6. Mix tasks and visualization

All tasks accept `--json`, exit non-zero on failure, and take optional spec names
(default: all specs in `specs_dir`). `outlaw.test` and `outlaw.verify` run in
`MIX_ENV=test` (declared via `preferred_envs` in the user's `mix.exs`), compile
the project (mapping modules under `test/outlaw/` are on `elixirc_paths(:test)`),
start the app, require `test/outlaw/outlaw_helper.exs` if present (for setup such
as Ecto sandbox mode), discover mapping modules, and run the checks directly. The
generated `*_conformance_test.exs` wraps the same check
(`Outlaw.Conformance.assert_conforms/1`) so plain `mix test` covers conformance too.
A mapping declared with `use Outlaw.Conformance, ..., discover: false` is
skipped by discovery (useful for alternate or deliberately buggy mappings).

With `--json`, the JSON report is the **last line of stdout** (compiler output may
precede it) and is also written to `_build/outlaw/report.json`.

| Task | Behavior |
|---|---|
| `mix outlaw.install` | Download pinned `tla2tools.jar` to `_build/outlaw/`, verify checksum, check Java ≥ 11. |
| `mix outlaw.new Name [--no-mapping]` | Scaffold `specs/Name.tla` (CONSTANTS, VARIABLES, `TypeOK`, `Init`, `Next`, `Spec`, convention comments incl. external-effect actions), `specs/Name.cfg`, mapping stub, test file; create `specs/AGENTS.md` if absent; print the CLAUDE.md/AGENTS.md snippet. Refuses to overwrite existing files. |
| `mix outlaw.check` | Run TLC; report pass or violation with readable counterexample trace. |
| `mix outlaw.test` | Load/build cached graph; run conformance properties. |
| `mix outlaw.verify` | Lock check → `check` → `test`, for all specs. The one command for LLMs and CI. |
| `mix outlaw.lock` | Record current spec hashes in `specs/.outlaw.lock` (deliberate human step). |
| `mix outlaw.graph Name [--open] [--format html\|mermaid] [--trace failure\|counterexample]` | Generate the viewer or Mermaid output. |

### 6.1 HTML viewer

A single self-contained HTML file (Cytoscape.js vendored in `priv/`, works
offline): pan/zoom, click a state to see its variables, filter by action,
collapse by variable (untick variables to merge states that agree on the rest),
and highlight a path (TLC counterexample or conformance
failure trace). Above 500 states it starts collapsed around the initial state and
the highlighted path; users expand outward.

### 6.2 Mermaid

`--format mermaid` emits a `stateDiagram-v2` suitable for GitHub/markdown and for
LLM consumption. Above 50 states it emits only the highlighted path (or the
initial neighborhood) and says so in a comment.

## 7. LLM workflow and spec integrity

`specs/AGENTS.md` (and the printed snippet) instructs agents:

1. Files in `specs/` are human-authored. **Never edit `.tla`, `.cfg`, or
   `.outlaw.lock`.** If the spec seems wrong or ambiguous, stop and ask.
2. Implement: read the spec, write code, write/complete the mapping module, run
   `mix outlaw.verify --json`.
3. On failure: read the shrunk trace and divergent step (optionally
   `mix outlaw.graph Name --format mermaid --trace failure`), fix the **code**,
   re-run.

Integrity: `mix outlaw.verify` compares spec hashes against
`specs/.outlaw.lock`. A mismatch fails verification with
`spec changed since last lock: Bank.tla — run mix outlaw.lock if intentional`.
A spec with no lock entry fails the same way (so a freshly scaffolded spec must
be locked once the human finishes writing it). Only a human runs
`mix outlaw.lock`. This makes spec edits by an LLM visible in
both the tool output and the diff.

## 8. Phase 2: LiveView conformance

`Outlaw.Conformance.LiveView` is compiled only when `phoenix_live_view` is
available. It reuses the runner; only driving and projection differ.

**Driving.** `init/0` builds a conn and calls `live(conn, path)`. ctx holds the
view, or a map of views per actor (`%{u1: view1, u2: view2}`) for multi-user
specs. Helpers return the runner contract:

```elixir
def action("AddItem", %{sku: s}, ctx), do: click(ctx, "[data-sku=#{s}] button")
def action("Pay", _, ctx),            do: submit(ctx, "#payment-form", %{card: "ok"})
```

`click/3,4`, `submit/4,5`, `change/4,5` (optional actor argument). A target
element that is **missing or `disabled`** yields `{:rejected, :not_available, ctx}`
— so "spec says not enabled" becomes "the UI must not offer it." Redirects and
live navigation are followed automatically, replacing the view in ctx.

**Observing.** Primary: markup convention
`<span data-outlaw-var="step" data-outlaw-value="payment">`; `project_dom/1`
collects every `[data-outlaw-var]` across views and parses values with
`Outlaw.Value`. Escape hatch: `project_assigns/1` reads socket assigns
(documented as depending on LiveView internals).

**Settling.** After each action the runner settles every view (`render_async` +
`render`) so PubSub / `handle_info` updates from other actors land before
projection. Settle timeout (default 1s) is a failure (`:settle_timeout`), never a
pass.

**Database.** Helpers check out an Ecto sandbox per run in `init`, allow the
LiveView processes, and check in on `teardown`.

**Limit.** Server-side LiveView behavior only; JS hooks / `JS.*` client commands
are not exercised.

## 9. Error handling

Distinct, actionable messages (and structured `--json` errors) for:

| Condition | Message gist |
|---|---|
| Java or jar missing | run `mix outlaw.install` / use the nix flake |
| TLC parse/semantic error | TLC message with file:line |
| State space > `max_states` | aborted; shrink constants in `.cfg` |
| TLC timeout / crash | timeout or exit status + last output lines |
| Mapping invalid | unknown action names, missing/extra observed vars in `project/1` |
| Unparseable TLC value | Outlaw bug; raw text included |
| Action timeout | step, action, params |
| Spec lock mismatch | which spec; run `mix outlaw.lock` if intentional |

## 10. Development environment

The Outlaw repo ships a `flake.nix` dev shell providing Elixir/Erlang, a JDK, and
(for tests) Postgres. Users may use the flake as a reference or rely on
`mix outlaw.install` + any Java ≥ 11.

## 11. Testing Outlaw

- `Outlaw.Value`: unit + property tests over captured TLC output samples.
- `Outlaw.StateGraph`: fixture DOT files.
- End-to-end fixtures in `test/fixtures/`, each with a correct and a
  deliberately buggy implementation; the buggy one must fail with the expected
  failure kind and shrunk trace:
  - `Counter` — trivial.
  - `Bank` — with a hidden (unobserved) variable.
  - `Workflow` — two actors, external-effect action.
  - Phase 2: a three-step wizard LiveView (bug: "Pay" enabled before address),
    plus a two-user PubSub variant.
- Tests needing Java are tagged `:tlc`; value/graph tests run anywhere.
- CI order: fixture suite first, then Outlaw's own `mix outlaw.verify` (§12).

## 12. Phases and dogfooding

**Phase 1 — Core.** §3–§7, §9–§11 (except LiveView): value parser, graph,
TLC runner, cache, lock, conformance runner, reports, all mix tasks, HTML viewer
and Mermaid, flake, fixtures.

**Phase 1.5 — Bootstrap.** Outlaw gets its own `specs/`, human-authored, and
`mix outlaw.verify` runs on Outlaw in CI. Initial targets:
- `Outlaw.Tools.TLCRunner` lifecycle (idle → running → done / timed out /
  crashed; cancellation; crash mid-run).
- The cache + lock protocol (when a graph is reused vs rebuilt; when a spec
  change is flagged vs accepted).

**Phase 2 — LiveView, spec-first.** Before Phase 2 code exists, the human specs
the settle protocol (multi-view async updates, timeouts, redirect-replaces-view);
Phase 2 is implemented against it with Outlaw.

**Circular trust guard.** Outlaw self-verification counts only while the fixture
suite is green — known-buggy implementations must fail. CI enforces the order.

## 13. Out of scope (v1)

Runtime trace validation for concurrent code, MCP server, conformance-time
liveness checking, Apalache, a LiveView dashboard for Outlaw itself, and
client-side LiveView JS behavior.
