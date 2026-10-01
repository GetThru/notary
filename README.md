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
  state unchanged. Outlaw checks guards too.
- Model the outside world (time, failing services) as spec actions, and have
  the mapping drive a stub.

## Seeing the state space

```bash
mix outlaw.graph Bank --open                      # interactive HTML
mix outlaw.graph Bank --trace failure --open      # where the last conformance run diverged
mix outlaw.graph Bank --format mermaid            # for PRs and LLMs
```

## Limits (v1)

Actions are driven sequentially, so code-level races are not exercised. TLC
still checks the design across all interleavings. Liveness is checked only on
the spec. Keep `.cfg` constants small.

## Developing Outlaw

```bash
nix develop
mix deps.get && mix run -e 'Outlaw.Tools.install()'
mix test --include tlc                 # add --include e2e for the end-to-end test
mix run test/fixtures/regen_graphs.exs # after changing fixture specs
```
