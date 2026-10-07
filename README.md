# Notary

> Any behavior not in the spec is uncertified.


Notary makes **TLA+ specifications the contract between you and an LLM** in
Elixir projects. You write the spec. TLC model-checks it. The LLM implements it.
Notary then proves the implementation behaves like the spec, by driving it
through generated action sequences and checking every step against the spec's
full state graph.

New to Notary? Start with the
[Getting Started: Hello, World](guides/getting-started.md) guide, which goes
from `mix new` to a verified feature in a few minutes.

## Install

```elixir
# mix.exs
def project do
  [..., elixirc_paths: elixirc_paths(Mix.env())]
end

def cli, do: [preferred_envs: ["notary.test": :test, "notary.verify": :test]]

defp deps, do: [{:notary, "~> 0.1", only: [:dev, :test]}]
defp elixirc_paths(:test), do: ["lib", "test/support", "test/notary"]
defp elixirc_paths(_), do: ["lib"]
```

```bash
mix deps.get
mix notary.install      # pinned tla2tools.jar; needs Java >= 11
```

Using Nix? See [Using Nix](#using-nix): the flake provides Java and the jar,
so you can skip `mix notary.install`.

### Using Nix

Notary needs two things a normal Elixir setup doesn't have: **Java** (11 or
newer) and the pinned **TLA+ tools jar**. The flake in this repository
provides both:

- **`packages.tla2tools`** is the pinned jar, fetched and checksum-verified
  by nix.
- **`devShells.tools`** adds Java and exports `NOTARY_TLA2TOOLS`, pointing
  at that jar. It contains nothing else, so it layers onto whatever Elixir
  you already use.

Notary finds the jar in this order: `config :notary, tla2tools_path:`, then
the `NOTARY_TLA2TOOLS` environment variable, then
`_build/notary/tla2tools.jar` (where `mix notary.install` puts it). With the
flake's shell active, `mix notary.install` has nothing to download; it just
confirms the jar and Java.

**If your project has its own `flake.nix`**, add Notary as an input and pull
its tools shell into yours:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    notary.url = "git+file:///path/to/notary";  # until Notary has a public repo
  };

  outputs = { nixpkgs, flake-utils, notary, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          # Java and the TLA+ tools jar for Notary.
          inputsFrom = [ notary.devShells.${system}.tools ];
          # Your project's own toolchain.
          packages = [ pkgs.beam.packages.erlang_27.elixir_1_19 ];
        };
      });
}
```

Then `nix develop` and use `mix notary.*` as usual.

**If it doesn't**, borrow the tools shell for a session, from your project
directory. Elixir comes from wherever you normally get it:

```console
$ nix develop /path/to/notary#tools
$ mix notary.verify
```

Or for a single command: `nix develop /path/to/notary#tools -c mix notary.verify`.

Don't use the flake's *default* shell for your project. That shell is for
working on Notary itself: it pins Elixir 1.19 and points `MIX_HOME` and
`HEX_HOME` at folders in the current directory.

## Workflow

| Who | Step |
|---|---|
| You | `mix notary.new Checkout`, then write `specs/Checkout.tla` and `.cfg` |
| You | `mix notary.check Checkout` until TLC is happy, then `mix notary.lock` |
| LLM | Implement it in `lib/`, and complete `test/notary/checkout_spec.ex` |
| LLM / CI | `mix notary.verify --json` (lock check, model check, conformance) |

`specs/AGENTS.md` tells agents the rules: specs are yours, and agents never
edit them. If a spec changes without `mix notary.lock`, verification fails.

A conformance failure or error renders as a compiler-style diagnostic first
(a source excerpt with the responsible span underlined, then `help:`/`note:`
lines) whenever Notary can locate it in the spec or mapping file, followed by
the full step table. `--json` carries the same position as
`"location": {"file", "line", "column"}` on the `failure`/`error` object, so
an agent (or an editor) can jump straight there.

## The mapping module

```elixir
defmodule MyApp.Specs.Bank do
  use Notary.Conformance, spec: "specs/Bank.tla", observe: ["balance"]

  def init, do: MyApp.Bank.start_link()
  def actions, do: %{"Deposit" => StreamData.fixed_map(%{a: StreamData.integer(1..2)}), ...}
  def action("Deposit", %{a: a}, pid), do: ...   # {:ok, pid} | {:rejected, reason, pid}
  def project(pid), do: %{"balance" => MyApp.Bank.balance(pid)}
end
```

- `project/1` returns spec variables using `Notary.Value`'s representation:
  model values are `model("u1")`, sets are `set([...])`, sequences are lists,
  records are maps with string keys.
- Actions that the spec forbids must return `{:rejected, reason, ctx}` with
  state unchanged except for internal reactions (see `internal:` below).
  Notary checks guards too.
- Model the outside world (time, failing services) as spec actions, and have
  the mapping drive a stub.

### Internal actions

Some spec actions happen *inside* the implementation on their own, never on
request: a GenServer reacting to a message, a watchdog reaping a dead process,
a limit check killing a run. The mapping can't invoke these, and checking
state right after the triggering step would race the reaction.

```elixir
use Notary.Conformance, spec: "specs/Watchdog.tla", internal: ["Reap"]
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

By default (`generation: :walk`), sequences come from `Notary.Conformance.Walk`,
which walks the spec's state graph: about half of the generated values target
a graph edge directly (shortest path to it, then that transition); every value
then continues with mostly actions enabled somewhere in the current possible
set, some actions disabled everywhere (to exercise guards), and occasional
`:settle` points (design spec §5.1). Pass `generation: :uniform` to keep the Phase 1 generator
instead — uniform random picks from `actions/0`, no targeting, no `:settle`
points:

```elixir
use Notary.Conformance, spec: "specs/Bank.tla", generation: :uniform
```

`:uniform` is useful as a baseline when comparing behavior, or while
narrowing down whether a failure is particular to the walk's targeting.

### LiveView

`Notary.Conformance.LiveView` adds helpers for mapping modules that drive a
Phoenix LiveView instead of calling functions directly:

```elixir
defmodule MyAppWeb.Specs.Wizard do
  use Notary.Conformance, spec: "specs/Wizard.tla"
  import Notary.Conformance.LiveView

  def init, do: mount(MyAppWeb.WizardLive, endpoint: MyAppWeb.Endpoint)
  def action("Pay", _, ctx), do: click(ctx, "#pay")

  def project(ctx) do
    %{"step" => ctx |> text("#step-title") |> String.downcase(),
      "address" => has?(ctx, "#address-summary")}
  end

  def teardown(ctx), do: unmount(ctx)
end
```

Two rules are enforced: the UI must not offer what the spec forbids
(`action_not_enabled`, same as any mapping), and it must also *offer* what
the spec allows (`action_not_offered` — a missing or disabled element where
the spec says the action should be possible). Variables are read straight
from the rendered page with page-query helpers (`text/2`, `has?/2`,
`attr/3`, `value/2`, ...) — no Notary code or test-only markup in app
templates, since Notary is a `:dev`/`:test` dependency. `assigns/1` is an
escape hatch for state the page never shows. See the
[LiveView guide](guides/liveview.md) for the full walkthrough.

Measured on a three-step checkout wizard (seeds 1..10, default 100 runs,
spec `test/fixtures/specs/Wizard.tla`, script
`test/fixtures/measure_wizard.exs`): offering a forbidden action one step
early is caught by `action_not_enabled` on 10/10 seeds, and never offering an
allowed action is caught by `action_not_offered` on 10/10 seeds.

## Seeing the state space

```bash
mix notary.graph Bank --open                      # interactive HTML
mix notary.graph Bank --trace failure --open      # where the last conformance run diverged
mix notary.graph Bank --format mermaid            # for PRs and LLMs
```

## Limits (v1)

Actions are driven sequentially, so code-level races are not exercised. TLC
still checks the design across all interleavings. Liveness is checked only on
the spec, plus the bounded settle check for fair internal actions (above).
Keep `.cfg` constants small.

LiveView mappings (above) are single view, single actor (Phase 2a): no
PubSub from other processes, no JS hooks, and `render_async/2` settles only
the top-level view, not nested child LiveViews. Multi-view, multi-actor and
PubSub settling are Phase 2b.

The compiler-style diagnostic is a syntactic pointer, not a TLA+ evaluator, so
it can overclaim: a labelled effect conjunct might actually *disable* the
action rather than cause the bad transition (e.g. `x' \in {}`), a guard can be
hidden inside an operator call rather than written out in the action's own
`/\` list (so it's never labelled at all), and a `.cfg` `CONSTRAINT` can prune
states out of TLC's exploration entirely. Treat the diagnostic as a place to
start reading, not a verdict.

Every passing `check` reports a coverage summary (`coverage: actions R/T,
observed states R/T, transitions R/T`) plus `warning:` lines for gaps — read
them, don't just trust a pass. A gap can be genuine and permanent rather than
bad luck: on Notary's own `specs/TLCRunner.tla`, a couple of the graph's
states are reachable in TLC but never in the real implementation, because an
internal reaction (the state-limit kill beating a driven `Cancel`/`Timeout`
at the same instant) wins the timing race in every measured run — not a bug, just the
coverage report documenting exactly which graph states the implementation's
real timing rules out.

Random generation can also miss paths that *aren't* ruled out, just rare.
Measured on `specs/TLCRunner.tla` (`mix notary.verify --seed 1..10`, default
100 runs, `generation: :walk`):

- All 6 external actions plus both internal ones (`LimitKill`, `Reap`) are
  reached on 9 of 10 seeds (`coverage: actions 8/8`); one seed (8) misses
  `LimitKill` at the default 100 runs (`coverage: actions 7/8`,
  `warning: never reached: LimitKill`) — a rare-but-possible miss the
  coverage report surfaces rather than a conformance failure (see
  `--max-runs` below).
- A missing watchdog (the owner's `:DOWN` no longer kills the OS process) is
  caught on 10 of 10 seeds, failing `internal_action_stalled` (pending
  `Reap`) — the spec marks `Reap` fair, so settle points require it to happen.
- A disabled state-limit kill is caught on 7 of 10 seeds at the default 100
  runs, and on 10 of 10 at `--max-runs 300`, failing `internal_action_stalled`
  (pending `LimitKill`) with the minimal trace `Start, Progress, Progress,
  Progress`. This depends on the spec marking `LimitKill` fair
  (`WF_vars(LimitKill)`). Before that was added, the same bug passed
  conformance on 0 of 10 seeds, because an unfair internal action is never
  required to fire; only the coverage report (`warning: never reached:
  LimitKill`) hinted at it. The text warning names a count and the first
  unreached state; `--json`'s `coverage.states.unreached` lists the gap
  (capped at 20 entries, like the text warning).
  Read coverage warnings rather than relying on conformance pass/fail alone.

Raise `--max-runs` for specs where a missed-but-possible path matters. It
won't help an unfair internal action that silently stops firing: catching
that needs a human decision (mark it fair in the spec, as was done for
`LimitKill` here, or add a dedicated assertion), not more runs. `--seed`, `--max-runs` and `--json` are
CLI options on `mix notary.verify`/`mix notary.test`; `settle_timeout` is not
— it's set via `config :notary, settle_timeout: ...` — and `max_replays`
(the post-shrink minimization pass's replay budget) isn't exposed by any mix
task at all, only as an opt to `Notary.Conformance.Runner.check/4` directly.

## Developing Notary

```bash
nix develop                            # Elixir, Java and the TLA+ jar (no install step)
mix deps.get
mix test --include tlc                 # add --include e2e for the end-to-end test
mix notary.verify --max-runs 1000
mix run test/fixtures/regen_graphs.exs # after changing fixture specs
```
