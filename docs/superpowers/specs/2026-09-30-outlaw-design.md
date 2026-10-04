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
| `Outlaw.Conformance.LiveView` | Phase 2. LiveView driving/projection helpers (§8); with `.Ctx` and `.Dom`. |

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
action the spec doesn't mark fair (e.g. the fixture spec `Async` without its
`WF_status(Complete)`) is never required to happen. (`specs/TLCRunner.tla`
originally marked only `Reap` fair; a disabled limit kill then passed
conformance, which led the spec author to add `WF_vars(LimitKill)`.)

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
     meanwhile). Empty → fail (`:rejected_with_side_effect`). If the reason is
     `:not_available` or `{:not_available, _}` and every state in `B` enables
     `name`, fail first with `:action_not_offered` (§8.4).
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
- **Target.** About half of the generated values are targeted (a `targeted?`
  boolean that shrinks to `false`, dropping the prefix entirely). A targeted
  value picks a transition `(s, a, t)` uniformly among the eligible edges —
  every graph edge whose action is declared external (an `actions/0` key) or
  internal, and whose source `s` is reachable from `closure(initial)` by some
  external-action path — and emits that shortest path, then `a` if external,
  or a `:settle` point if `a` is internal. If the value's token list is
  shorter than the path needs (e.g. after shrinking), the prefix is simply cut
  to however many tokens are available, same as running out of `max_steps`.
  All paths come from a single BFS (parent-pointer map) run once per
  generator build, not one search per target. If there is no eligible edge at
  all, every value is pure continuation (below), untargeted.
- **Continue.** Then a random walk up to `max_steps`: ~80% an action enabled
  somewhere in `P` (uniform; falls back to the disabled bucket if none is
  enabled), ~15% an action disabled everywhere in `P` (guard testing; falls
  back to the enabled bucket if none is disabled), ~5% a `:settle` point (both
  buckets empty falls back to `:settle` too). After emitting an action, a
  fair-internal-action bias can force the *next* item to `:settle`: if that
  action's direct, pre-closure successors in `P` include a state where some
  fair internal action is enabled (ignoring self-loops), the next token's own
  50/50 settle-bias roll gets a chance to force `:settle` in place of its
  normal choice.
- **Params.** Every emitted action takes a value from its `actions/0` params
  generator. The walk cannot choose params that lead to a particular edge, so
  for parameterised actions targeting is by action name only.
- **Reproducibility and shrinking.** All randomness is StreamData's, so `--seed`
  reproduces the sequences; a value is a plain list of steps and `:settle`
  points and shrinks like any list (removing steps may turn later actions into
  disabled ones, which still test guards). State ids are TLC fingerprints that
  change on every fresh TLC run (TLC picks a random fingerprint polynomial),
  so every ordering decision the walk makes — the eligible-edge list, the
  BFS's frontier/successors/closure traversal — is sorted by state *content*,
  never by id, so that `--seed` reproduces the same sequence across graph
  rebuilds, not just within one. Because each generated step is
  chosen relative to the walk's possible set, StreamData deleting one step can
  reinterpret every later one, so its shrinking can stop at a long trace.
  After StreamData has shrunk a failure, the runner therefore minimizes the
  concrete failing item list itself (`Outlaw.Conformance.Runner.minimize/4`,
  both generation modes): repeated rounds of deletion (contiguous chunks --
  halves, quarters, ... -- then single items, front to back) and params
  reduction (for each step, values from that action's own `actions/0`
  generator that are smaller in Erlang term order -- a structural order, not
  a domain-specific "simpler" -- smallest first), keeping each change whose
  replay still shows the same defect: it fails with the original failure's
  kind, or both kinds are spec-level (`:init_mismatch`, `:illegal_transition`,
  `:action_not_enabled`, `:rejected_with_side_effect`), so a spec violation is
  never traded for a timeout, crash, exception or stall. Rounds repeat until
  one changes nothing, capped at `:max_replays` (default 200) replays in total;
  each replay can cost up to `action_timeout` per step plus `settle_timeout`
  per settle point. The reported
  failure is the last failing replay's; its details record the pass
  (`minimized: N replays, K items removed, P params reduced`); the seed is
  unchanged.

### 5.2 Coverage

Each passing `check` reports coverage accumulated over all its runs (a failing
check reports its failure instead; a passing check never shrinks, so every
counted execution is an original run):

- **Actions** — an external action is reached when a step accepted it. An
  internal action is credited per step (after the initial one): let `C_prev`
  be the previous step's candidates and `E := successors(closure(C_prev), a)`
  if this step accepted an external action `a`, or `E := C_prev` if this step
  is a `(settle)` step or was rejected. If this step's candidates are disjoint
  from `E` (the implementation could only have gotten here via one or more
  internal actions), every internal action labelling an edge `(u, a, t)` with
  `u` in `closure(E)` and `t` in this step's candidates counts as reached.
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

Phase 2 is delivered in two slices:

- **Phase 2a (this section): a single view and a single actor.** No multi-view
  settling.
- **Phase 2b: multi-view, multi-actor and PubSub settling.** It is spec-first:
  the human writes a spec of the driver/settle protocol before Phase 2b code
  exists (§12).

### 8.1 Shape

LiveView support is a set of **helpers on the existing mapping contract (§4)**.
It is not a separate runner and not a declarative action table. A LiveView
mapping is an ordinary `use Outlaw.Conformance` module that
`import`s `Outlaw.Conformance.LiveView`:

```elixir
defmodule MyAppWeb.Specs.Wizard do
  use Outlaw.Conformance, spec: "specs/Wizard.tla"
  import Outlaw.Conformance.LiveView

  def init, do: mount(MyAppWeb.WizardLive, endpoint: MyAppWeb.Endpoint)

  def actions, do: %{"EnterAddress" => StreamData.constant(%{}), "Next" => ..., "Pay" => ...}

  def action("EnterAddress", _, ctx), do: submit(ctx, "#address-form", %{address: "1 Main St"})
  def action("Next", _, ctx), do: click(ctx, "#next")
  def action("Pay", _, ctx), do: click(ctx, "#pay")

  def project(ctx), do: project_dom(ctx)
end
```

Dependencies:

- `{:phoenix_live_view, "~> 1.2", optional: true}`.
- Outlaw's own test environment also needs `phoenix` and `lazy_html`.
- `Outlaw.Conformance.LiveView` is compiled only when `Phoenix.LiveViewTest` is
  available (`if Code.ensure_loaded?/1`).

The runner, Walk, shrinking, minimization, coverage, diagnostics and mix tasks
are unchanged, except for the availability rule in §8.4.

### 8.2 Modules

| Module | Responsibility |
|---|---|
| `Outlaw.Conformance.LiveView` | Helpers: `mount/2`, `click/2`, `submit/3`, `change/3`, `project_dom/1`, `project_assigns/2`. |
| `Outlaw.Conformance.LiveView.Ctx` | `%Ctx{conn, view, html, endpoint, assigns}`. `view` is the current `Phoenix.LiveViewTest.View`, or `nil` after a redirect to a page that isn't a LiveView, where `html` holds that page. `assigns` is free space for the mapping, e.g. a stub's pid. |
| `Outlaw.Conformance.LiveView.Dom` | Pure function: rendered HTML → `%{var => value}`. Unit-tested without any LiveView process. |

### 8.3 Driving

- **`mount(path_or_module, opts)`.**
  - It builds a conn for `opts[:endpoint]`, or `config :outlaw, endpoint:` if
    that's not given.
  - A path is mounted with `live(conn, path)`, which requires a router. A module
    is mounted with `live_isolated(conn, module, session: opts[:session])`.
  - It returns `{:ok, %Ctx{}}`.
- **Availability.** `click(ctx, selector)`, `submit(ctx, form_selector, values)`
  and `change(ctx, form_selector, values)` first check that the target is
  present (`has_element?/2`) and not `disabled`. For `submit`, the form's submit
  button is checked too.
  - If the target is missing or disabled, the helper sends no event and returns
    `{:rejected, {:not_available, selector}, ctx}`.
  - If the selector matches more than one element, the helper raises
    `Outlaw.Error`. That's a mapping bug, not a UI verdict.
  - With `view == nil` (a page that isn't a LiveView), every helper returns
    `:not_available`.
- **Acting.** The event is sent with `render_click/render_submit/render_change`
  via `element/2` and `form/3`. Then `render_async(view)` runs so that
  `assign_async`/`start_async` results land before projection. This is the
  whole of single-view settling.
- **Redirects.** For `{:error, {:live_redirect | :redirect, %{to: to}}}`:
  - It is followed with `follow_redirect/2`.
  - A LiveView target replaces `view` in ctx.
  - A target that isn't a LiveView sets `view: nil, html: body`.
  - `push_patch` needs no handling.
- **Result.** Each helper returns the runner contract, `{:ok, ctx}`. It never
  inspects spec state.

### 8.4 The availability rule: `:action_not_offered`

A UI must not offer what the spec forbids. With today's runner that is already
enforced: an available element that accepts the event returns `{:ok, ctx}`, and
if the spec does not enable the action there, the run fails with
`:action_not_enabled`.

A UI must also **offer what the spec allows.** Rule 3 of §5 gains a case for
rejections whose reason is `:not_available` or `{:not_available, _}`:

- Let `B := closure(C)`.
- If **every** state in `B` has a successor labelled `name`, fail with
  `:action_not_offered`: "The spec allows this action here, but the UI did not
  offer it (the element was missing or disabled)."

The check runs before the projection comparison. Requiring *every* candidate,
rather than any, keeps the rule sound when unobserved variables leave several
candidates, some of which don't enable the action. Other rejection reasons keep
the existing semantics. The rule is keyed on the reason, not on LiveView, so a
non-LiveView mapping may opt in by returning `{:not_available, _}`.

For `:action_not_offered`:

- The diagnostic underlines the spec action's guards, which made it enabled.
- Its `help:` line names the selector.
- `--json` carries `"selector"` in the failure details.

### 8.5 Observing

**Markup convention.** The markers live in the application's own templates,
which compile in every environment. Outlaw is a `:dev`/`:test` dependency, so
the markup uses no Outlaw code: plain attributes, decoded by Outlaw. Each
observed variable is one element with `data-outlaw-var` and exactly one value
attribute:

```heex
<span hidden data-outlaw-var="step"  data-outlaw-json={JSON.encode!(@step)} />
<span hidden data-outlaw-var="users" data-outlaw-value={"{u1, u2}"} />
```

- **`data-outlaw-json`** is decoded with Elixir's built-in `JSON`, with no
  extra dependency.
  - Strings, integers and booleans map directly.
  - Arrays are sequences.
  - Objects are records with string keys.
  - An empty object is the empty sequence/function `<<>>`.
  - `null` and floats are `:invalid_projection`.
- **`data-outlaw-value`** is TLC syntax, parsed by `Outlaw.Value`. It is used
  for sets and model values, which JSON cannot express.
- An element with both value attributes, or neither, is `:invalid_projection`.

**`project_dom/1`** renders the view (or uses `html`) and collects every
`[data-outlaw-var]` via `Dom`:

- A variable appearing twice with different values is `:invalid_projection`,
  and the message names both values.
- An unparseable value is `:invalid_projection`, quoting the raw text.
- A missing variable is `:invalid_projection`, the existing check.

**`project_assigns(ctx, keys)`** is the escape hatch. It reads socket assigns
through LiveViewTest internals, is documented as unstable, and returns the
given keys as strings.

### 8.6 Errors

- A LiveView process crashing during an action or render surfaces as the
  existing `:exception`/`:crashed` failures, with the exit reason.
- The mapping's `action/3` diagnostic location (§9.1) applies unchanged.

### 8.7 Limits (Phase 2a)

Phase 2a does not cover:

- more than one view or actor;
- PubSub and `handle_info` from other processes (Phase 2b);
- an Ecto sandbox;
- JS hooks and `JS.*` client commands, which are never exercised.

Server-side LiveView behaviour only.

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

### 9.1 Source diagnostics (pentiment)

Text reports render failures and errors as compiler-style diagnostics with
[pentiment](https://hex.pm/packages/pentiment) (`{:pentiment, "~> 0.2.1"}`): a
source excerpt with line numbers and labelled spans, then `help:` / `note:`
lines. The conformance step table still follows the diagnostic (a trace isn't
source). When no source location can be found, the report is the plain text
it was before.

**Locators.**
- `Outlaw.Spec.Locate` finds definitions in a spec's `.tla` text — `Name ==`
  and `Name(params) ==` — with their line ranges; for a definition whose body
  is a `/\` list, its conjuncts with line/column spans, classified as
  **guards** (no primed variable and no `UNCHANGED`) or **effects** (a primed
  variable, or `UNCHANGED`); and `WF_`/`SF_` occurrences in `Spec`. It returns
  `nil` for anything it can't parse; diagnostics then fall back to the
  definition's name line.
- `Outlaw.Mapping.Locate` finds a mapping module's source file
  (`module.module_info(:compile)[:source]`), parses it, and returns the lines
  of the `use Outlaw.Conformance` call and of the `def init`, `def actions`,
  `def project` and `def action("Name", ...)` clauses.

**What each report points at.**

| Kind | Primary label | Secondary / help |
|---|---|---|
| `action_not_enabled` | the action's guard conjuncts — one guard: "false here: ⟨state⟩"; several: "one of these is false in ⟨state⟩" (Outlaw doesn't evaluate TLA+, so it never claims which) | help: return `{:rejected, reason, ctx}` |
| `illegal_transition` | the action's effect conjuncts: "implementation reached ⟨p′⟩" | note: what the spec allowed |
| `rejected_with_side_effect` | the action's name: "rejected, but the state changed ⟨p⟩ → ⟨p′⟩" | |
| `init_mismatch` | `Init`'s definition | note: the spec's initial states |
| `internal_action_stalled` | each pending action's definition | secondary: its `WF_`/`SF_` occurrence in `Spec`, "fairness requires this to happen" |
| `invalid_projection` | `def project` in the mapping | help: expected variables / value-type hint |
| `invalid_action_result` | the matching `def action("Name", ...)` clause, or `def init` | |
| `exception` | the top stack frame inside the project (raw file/line kept in the failure details) | note: the exception message |
| `timeout` / `crashed` | the clause named by `during` (`action/3 Inc` → `def action("Inc", ...)`) | |
| `invalid_mapping` | the `use Outlaw.Conformance` line | secondary: `def actions`; help: known actions / variables |
| `spec_error` (SANY) | SANY's reported line/column, with its message | |

Spec lock mismatches, Java/jar and TLC process errors keep their text form (no
source position).

**Overclaiming.** These are syntactic locators, not a TLA+ evaluator, so a
label can point at a conjunct that isn't actually the problem: an effect
conjunct that *disables* the action rather than causing the bad transition
(e.g. `x' \in {}`), a guard hidden inside an operator call rather than written
out in the `/\` list, or a state the implementation never reaches because a
`.cfg` `CONSTRAINT` prunes it from TLC's exploration. The diagnostic is a
pointer to go read, not a verdict.

**Rendering.** Colors only when stdout is a TTY, ANSI is enabled and `--json`
is not set; otherwise plain text (tests render plain). TLA+ excerpts are not
syntax-highlighted (no makeup lexer), only annotated. JSON keeps its shape and
gains `"location": {"file", "line", "column"}` on failures and errors that
have one.

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
  - Phase 2a: `Wizard`, a three-step wizard LiveView (address → payment →
    confirm), mounted with `live_isolated` through a minimal test endpoint.
    Variants:
    - correct;
    - buggy, "Pay" enabled before an address is entered, which must fail with
      `:action_not_enabled`;
    - buggy, "Pay" never rendered, which must fail with `:action_not_offered`;
    - correct, `push_navigate`s to `/done` after Pay (exercises redirect
      following).

    `Wizard.tla` is human-authored, written with the agent as TLCRunner was,
    and reviewed by the human. Fixture specs are not covered by
    `specs/.outlaw.lock`.
  - Phase 2b: a two-user PubSub variant.
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

**Phase 2a — LiveView, single view.** (§8)

1. The human writes `Wizard.tla` first.
2. The helpers and `Dom` are built test-first.
3. The runner gains `:action_not_offered` (§8.4).
4. The wizard fixtures join the circular-trust-guard suite.
5. Measured catch rates for both buggy wizards (`--seed 1..10`) are recorded
   in the README.
6. A LiveView guide (`guides/liveview.md`) is added.

**Phase 2b — LiveView, multi-view, spec-first.** Before Phase 2b code exists,
the human specs the driver/settle protocol (multi-view async updates,
timeouts, redirect-replaces-view). Phase 2b is implemented against it with
Outlaw.

**Circular trust guard.** Outlaw self-verification counts only while the fixture
suite is green — known-buggy implementations must fail. CI enforces the order.

## 13. Out of scope (v1)

Runtime trace validation for concurrent code, MCP server, conformance-time
liveness checking, Apalache, a LiveView dashboard for Outlaw itself, and
client-side LiveView JS behavior.
