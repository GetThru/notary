# Outlaw

> Any behavior not in the spec is outlawed.

Outlaw makes **TLA+ specifications the contract between you and an LLM** in
Elixir projects. You write the spec. TLC model-checks it. The LLM implements it.
Outlaw then proves the implementation behaves like the spec, by driving it
through generated action sequences and checking every step against the spec's
full state graph.

## Install

```elixir
# mix.exs
def project do
  [..., elixirc_paths: elixirc_paths(Mix.env())]
end

def cli, do: [preferred_envs: ["outlaw.test": :test, "outlaw.verify": :test]]

defp deps, do: [{:outlaw, "~> 0.1", only: [:dev, :test]}]
defp elixirc_paths(:test), do: ["lib", "test/support", "test/outlaw"]
defp elixirc_paths(_), do: ["lib"]
```

```bash
mix deps.get
mix outlaw.install      # pinned tla2tools.jar; needs Java >= 11 (or use this repo's nix flake)
```

## Workflow

| Who | Step |
|---|---|
| You | `mix outlaw.new Checkout`, then write `specs/Checkout.tla` and `.cfg` |
| You | `mix outlaw.check Checkout` until TLC is happy, then `mix outlaw.lock` |
| LLM | Implement it in `lib/`, and complete `test/outlaw/checkout_spec.ex` |
| LLM / CI | `mix outlaw.verify --json` (lock check, model check, conformance) |

`specs/AGENTS.md` tells agents the rules: specs are yours, and agents never
edit them. If a spec changes without `mix outlaw.lock`, verification fails.

## The mapping module

```elixir
defmodule MyApp.Specs.Bank do
  use Outlaw.Conformance, spec: "specs/Bank.tla", observe: ["balance"]

  def init, do: MyApp.Bank.start_link()
  def actions, do: %{"Deposit" => StreamData.fixed_map(%{a: StreamData.integer(1..2)}), ...}
  def action("Deposit", %{a: a}, pid), do: ...   # {:ok, pid} | {:rejected, reason, pid}
  def project(pid), do: %{"balance" => MyApp.Bank.balance(pid)}
end
```

- `project/1` returns spec variables using `Outlaw.Value`'s representation:
  model values are `model("u1")`, sets are `set([...])`, sequences are lists,
  records are maps with string keys.
- Actions that the spec forbids must return `{:rejected, reason, ctx}` with
  state unchanged except for internal reactions (see `internal:` below).
  Outlaw checks guards too.
- Model the outside world (time, failing services) as spec actions, and have
  the mapping drive a stub.

### Internal actions

Some spec actions happen *inside* the implementation on their own, never on
request: a GenServer reacting to a message, a watchdog reaping a dead process,
a limit check killing a run. The mapping can't invoke these, and checking
state right after the triggering step would race the reaction.

```elixir
use Outlaw.Conformance, spec: "specs/Watchdog.tla", internal: ["Reap"]
```

Internal actions are excluded from `actions/0` (and must not be a key of it):
the runner never generates them as driven steps. Instead it treats the
implementation as free to take any number of them at any time, tracking every
state reachable through zero or more internal transitions (their *closure*)
alongside each driven step. At the end of a run, it *settles*: it waits for
the implementation to reach a candidate state where no internal action the
*spec* marks fair is enabled (self-loops don't count). Fairness is read from
the spec's own text (`WF_vars(Reap)`, `SF_vars(...)`, ...), not assumed for
every declared internal action — an internal action the spec never marks fair
is never required to fire.

### Generation

By default (`generation: :walk`), sequences come from `Outlaw.Conformance.Walk`,
which walks the spec's state graph: about half of the generated values target
a graph edge directly (shortest path to it, then that transition); every value
then continues with mostly actions enabled somewhere in the current possible
set, some actions disabled everywhere (to exercise guards), and occasional
`:settle` points (design spec §5.1). Pass `generation: :uniform` to keep the Phase 1 generator
instead — uniform random picks from `actions/0`, no targeting, no `:settle`
points:

```elixir
use Outlaw.Conformance, spec: "specs/Bank.tla", generation: :uniform
```

`:uniform` is useful as a baseline when comparing behavior, or while
narrowing down whether a failure is particular to the walk's targeting.

## Seeing the state space

```bash
mix outlaw.graph Bank --open                      # interactive HTML
mix outlaw.graph Bank --trace failure --open      # where the last conformance run diverged
mix outlaw.graph Bank --format mermaid            # for PRs and LLMs
```

## Limits (v1)

Actions are driven sequentially, so code-level races are not exercised. TLC
still checks the design across all interleavings. Liveness is checked only on
the spec, plus the bounded settle check for fair internal actions (above).
Keep `.cfg` constants small.

Every passing `check` reports a coverage summary (`coverage: actions R/T,
observed states R/T, transitions R/T`) plus `warning:` lines for gaps — read
them, don't just trust a pass. A gap can be genuine and permanent rather than
bad luck: on Outlaw's own `specs/TLCRunner.tla`, a couple of the graph's
states are reachable in TLC but never in the real implementation, because an
internal reaction (the state-limit kill beating a driven `Cancel`/`Timeout`
at the same instant) wins the timing race in every measured run — not a bug, just the
coverage report documenting exactly which graph states the implementation's
real timing rules out.

Random generation can also miss paths that *aren't* ruled out, just rare.
Measured on `specs/TLCRunner.tla` (`mix outlaw.verify --seed 1..10`, default
100 runs, `generation: :walk`):

- All 6 external actions plus both internal ones (`LimitKill`, `Reap`) are
  reached on 10 of 10 seeds (`coverage: actions 8/8`).
- A missing watchdog (the owner's `:DOWN` no longer kills the OS process) is
  caught on 10 of 10 seeds, failing `internal_action_stalled` (pending
  `Reap`) — `Reap` is the one internal action this spec marks fair, so the
  end-of-run settle check requires it to happen.
- A disabled state-limit kill is **not** caught by conformance on any of 10
  seeds (0 of 10), because `LimitKill` is not marked fair in the spec:
  nothing requires it to ever fire, so an implementation that never fires it
  doesn't contradict the spec. The coverage report is what flags this
  instead — `warning: never reached: LimitKill` plus a
  `warning: N observed states never reached (first: ...)` line, which among
  those N includes the `result = "too_many_states"` state. The text warning
  only names a count and the first unreached state; the full list (including
  that `too_many_states` state) is in `--json`'s
  `coverage.states.unreached` — read coverage warnings rather than relying on
  conformance pass/fail alone.

Raise `--max-runs` for specs where a missed-but-possible path matters; it
won't help an unfair internal action that silently stops firing (above) —
catching that needs a human decision (mark it fair in the spec, or add a
dedicated assertion), not more runs. `--seed`, `--max-runs` and `--json` are
CLI options on `mix outlaw.verify`/`mix outlaw.test`; `settle_timeout` is not
— it's set via `config :outlaw, settle_timeout: ...` — and `max_replays`
(the post-shrink minimization pass's replay budget) isn't exposed by any mix
task at all, only as an opt to `Outlaw.Conformance.Runner.check/4` directly.

## Developing Outlaw

```bash
nix develop
mix deps.get && mix run -e 'Outlaw.Tools.install()'
mix test --include tlc                 # add --include e2e for the end-to-end test
mix outlaw.verify --max-runs 1000
mix run test/fixtures/regen_graphs.exs # after changing fixture specs
```
