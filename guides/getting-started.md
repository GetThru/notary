# Getting Started: Hello, World

This guide takes you from an empty directory to a verified feature. You will:

1. create a Mix project and add Outlaw,
2. write a small TLA+ spec for a feature,
3. have the feature implemented (by an LLM agent, or by hand),
4. verify the implementation against the spec,
5. break it on purpose and read what Outlaw reports.

The feature is about as small as features get: a **greeter that prints
`Hello, world!` exactly once**. Asking it to greet a second time must be
refused. That's tiny, but it already has the two things Outlaw checks: a
change of state (not greeted → greeted) and a rule about when an action is
allowed (only before the first greeting).

## Before you start

You need:

- Elixir 1.18 or newer.
- Java 11 or newer, to run the TLA+ model checker (TLC). Check with
  `java -version`.
- A local copy of Outlaw. It isn't published to Hex yet, so this guide
  depends on it by path. The examples assume it lives next to your project,
  at `../outlaw`.

You don't need to know TLA+ already. Everything the spec uses is explained
as it comes up.

## 1. Create the project

```console
$ mix new hello_outlaw
$ cd hello_outlaw
```

## 2. Add Outlaw

Open `mix.exs` and make three changes:

```elixir
defmodule HelloOutlaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_outlaw,
      version: "0.1.0",
      elixir: "~> 1.19",
      # 1. Compile the mapping modules under test/outlaw in the test env.
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # 2. Run Outlaw's conformance tasks in the test environment.
  def cli do
    [preferred_envs: ["outlaw.test": :test, "outlaw.verify": :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/outlaw"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # 3. Outlaw itself, only needed in dev and test.
      {:outlaw, path: "../outlaw", only: [:dev, :test]}
    ]
  end
end
```

Then fetch dependencies and install the TLA+ tools. `mix outlaw.install`
downloads the pinned `tla2tools.jar`, checks its checksum, and checks Java:

```console
$ mix deps.get
$ mix outlaw.install
tla2tools.jar v1.7.4 ready at _build/outlaw/tla2tools.jar
Java OK: /usr/bin/java
```

## 3. Scaffold the spec

```console
$ mix outlaw.new Greeter
* creating specs/Greeter.tla
* creating specs/Greeter.cfg
* creating specs/AGENTS.md
* creating test/outlaw/greeter_spec.ex
* creating test/outlaw/greeter_conformance_test.exs
```

What each file is for:

| File | Who writes it | What it is |
|---|---|---|
| `specs/Greeter.tla` | **you** | The TLA+ spec: what the feature is allowed to do. |
| `specs/Greeter.cfg` | **you** | The model TLC checks (constants, invariants). |
| `specs/AGENTS.md` | generated once | Rules for LLM agents: never edit specs, how to verify. |
| `test/outlaw/greeter_spec.ex` | the implementer | The *mapping module* that connects the spec to your code. |
| `test/outlaw/greeter_conformance_test.exs` | generated | Runs the conformance check as part of `mix test`. |

`mix outlaw.new` also prints a snippet for your `CLAUDE.md` or `AGENTS.md`,
so that agents working in your project find `specs/AGENTS.md`. Add it if you
use an agent.

## 4. Write the spec

The scaffold's spec is a placeholder counter. Replace `specs/Greeter.tla`
with:

```tla
---------------------------- MODULE Greeter ----------------------------
\* Greeter: says "Hello, world!" exactly once.
EXTENDS Naturals

VARIABLE greeted        \* has the greeting been printed yet?

TypeOK == greeted \in BOOLEAN

Init == greeted = FALSE

\* Print the greeting. Only allowed if we haven't greeted yet.
Greet == /\ greeted = FALSE
         /\ greeted' = TRUE

Next == Greet

Spec == Init /\ [][Next]_greeted
=============================================================================
```

Reading it line by line:

- `VARIABLE greeted` is the feature's state. Specs describe *state* and the
  *actions* that change it.
- `TypeOK` is an invariant: `greeted` is always a boolean.
- `Init` is the starting state: nobody has been greeted.
- `Greet` is an action. It has two parts joined by `/\` ("and"):
  - `greeted = FALSE` is the **guard**. The action is only allowed when
    this is true.
  - `greeted' = TRUE` is the **effect**. A primed variable means "the
    value after the step".
- `Next` lists every action the feature has. Here there's only one.
- `Spec` says: start in `Init`, and every step is a `Next` step (or
  nothing changes).

Replace `specs/Greeter.cfg` with:

```
INIT Init
NEXT Next
INVARIANT TypeOK
\* After greeting there is nothing left to do; that's expected, not a deadlock.
CHECK_DEADLOCK FALSE
```

Now let TLC check the spec. It explores every reachable state and checks
`TypeOK` in each:

```console
$ mix outlaw.check Greeter
Greeter: pass
  check: pass (2 distinct states)

Outlaw: all checks passed.
```

Two states: not greeted, and greeted. When you're happy with the spec,
record it as reviewed:

```console
$ mix outlaw.lock
Locked 2 spec files in specs/.outlaw.lock:
  Greeter.cfg
  Greeter.tla
```

The lock file is your signature. From now on, if anyone (an LLM agent
included) changes a spec file without you running `mix outlaw.lock` again,
`mix outlaw.verify` fails. Commit the lock file along with your specs.

## 5. Get it implemented

This is where an LLM agent comes in. The spec is the whole requirement; you
don't need to describe the feature again in prose. A prompt like this is
enough:

> Implement the spec in `specs/Greeter.tla` as `HelloOutlaw.Greeter` in
> `lib/`. Read `specs/AGENTS.md` first. Complete the mapping module in
> `test/outlaw/greeter_spec.ex`, then run `mix outlaw.verify --json` and fix
> the code until it passes. Don't edit anything in `specs/`.

If you run `mix outlaw.verify` before anything is implemented, it already
tells you (and the agent) what's missing. Here, the scaffold's placeholder
actions don't exist in the new spec:

```console
$ mix outlaw.verify
lock: pass

Greeter: FAIL
  check: pass (2 distinct states)
  conformance: error
    error[invalid_mapping]: Invalid mapping HelloOutlaw.Specs.Greeter
       ╭─[test/outlaw/greeter_spec.ex:8:3]
       │
     6 │   See `Outlaw.Conformance` for the callbacks.
     7 │   """
     8 │   use Outlaw.Conformance, spec: "specs/Greeter.tla"
       •   ────────────────────────┬────────────────────────
       •                           ╰── use Outlaw.Conformance here
     9 │ 
    10 │   @impl true
       ⋮
    16 │ 
    17 │   @impl true
    18 │   def actions do
       •   ──────┬───────
       •         ╰── def actions
    19 │     # One entry per spec action: name => StreamData generator of params.
    20 │     %{
       │
       ╰─────
         help: actions/0 names actions that never occur in the spec's state graph: Increment, Reset. Known actions: Greet. (An action that is never enabled under the .cfg constants does not appear.)

    Invalid mapping HelloOutlaw.Specs.Greeter:
      actions/0 names actions that never occur in the spec's state graph: Increment, Reset. Known actions: Greet. (An action that is never enabled under the .cfg constants does not appear.)

Outlaw: verification FAILED.
```

The `error[invalid_mapping]` block is Outlaw rendering that error as a
compiler-style diagnostic, pointing straight at the `use Outlaw.Conformance`
line and the `def actions` that names the unknown actions, with the fix in
`help:`. The plain-text summary underneath is unchanged, for tools (or
terminals) that don't render the diagnostic.

Whether the agent writes it or you do, the result looks like this.

**The implementation**, `lib/hello_outlaw/greeter.ex`:

```elixir
defmodule HelloOutlaw.Greeter do
  @moduledoc "Says \"Hello, world!\" exactly once."
  use Agent

  @doc "Starts a greeter that writes to `device` (standard output by default)."
  def start_link(device \\ :stdio) do
    Agent.start_link(fn -> %{greeted: false, device: device} end)
  end

  @doc "Prints the greeting, unless this greeter has already greeted."
  def greet(greeter) do
    Agent.get_and_update(greeter, fn
      %{greeted: false} = state ->
        IO.puts(state.device, "Hello, world!")
        {:ok, %{state | greeted: true}}

      state ->
        {{:error, :already_greeted}, state}
    end)
  end

  @doc "Whether the greeting has been printed."
  def greeted?(greeter), do: Agent.get(greeter, & &1.greeted)
end
```

**The mapping module**, `test/outlaw/greeter_spec.ex`. It tells Outlaw how to
start your code, how to perform each spec action, and how to read your
code's state back as the spec's variables:

```elixir
defmodule HelloOutlaw.Specs.Greeter do
  use Outlaw.Conformance, spec: "specs/Greeter.tla"

  alias HelloOutlaw.Greeter

  @impl true
  def init do
    # Print into a StringIO instead of the terminal: Outlaw runs this
    # hundreds of times.
    {:ok, device} = StringIO.open("")
    {:ok, greeter} = Greeter.start_link(device)
    {:ok, %{greeter: greeter, device: device}}
  end

  @impl true
  def actions do
    # One entry per spec action, with a generator for its parameters.
    # Greet takes none.
    %{"Greet" => StreamData.constant(%{})}
  end

  @impl true
  def action("Greet", _params, ctx) do
    case Greeter.greet(ctx.greeter) do
      :ok -> {:ok, ctx}
      {:error, reason} -> {:rejected, reason, ctx}
    end
  end

  @impl true
  def project(ctx) do
    # The spec's variables, read from the implementation.
    %{"greeted" => Greeter.greeted?(ctx.greeter)}
  end
end
```

Two details matter here:

- **`{:rejected, reason, ctx}`.** When your code refuses an action, the
  mapping says so. Outlaw then checks the refusal was correct: the spec
  must also forbid that action in the current state, and your code's state
  must not have changed.
- **`project/1` returns spec values.** The keys are the spec's variable
  names as strings, and the values use TLA+ types: booleans, integers and
  strings as themselves (see `Outlaw.Value` for sets, sequences and
  records).

You can try the greeter by hand:

```console
$ mix run -e '{:ok, g} = HelloOutlaw.Greeter.start_link(); IO.inspect(HelloOutlaw.Greeter.greet(g)); IO.inspect(HelloOutlaw.Greeter.greet(g))'
Hello, world!
:ok
{:error, :already_greeted}
```

## 6. Verify

```console
$ mix outlaw.verify
lock: pass

Greeter: pass
  check: pass (2 distinct states)
  conformance: pass (100 runs, seed 624585)
    coverage: actions 1/1, observed states 2/2, transitions 1/1

Outlaw: all checks passed.
```

Here's what just happened:

- **lock** — the spec files match what you locked, so nobody changed them
  behind your back.
- **check** — TLC model-checked the spec again: no invariant is violated.
- **conformance** — Outlaw ran 100 generated sequences of `Greet` calls
  against your real code. After every step it compared your code's state
  (from `project/1`) with what the spec allows, and checked that refused
  actions really were forbidden.
- **coverage** — what those runs reached: every action, both states and the
  one transition. A gap would show up here as a `warning:` line.

The same check also runs with plain `mix test`, through the generated
`test/outlaw/greeter_conformance_test.exs`:

```console
$ mix test
...
1 doctest, 2 tests, 0 failures
```

## 7. Break it on purpose

To see what a failure looks like, remove the guard from `greet/1` so it
always greets:

```elixir
def greet(greeter) do
  Agent.get_and_update(greeter, fn state ->
    IO.puts(state.device, "Hello, world!")
    {:ok, %{state | greeted: true}}
  end)
end
```

```console
$ mix outlaw.verify
lock: pass

Greeter: FAIL
  check: pass (2 distinct states)
  conformance: fail
    error[action_not_enabled]: Greet was accepted, but the spec doesn't allow it in greeted = TRUE
       ╭─[specs/Greeter.tla:12:13]
       │
    10 │ 
    11 │ \* Print the greeting. Only allowed if we haven't greeted yet.
    12 │ Greet == /\ greeted = FALSE
       •             ───────┬───────
       •                    ╰── false here: greeted = TRUE
    13 │          /\ greeted' = TRUE
    14 │ 
       │
       ╰─────
         help: return {:rejected, reason, ctx}

    Conformance failure in Greeter: action_not_enabled (seed 100761)
    The implementation accepted an action the spec does not allow in this state. It should have returned {:rejected, reason, ctx}.

      step  action / params / outcome / implementation state
      0     (init)     ok          greeted = FALSE
      1     Greet %{}  ok          greeted = TRUE
      2     Greet %{}  ok          greeted = TRUE   <-- diverges here

    Spec allowed: (no Greet transition is enabled here)
    minimized: 2 replays, 0 items removed, 0 params reduced

    Reproduce: mix outlaw.test Greeter --seed 100761
    Visualize: mix outlaw.graph Greeter --trace failure --open

Outlaw: verification FAILED.
```

Reading the report:

- **`error[action_not_enabled]`** is the same failure rendered as a
  compiler-style diagnostic: it underlines the exact guard conjunct in
  `specs/Greeter.tla` that was false (`greeted = FALSE`, in a state where
  `greeted = TRUE`), with the fix (`help:`) right there instead of buried
  further down the report.
- **The step table** below it is the shortest sequence Outlaw found that
  triggers the bug: greet once (fine), then greet again. The second `Greet`
  should have been refused.
- **`Spec allowed:`** shows what the spec permitted at that step: nothing,
  because no `Greet` is allowed once `greeted = TRUE`.
- **`Reproduce:`** reruns exactly this failure, with the same seed.

You can also see the spec's state graph. `--format mermaid` prints a diagram
that renders on GitHub and in most markdown viewers. Without it, Outlaw
writes an interactive HTML page to `_build/outlaw/`.

```console
$ mix outlaw.graph Greeter --trace failure --format mermaid
stateDiagram-v2
    state "greeted = FALSE" as s0
    state "greeted = TRUE" as s1
    [*] --> s0
    s0 --> s1 : Greet
    classDef path stroke-width:3px,stroke:#d9480f
    class s0,s1 path
```

The graph has no `Greet` edge out of `greeted = TRUE`, and that's exactly the
step the broken code took. Put the guard back, and `mix outlaw.verify`
passes again.

## Next steps

- If you use an LLM agent, add the snippet `mix outlaw.new` printed to your
  `CLAUDE.md` or `AGENTS.md`, and let the agent run
  `mix outlaw.verify --json`. Its last line of output is a JSON report
  written for agents to read.
- For bigger features (several processes, hidden state, external services,
  reactions your code performs on its own) see the README sections on the
  mapping module, internal actions and coverage.
