# Notary Phase 1 (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Notary Elixir library through Phase 1: TLC integration, state-graph conformance testing, all `mix notary.*` tasks, and the HTML/Mermaid graph viewer.

**Architecture:** TLC (run as an OS port) model-checks a human-written spec and dumps its full reachable state graph as DOT. Notary parses that graph. A StreamData property then drives the real implementation through random action sequences via a user-written mapping module and checks each step against the graph. Mix tasks are the interface for humans, LLMs and CI.

**Tech Stack:** Elixir 1.19 / OTP 27, StreamData 1.x, stdlib `JSON`, EEx, TLA+ tools v1.7.4 (TLC 2.19) on Java 21, Cytoscape.js 3.34.3 (vendored), Nix flake dev shell.

**Spec:** `docs/superpowers/specs/2026-09-30-notary-design.md` (read it before starting any task).

## Global Constraints

- Package/app name `notary`; modules `Notary.*`; mix tasks `mix notary.*`; lock file `specs/.notary.lock`; work dir `_build/notary/`.
- Elixir `~> 1.18` (uses the stdlib `JSON` module, so there is no Jason dependency). The only Hex runtime dependency is `stream_data`.
- TLA+ tools pinned to v1.7.4: URL `https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar`, sha256 `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`. Java >= 11.
- TLC always runs with `-tool -workers auto -metadir <unique dir>`. A unique `-metadir` is mandatory, because two runs started in the same second otherwise collide on TLC's `states/` directory.
- Specs in `specs/` are human-authored; nothing in Notary ever writes `.tla`/`.cfg` files except `mix notary.new` (which refuses to overwrite).
- Every mix task supports `--json`. With `--json` the JSON report is the last line of stdout and is also written to `_build/notary/report.json`. On failure, tasks exit with status 1 (`exit({:shutdown, 1})`).
- Config defaults (`config :notary, ...`): `specs_dir: "specs"`, `work_dir: nil` (→ `_build/notary`), `tla2tools_path: nil` (→ `<work_dir>/tla2tools.jar`), `java: "java"`, `tlc_workers: "auto"`, `tlc_timeout: 300_000`, `max_states: 100_000`, `max_runs: 100`, `max_steps: 50`, `action_timeout: 5_000`.
- **Shell:** run every command inside the dev shell: `nix develop -c <command>`, or open `nix develop` once. Tests tagged `:tlc` need Java plus the jar (`mix notary.install`), tests tagged `:network` need internet, and tests tagged `:e2e` need both. `test/test_helper.exs` excludes these automatically when they can't run.

## Verified TLC facts (captured from TLC 2.19; parsers depend on them)

- DOT dump (`-dump dot,actionlabels file.dot`): one line per node, `ID [label="...",style = filled]` for initial states and `ID [label="..."]` otherwise. One line per edge, `FROM -> TO [label="Action",color="black",fontcolor="black"];`. IDs are signed 64-bit integers, which Notary keeps as strings. Stuttering steps (`UNCHANGED`) appear as self-loops. The `{rank = same; ...}` lines can be ignored.
- Label escaping inside DOT: `\\` → `\`, `\"` → `"`, `\n` → newline. With more than one variable a state label is `/\ var = value` lines; with exactly one variable it is `var = value` with no `/\ ` prefix. In DOT, each value stays on a single line.
- Value syntax: `(u1 :> 0 @@ u2 :> 0)` (functions), `[status |-> "open", n |-> 0]` (records), `{u1, u2}`, `<<u1, u2>>`, `<<>>`, `{}`, bare identifiers for model values, `"a \"q\" b"` strings, `TRUE`/`FALSE`. Functions with domain `1..n` print as `<<...>>`.
- `-tool` output wraps every message as `@!@!@STARTMSG <code>:<severity> @!@!@` … `@!@!@ENDMSG <code> @!@!@`. Codes used: 2110 invariant violated, 2107 invariant violated in initial state, 2108/2112 property violated, 2114 deadlock, 2116 temporal (liveness) violated, 2132 Assert failed, 2121/2264 trace headers, 2216/2217 trace state (`N: <Action line … of module M>` or `N: <Initial predicate>` followed by the state), 2218 stuttering (`N: Stuttering`), 2122 loop (`N: Back to state: <…>`), 2199 final stats (`X states generated, Y distinct states found, …`), 2200 progress.
- In traces (2217), long values **wrap across indented lines**. Action headers omit parameters (`<Flip line 6, …>` for `Flip(u)`).
- SANY parse/semantic errors are **raw text outside messages** (between messages 2220 and 2219). Exit codes: 0 ok, 11 deadlock, 12 safety, 13 liveness, 14 assert/eval, 150 SANY error.
- The DOT dump is identical with `-workers 1` and `-workers auto`.

## File Structure

```
mix.exs, .formatter.exs, .gitignore, flake.nix, README.md
lib/notary.ex                       # moduledoc only
lib/notary/config.ex                # config with defaults, paths, pinned tool metadata
lib/notary/error.ex                 # %Notary.Error{kind, message, details} exception
lib/notary/value.ex                 # TLC value parser + printer
lib/notary/state_graph.ex           # DOT → graph; state-label parser; queries
lib/notary/tlc/output.ex            # -tool output → items → result
lib/notary/spec.ex                  # spec discovery + content hash
lib/notary/cache.ex                 # graph cache in work dir
lib/notary/lock.ex                  # specs/.notary.lock
lib/notary/tools.ex                 # java/jar discovery, install
lib/notary/tools/tlc_runner.ex      # port runner with timeout and state limit
lib/notary/tlc.ex                   # check/2, dump/3, graph/2
lib/notary/conformance.ex           # behaviour, __using__, validate, check/3, assert_conforms/2, discover_mappings/1
lib/notary/conformance/step.ex      # %Step{}
lib/notary/conformance/failure.ex   # %Failure{}
lib/notary/conformance/runner.ex    # generator, per-run worker, step semantics
lib/notary/report.ex                # text + JSON rendering
lib/notary/verify.ex                # stage orchestration shared by mix tasks
lib/notary/cli.ex                   # shared mix-task plumbing
lib/notary/scaffold.ex              # notary.new file generation
lib/notary/viewer.ex                # viewer model, HTML, failure artifacts
lib/notary/viewer/mermaid.ex        # Mermaid output
lib/mix/tasks/notary.{install,new,check,test,verify,lock,graph}.ex
priv/templates/{spec.tla,spec.cfg,mapping.ex,conformance_test.exs,AGENTS.md}.eex
priv/viewer/{viewer.html.eex,viewer.js,cytoscape.min.js,VENDOR.md}
test/test_helper.exs
test/support/fixtures.ex            # graph(name) helper
test/support/fixtures/{counter,bank,orders}.ex           # implementations
test/support/fixtures/{counter,bank,workflow}_specs.ex    # mapping modules (correct + buggy)
test/fixtures/specs/{Counter,Bank,Workflow}.{tla,cfg}
test/fixtures/specs_bad/{Broken,Inv}.{tla,cfg}
test/fixtures/graphs/{Counter,Bank,Workflow}.dot          # generated by regen script, committed
test/fixtures/regen_graphs.exs
test/fixtures/tlc_output/*.out      # captured TLC -tool output
test/notary/**/*_test.exs
e2e/sample_app/**                   # end-to-end consumer project (outside test/ on purpose)
test/e2e_test.exs                   # drives it
```

---

### Task 1: Project scaffold, dev shell, config and error type

**Files:**
- Create: `mix.exs`, `.formatter.exs`, `.gitignore`, `flake.nix`, `lib/notary.ex`, `lib/notary/config.ex`, `lib/notary/error.ex`, `test/test_helper.exs`
- Test: `test/notary/config_test.exs`

**Interfaces:**
- Produces: `Notary.Config.get(key) :: term` (raises `KeyError` for unknown keys), `Notary.Config.work_dir() :: String.t()`, `Notary.Config.jar_path() :: String.t()`, `Notary.Config.specs_dir() :: String.t()` (absolute), `Notary.Config.tla_version() :: "1.7.4"`, `Notary.Config.jar_url()`, `Notary.Config.jar_sha256()`. `Notary.Error.new(kind :: atom, message :: String.t, details :: map \\ %{}) :: %Notary.Error{}`. `Notary.Error` is an exception (`raise Notary.Error.new(...)` works).

- [ ] **Step 1: Write the project files**

`mix.exs`:
```elixir
defmodule Notary.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :notary,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "TLA+ specifications as the contract between humans and LLMs for Elixir projects."
    ]
  end

  def application do
    [extra_applications: [:logger, :eex, :mix, :inets, :ssl, :public_key, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [{:stream_data, "~> 1.1"}]
  end
end
```

`.formatter.exs`:
```elixir
[inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]
```

`.gitignore`:
```
/_build/
/deps/
/cover/
/doc/
/.direnv/
erl_crash.dump
*.ez
states/
/e2e/sample_app/_build/
/e2e/sample_app/deps/
```

`flake.nix`:
```nix
{
  description = "Notary development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        beam = pkgs.beam.packages.erlang_27;
      in {
        devShells.default = pkgs.mkShell {
          packages = [ beam.erlang beam.elixir_1_19 pkgs.jdk21_headless ];
          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        };
      });
}
```
Also add `/.nix-mix/` and `/.nix-hex/` to `.gitignore`.

`lib/notary.ex`:
```elixir
defmodule Notary do
  @moduledoc """
  Notary uses human-written TLA+ specifications as the contract between a
  developer and an LLM: TLC model-checks the spec, the LLM implements it, and
  Notary verifies the implementation conforms to the spec's state graph.

  Any behavior not in the spec is uncertified. Start with `mix notary.new`.
  """
end
```

`lib/notary/error.ex`:
```elixir
defmodule Notary.Error do
  @moduledoc "A structured, actionable Notary error. Also usable as an exception."
  defexception [:kind, :message, details: %{}]

  @type t :: %__MODULE__{kind: atom(), message: String.t(), details: map()}

  @spec new(atom(), String.t(), map()) :: t()
  def new(kind, message, details \\ %{}) when is_atom(kind) and is_binary(message) do
    %__MODULE__{kind: kind, message: message, details: details}
  end
end
```

`lib/notary/config.ex`:
```elixir
defmodule Notary.Config do
  @moduledoc """
  Notary configuration (`config :notary, ...`) with defaults, plus the pinned
  TLA+ tools metadata.
  """

  @defaults [
    specs_dir: "specs",
    work_dir: nil,
    tla2tools_path: nil,
    java: "java",
    tlc_workers: "auto",
    tlc_timeout: 300_000,
    max_states: 100_000,
    max_runs: 100,
    max_steps: 50,
    action_timeout: 5_000
  ]

  @tla_version "1.7.4"

  @spec get(atom()) :: term()
  def get(key) when is_atom(key) do
    Application.get_env(:notary, key, Keyword.fetch!(@defaults, key))
  end

  @doc "Directory for Notary's generated files (`_build/notary` by default)."
  @spec work_dir() :: String.t()
  def work_dir do
    case get(:work_dir) do
      nil -> Path.expand("../notary", Mix.Project.build_path())
      dir -> Path.expand(dir)
    end
  end

  @spec jar_path() :: String.t()
  def jar_path, do: get(:tla2tools_path) || Path.join(work_dir(), "tla2tools.jar")

  @spec specs_dir() :: String.t()
  def specs_dir, do: Path.expand(get(:specs_dir))

  @spec tla_version() :: String.t()
  def tla_version, do: @tla_version

  @spec jar_url() :: String.t()
  def jar_url,
    do: "https://github.com/tlaplus/tlaplus/releases/download/v#{@tla_version}/tla2tools.jar"

  @spec jar_sha256() :: String.t()
  def jar_sha256, do: "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
end
```

`test/test_helper.exs`:
```elixir
java? = System.find_executable("java") != nil
jar? = File.exists?(Notary.Config.jar_path())

exclude =
  [:network, :e2e] ++
    if(java? and jar?, do: [], else: [:tlc])

if :tlc in exclude do
  IO.puts("Skipping :tlc tests (need java and `mix notary.install`).")
end

ExUnit.start(exclude: exclude)
```

- [ ] **Step 2: Write the failing config test**

`test/notary/config_test.exs`:
```elixir
defmodule Notary.ConfigTest do
  use ExUnit.Case, async: false

  alias Notary.Config

  setup do
    on_exit(fn ->
      for key <- [:max_states, :work_dir, :tla2tools_path], do: Application.delete_env(:notary, key)
    end)
  end

  test "returns defaults" do
    assert Config.get(:max_states) == 100_000
    assert Config.get(:tlc_workers) == "auto"
    assert Config.get(:java) == "java"
  end

  test "application env overrides defaults" do
    Application.put_env(:notary, :max_states, 10)
    assert Config.get(:max_states) == 10
  end

  test "unknown keys raise" do
    assert_raise KeyError, fn -> Config.get(:nope) end
  end

  test "work_dir defaults to _build/notary and jar lives inside it" do
    assert Config.work_dir() |> Path.split() |> Enum.take(-2) == ["_build", "notary"]
    assert Config.jar_path() == Path.join(Config.work_dir(), "tla2tools.jar")
  end

  test "work_dir and jar path can be overridden" do
    Application.put_env(:notary, :work_dir, "/tmp/notary-x")
    Application.put_env(:notary, :tla2tools_path, "/opt/tla2tools.jar")
    assert Config.work_dir() == "/tmp/notary-x"
    assert Config.jar_path() == "/opt/tla2tools.jar"
  end

  test "pinned tools metadata" do
    assert Config.tla_version() == "1.7.4"
    assert Config.jar_url() =~ "v1.7.4/tla2tools.jar"
    assert byte_size(Config.jar_sha256()) == 64
  end
end
```

- [ ] **Step 3: Enter the dev shell, fetch deps, run the tests**

```bash
git add flake.nix && nix develop -c mix deps.get
nix develop -c mix test test/notary/config_test.exs
```
Expected: 6 tests, 0 failures (plus the "Skipping :tlc tests" line). `nix develop` needs `flake.nix` tracked by git, which is why it's `git add`ed first. Commit the generated `flake.lock` too.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: scaffold notary project with config, error type and nix dev shell"
```

---

### Task 2: `Notary.Value` — TLC value parser and printer

**Files:**
- Create: `lib/notary/value.ex`
- Test: `test/notary/value_test.exs`

**Interfaces:**
- Produces: `Notary.Value.parse(binary) :: {:ok, t} | {:error, {:unparseable_value, binary}}`; `Notary.Value.to_tla(t) :: String.t()`; `Notary.Value.model(name :: String.t()) :: {:model_value, name}`; `Notary.Value.set(Enumerable.t()) :: MapSet.t()`. Representation: integer, boolean, binary, `{:model_value, name}`, `MapSet`, list (sequences), map (records have binary keys; functions are keyed by parsed keys).

- [ ] **Step 1: Write the failing tests**

`test/notary/value_test.exs`:
```elixir
defmodule Notary.ValueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Notary.Value

  describe "parse/1 with real TLC output" do
    test "scalars" do
      assert Value.parse("0") == {:ok, 0}
      assert Value.parse("-3") == {:ok, -3}
      assert Value.parse("TRUE") == {:ok, true}
      assert Value.parse("FALSE") == {:ok, false}
      assert Value.parse(~S("open")) == {:ok, "open"}
      assert Value.parse("u1") == {:ok, {:model_value, "u1"}}
    end

    test "escaped strings" do
      assert Value.parse(~S("a \"q\" b")) == {:ok, ~S(a "q" b)}
      assert Value.parse(~S("back\\slash")) == {:ok, ~S(back\slash)}
      assert Value.parse(~S("line\nbreak")) == {:ok, "line\nbreak"}
    end

    test "sets and sequences" do
      assert Value.parse("{}") == {:ok, MapSet.new()}
      assert Value.parse("{u1, u2}") == {:ok, MapSet.new([{:model_value, "u1"}, {:model_value, "u2"}])}
      assert Value.parse("<<>>") == {:ok, []}
      assert Value.parse("<<u2, u1>>") == {:ok, [{:model_value, "u2"}, {:model_value, "u1"}]}
      assert Value.parse("<<100, 200, 300, 400>>") == {:ok, [100, 200, 300, 400]}
      assert Value.parse("<<1, <<2>>>>") == {:ok, [1, [2]]}
    end

    test "records" do
      assert Value.parse(~S([status |-> "open", n |-> 0])) ==
               {:ok, %{"status" => "open", "n" => 0}}
    end

    test "functions" do
      assert Value.parse("(u1 :> 0 @@ u2 :> 1)") ==
               {:ok, %{{:model_value, "u1"} => 0, {:model_value, "u2"} => 1}}

      assert Value.parse("(1 :> TRUE)") == {:ok, %{1 => true}}
    end

    test "values wrapped across lines in TLC traces" do
      raw = """
      [ a |-> 1,
        bbbb |->
            { "cccc",
              "dddd" } ]
      """

      assert Value.parse(raw) == {:ok, %{"a" => 1, "bbbb" => MapSet.new(["cccc", "dddd"])}}
    end

    test "garbage is an error carrying the raw text" do
      for raw <- ["[a |-> ", "{1,", "<<1 2>>", "(1 :> )", "\"open", "1 2", "", "?"] do
        assert Value.parse(raw) == {:error, {:unparseable_value, raw}}
      end
    end
  end

  describe "to_tla/1" do
    test "prints canonical TLA+ syntax" do
      assert Value.to_tla(%{"status" => "open", "n" => 0}) == ~S([n |-> 0, status |-> "open"])
      assert Value.to_tla(%{Value.model("u1") => 0}) == "(u1 :> 0)"
      assert Value.to_tla(MapSet.new([2, 1])) == "{1, 2}"
      assert Value.to_tla([1, "x"]) == ~S(<<1, "x">>)
      assert Value.to_tla(~S(a "q")) == ~S("a \"q\"")
      assert Value.to_tla(true) == "TRUE"
      assert Value.to_tla(%{}) == "<<>>"
    end
  end

  property "parse(to_tla(v)) round-trips" do
    check all value <- value_gen(), max_runs: 300 do
      assert Value.parse(Value.to_tla(value)) == {:ok, value}
    end
  end

  defp ident, do: string(?a..?z, min_length: 1, max_length: 6)

  defp value_gen do
    leaf =
      one_of([
        integer(),
        boolean(),
        string(:printable, max_length: 6),
        map(ident(), &Value.model/1)
      ])

    tree(leaf, fn child ->
      one_of([
        map(list_of(child, max_length: 3), &MapSet.new/1),
        list_of(child, max_length: 3),
        map_of(ident(), child, min_length: 1, max_length: 3),
        map_of(child, child, min_length: 1, max_length: 3)
      ])
    end)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/value_test.exs`
Expected: FAIL, `Notary.Value.parse/1 is undefined`.

- [ ] **Step 3: Implement `lib/notary/value.ex`**

```elixir
defmodule Notary.Value do
  @moduledoc """
  Parses TLC's printed value syntax into Elixir terms and prints them back.

  | TLA+                              | Elixir                     |
  |-----------------------------------|----------------------------|
  | integers                          | integer                    |
  | `TRUE` / `FALSE`                  | `true` / `false`           |
  | `"str"`                           | binary                     |
  | model value `u1`                  | `{:model_value, "u1"}`     |
  | `{a, b}`                          | `MapSet`                   |
  | `<<a, b>>` (and functions on 1..n)| list                       |
  | `[f \|-> v]`                      | map with binary keys       |
  | `(k1 :> v1 @@ k2 :> v2)`          | map keyed by parsed keys   |

  Mapping modules return values in this representation from `project/1`.
  """

  @type t ::
          integer()
          | boolean()
          | binary()
          | {:model_value, binary()}
          | MapSet.t()
          | list()
          | map()

  @spec model(String.t()) :: {:model_value, String.t()}
  def model(name) when is_binary(name), do: {:model_value, name}

  @spec set(Enumerable.t()) :: MapSet.t()
  def set(enum), do: MapSet.new(enum)

  @spec parse(binary()) :: {:ok, t()} | {:error, {:unparseable_value, binary()}}
  def parse(raw) when is_binary(raw) do
    with {:ok, tokens} <- tokenize(raw, []),
         {:ok, value, []} <- parse_value(tokens) do
      {:ok, value}
    else
      _ -> {:error, {:unparseable_value, raw}}
    end
  end

  # -- tokenizer ------------------------------------------------------------

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\n, ?\t, ?\r], do: tokenize(rest, acc)
  defp tokenize("<<" <> rest, acc), do: tokenize(rest, [:lseq | acc])
  defp tokenize(">>" <> rest, acc), do: tokenize(rest, [:rseq | acc])
  defp tokenize("|->" <> rest, acc), do: tokenize(rest, [:maps_to | acc])
  defp tokenize(":>" <> rest, acc), do: tokenize(rest, [:colon_gt | acc])
  defp tokenize("@@" <> rest, acc), do: tokenize(rest, [:at_at | acc])
  defp tokenize("{" <> rest, acc), do: tokenize(rest, [:lbrace | acc])
  defp tokenize("}" <> rest, acc), do: tokenize(rest, [:rbrace | acc])
  defp tokenize("[" <> rest, acc), do: tokenize(rest, [:lbracket | acc])
  defp tokenize("]" <> rest, acc), do: tokenize(rest, [:rbracket | acc])
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize("," <> rest, acc), do: tokenize(rest, [:comma | acc])

  defp tokenize("\"" <> rest, acc) do
    case read_string(rest, []) do
      {:ok, string, rest} -> tokenize(rest, [{:string, string} | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?0..?9 or c == ?- do
    case Integer.parse(bin) do
      {int, rest} -> tokenize(rest, [{:int, int} | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    [ident] = Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, bin)
    rest = binary_part(bin, byte_size(ident), byte_size(bin) - byte_size(ident))
    tokenize(rest, [ident_token(ident) | acc])
  end

  defp tokenize(_, _acc), do: :error

  defp ident_token("TRUE"), do: {:bool, true}
  defp ident_token("FALSE"), do: {:bool, false}
  defp ident_token(name), do: {:ident, name}

  defp read_string("\\\"" <> rest, acc), do: read_string(rest, [?" | acc])
  defp read_string("\\\\" <> rest, acc), do: read_string(rest, [?\\ | acc])
  defp read_string("\\n" <> rest, acc), do: read_string(rest, [?\n | acc])
  defp read_string("\\t" <> rest, acc), do: read_string(rest, [?\t | acc])
  defp read_string("\"" <> rest, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp read_string(<<c::utf8, rest::binary>>, acc), do: read_string(rest, [<<c::utf8>> | acc])
  defp read_string(_, _acc), do: :error

  # -- parser ---------------------------------------------------------------

  defp parse_value([{:int, i} | rest]), do: {:ok, i, rest}
  defp parse_value([{:string, s} | rest]), do: {:ok, s, rest}
  defp parse_value([{:bool, b} | rest]), do: {:ok, b, rest}
  defp parse_value([{:ident, name} | rest]), do: {:ok, {:model_value, name}, rest}
  defp parse_value([:lbrace, :rbrace | rest]), do: {:ok, MapSet.new(), rest}

  defp parse_value([:lbrace | rest]) do
    with {:ok, items, rest} <- parse_items(rest, :rbrace), do: {:ok, MapSet.new(items), rest}
  end

  defp parse_value([:lseq, :rseq | rest]), do: {:ok, [], rest}
  defp parse_value([:lseq | rest]), do: parse_items(rest, :rseq)

  defp parse_value([:lbracket | rest]) do
    with {:ok, pairs, rest} <- parse_fields(rest, []), do: {:ok, Map.new(pairs), rest}
  end

  defp parse_value([:lparen | rest]) do
    with {:ok, pairs, rest} <- parse_function(rest, []), do: {:ok, Map.new(pairs), rest}
  end

  defp parse_value(_), do: :error

  defp parse_items(tokens, close) do
    with {:ok, value, rest} <- parse_value(tokens) do
      case rest do
        [:comma | rest] ->
          with {:ok, values, rest} <- parse_items(rest, close), do: {:ok, [value | values], rest}

        [^close | rest] ->
          {:ok, [value], rest}

        _ ->
          :error
      end
    end
  end

  defp parse_fields([{:ident, key}, :maps_to | rest], acc) do
    with {:ok, value, rest} <- parse_value(rest) do
      case rest do
        [:comma | rest] -> parse_fields(rest, [{key, value} | acc])
        [:rbracket | rest] -> {:ok, Enum.reverse([{key, value} | acc]), rest}
        _ -> :error
      end
    end
  end

  defp parse_fields(_, _acc), do: :error

  defp parse_function(tokens, acc) do
    with {:ok, key, [:colon_gt | rest]} <- parse_value(tokens),
         {:ok, value, rest} <- parse_value(rest) do
      case rest do
        [:at_at | rest] -> parse_function(rest, [{key, value} | acc])
        [:rparen | rest] -> {:ok, Enum.reverse([{key, value} | acc]), rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  # -- printer --------------------------------------------------------------

  @spec to_tla(t()) :: String.t()
  def to_tla(true), do: "TRUE"
  def to_tla(false), do: "FALSE"
  def to_tla(int) when is_integer(int), do: Integer.to_string(int)
  def to_tla(string) when is_binary(string), do: quote_string(string)
  def to_tla({:model_value, name}), do: name
  def to_tla(%MapSet{} = set), do: "{" <> join(Enum.sort(set)) <> "}"
  def to_tla(list) when is_list(list), do: "<<" <> join(list) <> ">>"
  def to_tla(map) when map_size(map) == 0, do: "<<>>"

  def to_tla(map) when is_map(map) do
    sorted = Enum.sort(map)

    if Enum.all?(Map.keys(map), &record_key?/1) do
      "[" <> Enum.map_join(sorted, ", ", fn {k, v} -> "#{k} |-> #{to_tla(v)}" end) <> "]"
    else
      "(" <> Enum.map_join(sorted, " @@ ", fn {k, v} -> "#{to_tla(k)} :> #{to_tla(v)}" end) <> ")"
    end
  end

  defp join(values), do: Enum.map_join(values, ", ", &to_tla/1)

  defp record_key?(key),
    do: is_binary(key) and key not in ["TRUE", "FALSE"] and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key)

  defp quote_string(string) do
    escaped =
      string
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/value_test.exs`
Expected: all tests and the property pass. If the property finds a counterexample, fix the parser or printer. Do not weaken the generator, except to exclude empty maps, since `%{}` prints as `<<>>` and that ambiguity is intentional. (The `min_length: 1` already excludes them.)

- [ ] **Step 5: Commit**

```bash
git add lib/notary/value.ex test/notary/value_test.exs
git commit -m "feat: parse and print TLC values"
```

---

### Task 3: `Notary.StateGraph` — DOT dump parser and queries

**Files:**
- Create: `lib/notary/state_graph.ex`
- Test: `test/notary/state_graph_test.exs`

**Interfaces:**
- Consumes: `Notary.Value.parse/1`, `Notary.Error.new/3`.
- Produces: `%Notary.StateGraph{states: %{id => %{var => value}}, edges: %{{id, action} => [id]}, initial: [id], actions: MapSet.t(String.t()), variables: [String.t()]}` with `id :: String.t()`; `parse_dot(binary) :: {:ok, t} | {:error, Notary.Error.t()}`; `parse_state(String.t()) :: {:ok, %{String.t() => Value.t()}} | {:error, Notary.Error.t()}` (accepts both `/\ v = x` lines and a single `v = x`, and tolerates wrapped multi-line values); `initial_states(t) :: [id]`; `successors(t, id, action) :: [id]`; `state(t, id) :: map`; `edges(t) :: [{from, action, to}]` (sorted); `size(t) :: non_neg_integer`.

- [ ] **Step 1: Write the failing tests** (the DOT text is real TLC 2.19 output)

`test/notary/state_graph_test.exs`:
```elixir
defmodule Notary.StateGraphTest do
  use ExUnit.Case, async: true

  alias Notary.{StateGraph, Value}

  @counter_dot ~S"""
  strict digraph DiskGraph {
  nodesep=0.35;
  subgraph cluster_graph {
  color="white";
  -1367331574555479329 [label="x = 0",style = filled]
  -1367331574555479329 -> -637813419044459402 [label="Inc",color="black",fontcolor="black"];
  -637813419044459402 [label="x = 1"];
  -637813419044459402 -> -2790308373070655603 [label="Inc",color="black",fontcolor="black"];
  -2790308373070655603 [label="x = 2"];
  -2790308373070655603 -> -1367331574555479329 [label="Reset",color="black",fontcolor="black"];
  -1367331574555479329 -> -1367331574555479329 [label="Reset",color="black",fontcolor="black"];
  {rank = same; -1367331574555479329;}
  {rank = same; -637813419044459402;}
  }
  }
  """

  @bank_dot ~S"""
  strict digraph DiskGraph {
  nodesep=0.35;
  subgraph cluster_graph {
  color="white";
  -6317523553004397193 [label="/\\ seen = {}\n/\\ bal = (u1 :> 0 @@ u2 :> 0)\n/\\ meta = [status |-> \"open\", n |-> 0]\n/\\ log = <<>>",style = filled]
  -6317523553004397193 -> 4780036596849210003 [label="Deposit",color="black",fontcolor="black"];
  4780036596849210003 [label="/\\ seen = {u1}\n/\\ bal = (u1 :> 1 @@ u2 :> 0)\n/\\ meta = [status |-> \"open\", n |-> 1]\n/\\ log = <<u1>>"];
  -6317523553004397193 -> -2595030384104833759 [label="Deposit",color="black",fontcolor="black"];
  -2595030384104833759 [label="/\\ seen = {u2}\n/\\ bal = (u1 :> 0 @@ u2 :> 1)\n/\\ meta = [status |-> \"open\", n |-> 1]\n/\\ log = <<u2>>"];
  }
  }
  """

  @escaped_dot ~S"""
  strict digraph DiskGraph {
  -6920471283936856595 [label="r = [s |-> \"a \\\"q\\\" b\", k |-> <<100, 200>>]",style = filled]
  -6920471283936856595 -> -6920471283936856595 [label="Next",color="black",fontcolor="black"];
  }
  """

  test "parses single-variable states, initial states, edges and self-loops" do
    assert {:ok, graph} = StateGraph.parse_dot(@counter_dot)
    assert StateGraph.size(graph) == 3
    assert graph.variables == ["x"]
    assert graph.actions == MapSet.new(["Inc", "Reset"])
    assert [init] = StateGraph.initial_states(graph)
    assert StateGraph.state(graph, init) == %{"x" => 0}
    assert StateGraph.successors(graph, init, "Reset") == [init]
    assert [one] = StateGraph.successors(graph, init, "Inc")
    assert StateGraph.state(graph, one) == %{"x" => 1}
    assert StateGraph.successors(graph, one, "Reset") == []
    assert length(StateGraph.edges(graph)) == 4
  end

  test "parses multi-variable states with model values, functions and records" do
    assert {:ok, graph} = StateGraph.parse_dot(@bank_dot)
    assert graph.variables == ["bal", "log", "meta", "seen"]
    [init] = StateGraph.initial_states(graph)

    assert StateGraph.state(graph, init) == %{
             "seen" => MapSet.new(),
             "bal" => %{Value.model("u1") => 0, Value.model("u2") => 0},
             "meta" => %{"status" => "open", "n" => 0},
             "log" => []
           }

    targets = StateGraph.successors(graph, init, "Deposit")
    assert length(targets) == 2

    assert targets |> Enum.map(&StateGraph.state(graph, &1)["log"]) |> Enum.sort() ==
             [[Value.model("u1")], [Value.model("u2")]]
  end

  test "unescapes DOT labels before parsing TLA+ strings" do
    assert {:ok, graph} = StateGraph.parse_dot(@escaped_dot)
    [init] = StateGraph.initial_states(graph)
    assert StateGraph.state(graph, init) == %{"r" => %{"s" => ~S(a "q" b), "k" => [100, 200]}}
  end

  test "parse_state handles wrapped trace values" do
    text = """
    /\\ r = [ a |-> 1,
      bbbb |->
          { "cccc",
            "dddd" } ]
    /\\ x = 0
    """

    assert StateGraph.parse_state(text) ==
             {:ok, %{"r" => %{"a" => 1, "bbbb" => MapSet.new(["cccc", "dddd"])}, "x" => 0}}
  end

  test "unparseable state labels are reported as an Notary bug with the raw text" do
    dot = ~S"""
    1 [label="x = [oops",style = filled]
    """

    assert {:error, %Notary.Error{kind: :unparseable_state, details: %{raw: "x = [oops"}}} =
             StateGraph.parse_dot(dot)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/state_graph_test.exs`
Expected: FAIL, `Notary.StateGraph.parse_dot/1 is undefined`.

- [ ] **Step 3: Implement `lib/notary/state_graph.ex`**

```elixir
defmodule Notary.StateGraph do
  @moduledoc """
  The reachable state graph of a spec, parsed from TLC's
  `-dump dot,actionlabels` output. State ids are TLC fingerprints (strings).
  """

  alias Notary.{Error, Value}

  defstruct states: %{}, edges: %{}, initial: [], actions: MapSet.new(), variables: []

  @type state_id :: String.t()
  @type t :: %__MODULE__{
          states: %{state_id() => %{String.t() => Value.t()}},
          edges: %{{state_id(), String.t()} => [state_id()]},
          initial: [state_id()],
          actions: MapSet.t(String.t()),
          variables: [String.t()]
        }

  @edge ~r/^(-?\d+) -> (-?\d+) \[label="((?:[^"\\]|\\.)*)"/
  @node ~r/^(-?\d+) \[label="(.*)"(,style = filled)?\];?$/

  @spec parse_dot(binary()) :: {:ok, t()} | {:error, Error.t()}
  def parse_dot(dot) when is_binary(dot) do
    dot
    |> String.split("\n")
    |> Enum.reduce_while({:ok, %__MODULE__{}}, fn line, {:ok, graph} ->
      case parse_line(String.trim(line), graph) do
        {:ok, graph} -> {:cont, {:ok, graph}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, graph} -> {:ok, finalize(graph)}
      error -> error
    end
  end

  defp parse_line(line, graph) do
    cond do
      match = Regex.run(@edge, line) ->
        [_, from, to, action] = match
        action = unescape(action)
        edges = Map.update(graph.edges, {from, action}, [to], &[to | &1])
        {:ok, %{graph | edges: edges, actions: MapSet.put(graph.actions, action)}}

      match = Regex.run(@node, line) ->
        [_, id, label | style] = match

        with {:ok, vars} <- parse_state(unescape(label)) do
          initial = if style == [], do: graph.initial, else: [id | graph.initial]
          {:ok, %{graph | states: Map.put(graph.states, id, vars), initial: initial}}
        end

      true ->
        {:ok, graph}
    end
  end

  defp finalize(graph) do
    edges = Map.new(graph.edges, fn {key, targets} -> {key, targets |> Enum.reverse() |> Enum.uniq()} end)

    variables =
      case Map.values(graph.states) do
        [first | _] -> first |> Map.keys() |> Enum.sort()
        [] -> []
      end

    %{graph | edges: edges, initial: Enum.reverse(graph.initial), variables: variables}
  end

  defp unescape(text) do
    Regex.replace(~r/\\(.)/s, text, fn
      _, "n" -> "\n"
      _, char -> char
    end)
  end

  @doc "Parses a TLC state: `/\\ var = value` lines, or a single `var = value`."
  @spec parse_state(String.t()) :: {:ok, %{String.t() => Value.t()}} | {:error, Error.t()}
  def parse_state(text) do
    text = String.trim(text)

    chunks =
      if String.starts_with?(text, "/\\ "),
        do: String.split(text, ~r/^\/\\ /m, trim: true),
        else: [text]

    Enum.reduce_while(chunks, {:ok, %{}}, fn chunk, {:ok, acc} ->
      chunk = String.trim(chunk)

      with [_, var, raw] <- Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*) = (.*)$/s, chunk),
           {:ok, value} <- Value.parse(raw) do
        {:cont, {:ok, Map.put(acc, var, value)}}
      else
        _ ->
          {:halt,
           {:error,
            Error.new(
              :unparseable_state,
              "Notary could not parse a TLC state. This is an Notary bug; please report it with the raw text.",
              %{raw: chunk}
            )}}
      end
    end)
  end

  @spec initial_states(t()) :: [state_id()]
  def initial_states(%__MODULE__{initial: initial}), do: initial

  @spec successors(t(), state_id(), String.t()) :: [state_id()]
  def successors(%__MODULE__{edges: edges}, id, action), do: Map.get(edges, {id, action}, [])

  @spec state(t(), state_id()) :: %{String.t() => Value.t()}
  def state(%__MODULE__{states: states}, id), do: Map.fetch!(states, id)

  @spec edges(t()) :: [{state_id(), String.t(), state_id()}]
  def edges(%__MODULE__{edges: edges}) do
    for {{from, action}, targets} <- Enum.sort(edges), to <- targets, do: {from, action, to}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{states: states}), do: map_size(states)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/state_graph_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/notary/state_graph.ex test/notary/state_graph_test.exs
git commit -m "feat: parse TLC DOT state graphs"
```

---

### Task 4: `Notary.TLC.Output` — interpret TLC `-tool` output

**Files:**
- Create: `lib/notary/tlc/output.ex`, `test/fixtures/tlc_output/{pass,invariant,deadlock,liveness,assert,parse_error,semantic_error}.out`
- Test: `test/notary/tlc/output_test.exs`

**Interfaces:**
- Consumes: `Notary.StateGraph.parse_state/1`, `Notary.Error.new/3`.
- Produces:
  - `Notary.TLC.Output.items(binary) :: [{:message, %{code: integer, severity: integer, body: String.t()}} | {:text, String.t()}]`
  - `Notary.TLC.Output.interpret(items, exit_status :: integer) :: result`, where `result :: {:ok, stats} | {:violation, violation} | {:error, Notary.Error.t()}`, `stats :: %{distinct_states: integer, states_generated: integer}`, and `violation :: %{kind: :invariant | :deadlock | :liveness | :assertion | :property, name: String.t() | nil, message: String.t(), trace: [step]}`.
  - `step` is `%{index: pos_integer, action: String.t() | nil, state: map}` (action `nil` = initial state), `%{index: pos_integer, stuttering: true}`, or `%{index: pos_integer, back_to: pos_integer}`. A state that cannot be parsed yields `state: %{}` plus a `raw: text` key.
  - Spec errors are `%Notary.Error{kind: :spec_error, details: %{output: text, location: %{module: String.t(), line: integer, column: integer} | nil}}`. Other failures are `kind: :tlc_failed`.

- [ ] **Step 1: Create the captured-output fixtures** (real TLC 2.19 output, abridged to the messages the parser reads)

`test/fixtures/tlc_output/pass.out`:
```
@!@!@STARTMSG 2262:0 @!@!@
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
@!@!@ENDMSG 2262 @!@!@
@!@!@STARTMSG 2185:0 @!@!@
Starting... (2026-09-30 22:37:34)
@!@!@ENDMSG 2185 @!@!@
@!@!@STARTMSG 2193:0 @!@!@
Model checking completed. No error has been found.
  Estimates of the probability that TLC did not check all reachable states
  because two distinct states had the same fingerprint:
  calculated (optimistic):  val = 2.2E-18
@!@!@ENDMSG 2193 @!@!@
@!@!@STARTMSG 2200:0 @!@!@
Progress(4) at 2026-09-30 22:37:34: 14 states generated (1,869 s/min), 10 distinct states found (1,300 ds/min), 0 states left on queue.
@!@!@ENDMSG 2200 @!@!@
@!@!@STARTMSG 2199:0 @!@!@
14 states generated, 10 distinct states found, 0 states left on queue.
@!@!@ENDMSG 2199 @!@!@
@!@!@STARTMSG 2186:0 @!@!@
Finished in 279ms at (2026-09-30 22:37:34)
@!@!@ENDMSG 2186 @!@!@
```

`test/fixtures/tlc_output/invariant.out`:
```
@!@!@STARTMSG 2185:0 @!@!@
Starting... (2026-09-30 22:37:49)
@!@!@ENDMSG 2185 @!@!@
@!@!@STARTMSG 2110:1 @!@!@
Invariant Inv is violated.
@!@!@ENDMSG 2110 @!@!@
@!@!@STARTMSG 2121:1 @!@!@
The behavior up to this point is:
@!@!@ENDMSG 2121 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
1: <Initial predicate>
x = 0

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
2: <Inc line 6, col 8 to line 6, col 17 of module Counter>
x = 1

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
3: <Inc line 6, col 8 to line 6, col 17 of module Counter>
x = 2

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2199:0 @!@!@
4 states generated, 4 distinct states found, 0 states left on queue.
@!@!@ENDMSG 2199 @!@!@
```

`test/fixtures/tlc_output/deadlock.out`:
```
@!@!@STARTMSG 2114:1 @!@!@
Deadlock reached.
@!@!@ENDMSG 2114 @!@!@
@!@!@STARTMSG 2121:1 @!@!@
The behavior up to this point is:
@!@!@ENDMSG 2121 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
1: <Initial predicate>
x = 0

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
2: <Next line 5, col 9 to line 5, col 27 of module Dead>
x = 1

@!@!@ENDMSG 2217 @!@!@
```

`test/fixtures/tlc_output/liveness.out`:
```
@!@!@STARTMSG 2116:1 @!@!@
Temporal properties were violated.

@!@!@ENDMSG 2116 @!@!@
@!@!@STARTMSG 2264:1 @!@!@
The following behavior constitutes a counter-example:

@!@!@ENDMSG 2264 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
1: <Initial predicate>
/\ r = [ a |-> 1,
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb |->
      { "cccccccccccccccccccccccccc",
        "dddddddddddddddddddddddddddddd" } ]
/\ x = 0

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
2: <Flip line 6, col 12 to line 6, col 36 of module Loop>
/\ r = [ a |-> 1,
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb |->
      { "cccccccccccccccccccccccccc",
        "dddddddddddddddddddddddddddddd" } ]
/\ x = 1

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2122:4 @!@!@
1: Back to state: <Flip line 6, col 12 to line 6, col 36 of module Loop>

@!@!@ENDMSG 2122 @!@!@
@!@!@STARTMSG 2218:4 @!@!@
3: Stuttering
@!@!@ENDMSG 2218 @!@!@
```

`test/fixtures/tlc_output/assert.out`:
```
@!@!@STARTMSG 2132:1 @!@!@
The first argument of Assert evaluated to FALSE; the second argument was:
"x too big"
@!@!@ENDMSG 2132 @!@!@
@!@!@STARTMSG 2121:1 @!@!@
The behavior up to this point is:
@!@!@ENDMSG 2121 @!@!@
@!@!@STARTMSG 2217:4 @!@!@
1: <Initial predicate>
x = 0

@!@!@ENDMSG 2217 @!@!@
@!@!@STARTMSG 2103:1 @!@!@
The error occurred when TLC was evaluating the nested
expressions at the following positions:
0. Line 5, column 9 to line 6, column 21 in Asrt
@!@!@ENDMSG 2103 @!@!@
```

`test/fixtures/tlc_output/parse_error.out`:
```
@!@!@STARTMSG 2220:0 @!@!@
Starting SANY...
@!@!@ENDMSG 2220 @!@!@
Parsing file /tmp/specs/Bad.tla
***Parse Error***
Was expecting "Expression or Instance"
Encountered "Beginning of definition" at line 3, column 9 and token "==" 

Residual stack trace follows:
Definition starting at line 3, column 1.

Fatal errors while parsing TLA+ spec in file Bad

*** Abort messages: 1

In module Bad

Could not parse module Bad from file Bad.tla
@!@!@STARTMSG 2219:0 @!@!@
SANY finished.
@!@!@ENDMSG 2219 @!@!@
@!@!@STARTMSG 3002:1 @!@!@
@!@!@ENDMSG 3002 @!@!@
```

`test/fixtures/tlc_output/semantic_error.out`:
```
@!@!@STARTMSG 2220:0 @!@!@
Starting SANY...
@!@!@ENDMSG 2220 @!@!@
Semantic processing of module Sem

*** Errors: 1

line 3, col 13 to line 3, col 13 of module Sem

Unknown operator: `y'.

@!@!@STARTMSG 2219:0 @!@!@
SANY finished.
@!@!@ENDMSG 2219 @!@!@
```

- [ ] **Step 2: Write the failing tests**

`test/notary/tlc/output_test.exs`:
```elixir
defmodule Notary.TLC.OutputTest do
  use ExUnit.Case, async: true

  alias Notary.TLC.Output

  defp interpret(name, exit_status) do
    "test/fixtures/tlc_output/#{name}.out"
    |> File.read!()
    |> Output.items()
    |> Output.interpret(exit_status)
  end

  test "items/1 splits messages and raw text" do
    items = Output.items(File.read!("test/fixtures/tlc_output/parse_error.out"))
    assert {:message, %{code: 2220, severity: 0, body: "Starting SANY..."}} = hd(items)
    assert {:text, "***Parse Error***"} in items
  end

  test "successful run returns stats" do
    assert interpret("pass", 0) == {:ok, %{distinct_states: 10, states_generated: 14}}
  end

  test "invariant violation with trace" do
    assert {:violation, v} = interpret("invariant", 12)
    assert v.kind == :invariant
    assert v.name == "Inv"
    assert v.message == "Invariant Inv is violated."

    assert v.trace == [
             %{index: 1, action: nil, state: %{"x" => 0}},
             %{index: 2, action: "Inc", state: %{"x" => 1}},
             %{index: 3, action: "Inc", state: %{"x" => 2}}
           ]
  end

  test "deadlock" do
    assert {:violation, %{kind: :deadlock, name: nil, trace: [_, %{action: "Next"}]}} =
             interpret("deadlock", 11)
  end

  test "liveness with wrapped values, loop and stuttering" do
    assert {:violation, v} = interpret("liveness", 13)
    assert v.kind == :liveness
    assert [s1, s2, loop, stutter] = v.trace
    assert s1.state["r"]["a"] == 1
    assert s1.state["x"] == 0
    assert s2.action == "Flip"
    assert loop == %{index: 1, back_to: 1}
    assert stutter == %{index: 3, stuttering: true}
  end

  test "assertion failure" do
    assert {:violation, %{kind: :assertion, message: message, trace: [_]}} = interpret("assert", 14)
    assert message =~ "x too big"
  end

  test "parse error reports SANY text and location" do
    assert {:error, %Notary.Error{kind: :spec_error} = e} = interpret("parse_error", 150)
    assert e.message =~ "Bad"
    assert e.details.output =~ "***Parse Error***"
    assert e.details.location == %{module: "Bad", line: 3, column: 9}
  end

  test "semantic error reports location" do
    assert {:error, %Notary.Error{kind: :spec_error} = e} = interpret("semantic_error", 150)
    assert e.details.output =~ "Unknown operator"
    assert e.details.location == %{module: "Sem", line: 3, column: 13}
  end

  test "unknown non-zero exit is a tlc_failed error with the output tail" do
    assert {:error, %Notary.Error{kind: :tlc_failed} = e} =
             Output.interpret(Output.items("Exception in thread main\n"), 1)

    assert e.details.output =~ "Exception"
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/tlc/output_test.exs`
Expected: FAIL, `Notary.TLC.Output.items/1 is undefined`.

- [ ] **Step 4: Implement `lib/notary/tlc/output.ex`**

```elixir
defmodule Notary.TLC.Output do
  @moduledoc "Parses TLC `-tool` mode output into messages and interprets them."

  alias Notary.{Error, StateGraph}

  @type message :: %{code: integer(), severity: integer(), body: String.t()}
  @type item :: {:message, message()} | {:text, String.t()}
  @type step ::
          %{index: pos_integer(), action: String.t() | nil, state: map()}
          | %{index: pos_integer(), stuttering: true}
          | %{index: pos_integer(), back_to: pos_integer()}
  @type violation :: %{
          kind: :invariant | :deadlock | :liveness | :assertion | :property,
          name: String.t() | nil,
          message: String.t(),
          trace: [step()]
        }
  @type stats :: %{distinct_states: non_neg_integer(), states_generated: non_neg_integer()}
  @type result :: {:ok, stats()} | {:violation, violation()} | {:error, Error.t()}

  @start ~r/^@!@!@STARTMSG (\d+):(\d+) @!@!@$/
  @finish ~r/^@!@!@ENDMSG \d+ @!@!@$/

  @violations %{
    2107 => :invariant,
    2110 => :invariant,
    2108 => :property,
    2112 => :property,
    2114 => :deadlock,
    2116 => :liveness,
    2132 => :assertion
  }

  @spec items(binary()) :: [item()]
  def items(output) do
    {items, current} =
      output
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], nil}, fn line, {items, current} ->
        cond do
          match = Regex.run(@start, line) ->
            [_, code, severity] = match
            current = %{code: String.to_integer(code), severity: String.to_integer(severity), lines: []}
            {items, current}

          current != nil and Regex.match?(@finish, line) ->
            {[{:message, finish(current)} | items], nil}

          current != nil ->
            {items, %{current | lines: [line | current.lines]}}

          true ->
            {[{:text, line} | items], nil}
        end
      end)

    items = if current, do: [{:message, finish(current)} | items], else: items
    Enum.reverse(items)
  end

  defp finish(%{code: code, severity: severity, lines: lines}) do
    %{code: code, severity: severity, body: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing()}
  end

  @spec interpret([item()], integer()) :: result()
  def interpret(items, exit_status) do
    messages = for {:message, message} <- items, do: message

    cond do
      exit_status == 150 or sany_error?(items) -> {:error, spec_error(items)}
      violation = violation(messages) -> {:violation, violation}
      exit_status == 0 -> {:ok, stats(messages)}
      true -> {:error, tlc_failed(items, exit_status)}
    end
  end

  defp sany_error?(items) do
    Enum.any?(items, fn
      {:text, text} -> text =~ "***Parse Error***" or text =~ "*** Errors:" or text =~ "Could not parse module"
      _ -> false
    end)
  end

  defp spec_error(items) do
    text =
      items
      |> Enum.flat_map(fn
        {:text, text} -> [text]
        _ -> []
      end)
      |> Enum.reject(&(&1 =~ ~r/^(Parsing file|Semantic processing of module)/))
      |> Enum.join("\n")
      |> String.trim()

    location = location(text)

    where =
      case location do
        %{module: m, line: l, column: c} -> " in #{m}.tla:#{l}:#{c}"
        nil -> ""
      end

    Error.new(:spec_error, "TLA+ spec error#{where}:\n#{text}", %{output: text, location: location})
  end

  defp location(text) do
    cond do
      match = Regex.run(~r/line (\d+), col (\d+) to line \d+, col \d+ of module (\w+)/, text) ->
        [_, line, col, module] = match
        %{module: module, line: String.to_integer(line), column: String.to_integer(col)}

      match = Regex.run(~r/at line (\d+), column (\d+)/, text) ->
        [_, line, col] = match
        module = with [_, m] <- Regex.run(~r/Could not parse module (\w+)/, text), do: m
        %{module: module, line: String.to_integer(line), column: String.to_integer(col)}

      true ->
        nil
    end
  end

  defp violation(messages) do
    case Enum.find(messages, &Map.has_key?(@violations, &1.code)) do
      nil ->
        nil

      message ->
        %{
          kind: Map.fetch!(@violations, message.code),
          name: violation_name(message.body),
          message: String.trim(message.body),
          trace: messages |> Enum.filter(&(&1.code in [2216, 2217, 2218, 2122])) |> Enum.map(&trace_step/1)
        }
    end
  end

  defp violation_name(body) do
    case Regex.run(~r/(?:Invariant|[Pp]roperty) (\S+) is violated/, body) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp trace_step(%{code: 2218, body: body}) do
    [_, index] = Regex.run(~r/^(\d+):/, body)
    %{index: String.to_integer(index), stuttering: true}
  end

  defp trace_step(%{code: 2122, body: body}) do
    [_, index] = Regex.run(~r/^(\d+):/, body)
    %{index: String.to_integer(index), back_to: String.to_integer(index)}
  end

  defp trace_step(%{body: body}) do
    {index, action, text} =
      case String.split(body, "\n", parts: 2) do
        [header, rest] ->
          case Regex.run(~r/^(\d+): <(.*)>$/, header) do
            [_, index, label] -> {String.to_integer(index), action_name(label), rest}
            nil -> {1, nil, body}
          end

        [only] ->
          {1, nil, only}
      end

    case StateGraph.parse_state(text) do
      {:ok, state} -> %{index: index, action: action, state: state}
      {:error, _} -> %{index: index, action: action, state: %{}, raw: text}
    end
  end

  defp action_name("Initial predicate"), do: nil
  defp action_name(label), do: label |> String.split(~r/[\s(]/, parts: 2) |> hd()

  defp stats(messages) do
    with %{body: body} <- Enum.find(messages, &(&1.code == 2199)),
         [_, generated, distinct] <-
           Regex.run(~r/([\d,]+) states generated, ([\d,]+) distinct states found/, body) do
      %{states_generated: to_int(generated), distinct_states: to_int(distinct)}
    else
      _ -> %{states_generated: 0, distinct_states: 0}
    end
  end

  defp to_int(text), do: text |> String.replace(",", "") |> String.to_integer()

  defp tlc_failed(items, exit_status) do
    tail =
      items
      |> Enum.map(fn
        {:text, text} -> text
        {:message, %{body: body}} -> body
      end)
      |> Enum.take(-40)
      |> Enum.join("\n")
      |> String.trim()

    Error.new(:tlc_failed, "TLC exited with status #{exit_status}:\n#{tail}", %{
      exit_status: exit_status,
      output: tail
    })
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/tlc/output_test.exs`
Expected: 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/notary/tlc/output.ex test/notary/tlc/output_test.exs test/fixtures/tlc_output
git commit -m "feat: interpret TLC tool-mode output"
```

---
### Task 5: `Notary.Spec` discovery and `Notary.Cache`

**Files:**
- Create: `lib/notary/spec.ex`, `lib/notary/cache.ex`
- Test: `test/notary/spec_test.exs`, `test/notary/cache_test.exs`

**Interfaces:**
- Consumes: `Notary.Config.specs_dir/0`, `work_dir/0`, `tla_version/0`; `Notary.Error.new/3`.
- Produces:
  - `%Notary.Spec{name, dir, tla_path, cfg_path}` (absolute paths).
  - `Spec.discover(dir \\ Config.specs_dir()) :: [Spec.t()]` returns every `X.tla` that has a sibling `X.cfg`, sorted by name.
  - `Spec.fetch(name, dir \\ ...) :: {:ok, t} | {:error, %Error{kind: :unknown_spec}}`.
  - `Spec.select(names :: [String.t()], dir) :: {:ok, [t]} | {:error, Error.t()}`, where `[]` means all specs.
  - `Spec.from_path(tla_path) :: t`.
  - `Spec.content_hash(t) :: hex` covers every `*.tla` in the spec's directory (for `EXTENDS`) plus its `.cfg`.
  - `Cache.key(Spec.t()) :: String.t()` is `"<Name>-<16 hex>"` and includes the content hash, TLA+ tools version and cache format.
  - `Cache.get(key) :: {:ok, term} | :miss` (corrupt files count as a miss).
  - `Cache.put(key, term) :: :ok` writes atomically and deletes older entries for the same spec name.
  - `Cache.path(key) :: String.t()`.

- [ ] **Step 1: Write the failing tests**

`test/notary/spec_test.exs`:
```elixir
defmodule Notary.SpecTest do
  use ExUnit.Case, async: true

  alias Notary.Spec

  @moduletag :tmp_dir

  defp write(dir, files), do: Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)

  test "discovers specs that have a .cfg, sorted", %{tmp_dir: dir} do
    write(dir, [{"B.tla", "b"}, {"B.cfg", ""}, {"A.tla", "a"}, {"A.cfg", ""}, {"Helper.tla", "h"}])
    assert [%Spec{name: "A"} = a, %Spec{name: "B"}] = Spec.discover(dir)
    assert a.tla_path == Path.join(dir, "A.tla")
    assert a.cfg_path == Path.join(dir, "A.cfg")
    assert a.dir == dir
  end

  test "fetch and select", %{tmp_dir: dir} do
    write(dir, [{"A.tla", "a"}, {"A.cfg", ""}, {"B.tla", "b"}, {"B.cfg", ""}])
    assert {:ok, %Spec{name: "A"}} = Spec.fetch("A", dir)
    assert {:error, %Notary.Error{kind: :unknown_spec}} = Spec.fetch("Nope", dir)
    assert {:ok, [_, _]} = Spec.select([], dir)
    assert {:ok, [%Spec{name: "B"}]} = Spec.select(["B"], dir)
    assert {:error, %Notary.Error{kind: :unknown_spec}} = Spec.select(["B", "Nope"], dir)
  end

  test "from_path derives the cfg", %{tmp_dir: dir} do
    spec = Spec.from_path(Path.join(dir, "Bank.tla"))
    assert spec.name == "Bank"
    assert spec.cfg_path == Path.join(dir, "Bank.cfg")
  end

  test "content hash changes with the spec, its cfg, or a sibling module", %{tmp_dir: dir} do
    write(dir, [{"A.tla", "a"}, {"A.cfg", "c"}, {"Helper.tla", "h"}])
    {:ok, spec} = Spec.fetch("A", dir)
    h1 = Spec.content_hash(spec)
    assert h1 == Spec.content_hash(spec)

    for {file, body} <- [{"A.cfg", "c2"}, {"Helper.tla", "h2"}, {"A.tla", "a2"}] do
      before = Spec.content_hash(spec)
      File.write!(Path.join(dir, file), body)
      refute Spec.content_hash(spec) == before
    end
  end
end
```

`test/notary/cache_test.exs`:
```elixir
defmodule Notary.CacheTest do
  use ExUnit.Case, async: false

  alias Notary.{Cache, Spec}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
    File.write!(Path.join(dir, "A.tla"), "a")
    File.write!(Path.join(dir, "A.cfg"), "c")
    {:ok, spec} = Spec.fetch("A", dir)
    %{spec: spec, dir: dir}
  end

  test "miss, put, hit", %{spec: spec} do
    key = Cache.key(spec)
    assert key =~ ~r/^A-[0-9a-f]{16}$/
    assert Cache.get(key) == :miss
    assert Cache.put(key, %{graph: :g}) == :ok
    assert Cache.get(key) == {:ok, %{graph: :g}}
  end

  test "key changes when the spec changes and old entries are removed", %{spec: spec, dir: dir} do
    old = Cache.key(spec)
    Cache.put(old, :old)
    File.write!(Path.join(dir, "A.tla"), "a changed")
    new = Cache.key(spec)
    refute new == old
    Cache.put(new, :new)
    assert Cache.get(old) == :miss
    assert Cache.get(new) == {:ok, :new}
  end

  test "corrupt entries are a miss", %{spec: spec} do
    key = Cache.key(spec)
    File.mkdir_p!(Path.dirname(Cache.path(key)))
    File.write!(Cache.path(key), "not a term")
    assert Cache.get(key) == :miss
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/spec_test.exs test/notary/cache_test.exs`
Expected: FAIL, `Notary.Spec.discover/1 is undefined`.

- [ ] **Step 3: Implement**

`lib/notary/spec.ex`:
```elixir
defmodule Notary.Spec do
  @moduledoc "A TLA+ spec: `Name.tla` with a sibling `Name.cfg` TLC model."

  alias Notary.{Config, Error}

  defstruct [:name, :dir, :tla_path, :cfg_path]

  @type t :: %__MODULE__{name: String.t(), dir: String.t(), tla_path: String.t(), cfg_path: String.t()}

  @spec discover(String.t()) :: [t()]
  def discover(dir \\ Config.specs_dir()) do
    dir
    |> Path.expand()
    |> Path.join("*.tla")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn tla ->
      cfg = Path.rootname(tla) <> ".cfg"
      if File.exists?(cfg), do: [new(tla, cfg)], else: []
    end)
  end

  @spec fetch(String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def fetch(name, dir \\ Config.specs_dir()) do
    case Enum.find(discover(dir), &(&1.name == name)) do
      nil ->
        {:error,
         Error.new(:unknown_spec, "No spec named #{name} in #{dir} (expected #{name}.tla and #{name}.cfg).")}

      spec ->
        {:ok, spec}
    end
  end

  @spec select([String.t()], String.t()) :: {:ok, [t()]} | {:error, Error.t()}
  def select([], dir), do: {:ok, discover(dir)}

  def select(names, dir) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case fetch(name, dir) do
        {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
        error -> {:halt, error}
      end
    end)
  end

  @spec from_path(String.t()) :: t()
  def from_path(tla_path) do
    tla = Path.expand(tla_path)
    new(tla, Path.rootname(tla) <> ".cfg")
  end

  @spec content_hash(t()) :: String.t()
  def content_hash(%__MODULE__{} = spec) do
    files = Enum.sort(Path.wildcard(Path.join(spec.dir, "*.tla"))) ++ [spec.cfg_path]

    files
    |> Enum.map(fn file -> [Path.basename(file), 0, File.read!(file), 0] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp new(tla, cfg) do
    %__MODULE__{name: Path.basename(tla, ".tla"), dir: Path.dirname(tla), tla_path: tla, cfg_path: cfg}
  end
end
```

`lib/notary/cache.ex`:
```elixir
defmodule Notary.Cache do
  @moduledoc """
  Caches parsed state graphs in the work dir, keyed by the spec's contents, the
  TLA+ tools version and the cache format. Only passing TLC runs are cached.
  """

  alias Notary.{Config, Spec}

  @format "1"

  @spec key(Spec.t()) :: String.t()
  def key(%Spec{} = spec) do
    digest =
      :crypto.hash(:sha256, [Spec.content_hash(spec), Config.tla_version(), @format])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{spec.name}-#{digest}"
  end

  @spec path(String.t()) :: String.t()
  def path(key), do: Path.join(Config.work_dir(), key <> ".graph")

  @spec get(String.t()) :: {:ok, term()} | :miss
  def get(key) do
    case File.read(path(key)) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _} -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(String.t(), term()) :: :ok
  def put(key, value) do
    target = path(key)
    File.mkdir_p!(Path.dirname(target))
    [name | _] = String.split(key, "-")

    for old <- Path.wildcard(Path.join(Path.dirname(target), "#{name}-*.graph")), old != target do
      File.rm(old)
    end

    tmp = target <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, :erlang.term_to_binary(value))
    File.rename!(tmp, target)
    :ok
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/spec_test.exs test/notary/cache_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/notary/spec.ex lib/notary/cache.ex test/notary/spec_test.exs test/notary/cache_test.exs
git commit -m "feat: discover specs and cache state graphs"
```

---

### Task 6: `Notary.Lock` — spec integrity lock file

**Files:**
- Create: `lib/notary/lock.ex`
- Test: `test/notary/lock_test.exs`

**Interfaces:**
- Consumes: `Notary.Config.specs_dir/0`, `Notary.Error.new/3`.
- Produces:
  - `Lock.path(dir) :: String.t()`, which is `<dir>/.notary.lock`.
  - `Lock.write(dir) :: {:ok, [file_name]}` records the sha256 of every `*.tla`/`*.cfg` in `dir`, as stable pretty JSON with sorted keys.
  - `Lock.changes(dir) :: [{:changed | :unlocked | :removed, file_name}]` (sorted).
  - `Lock.check(dir) :: :ok | {:error, %Error{kind: :spec_lock_mismatch, details: %{changes: [...]}}}`.

- [ ] **Step 1: Write the failing tests**

`test/notary/lock_test.exs`:
```elixir
defmodule Notary.LockTest do
  use ExUnit.Case, async: true

  alias Notary.Lock

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Bank.tla"), "spec")
    File.write!(Path.join(dir, "Bank.cfg"), "cfg")
    :ok
  end

  test "a directory with no lock file reports every spec file as unlocked", %{tmp_dir: dir} do
    assert Lock.changes(dir) == [{:unlocked, "Bank.cfg"}, {:unlocked, "Bank.tla"}]
    assert {:error, %Notary.Error{kind: :spec_lock_mismatch} = e} = Lock.check(dir)
    assert e.message =~ "mix notary.lock"
    assert e.message =~ "do not edit specs"
  end

  test "write then check passes, and the file is stable sorted JSON", %{tmp_dir: dir} do
    assert {:ok, ["Bank.cfg", "Bank.tla"]} = Lock.write(dir)
    assert Lock.check(dir) == :ok
    body = File.read!(Lock.path(dir))
    assert %{"version" => 1, "files" => %{"Bank.tla" => _, "Bank.cfg" => _}} = JSON.decode!(body)
    {:ok, _} = Lock.write(dir)
    assert File.read!(Lock.path(dir)) == body
  end

  test "detects changed, unlocked and removed files", %{tmp_dir: dir} do
    {:ok, _} = Lock.write(dir)
    File.write!(Path.join(dir, "Bank.tla"), "edited by someone")
    File.write!(Path.join(dir, "New.tla"), "new")
    File.rm!(Path.join(dir, "Bank.cfg"))

    assert Lock.changes(dir) == [{:changed, "Bank.tla"}, {:removed, "Bank.cfg"}, {:unlocked, "New.tla"}]
    assert {:error, %Notary.Error{details: %{changes: [_, _, _]}}} = Lock.check(dir)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/lock_test.exs`
Expected: FAIL, `Notary.Lock.changes/1 is undefined`.

- [ ] **Step 3: Implement `lib/notary/lock.ex`**

```elixir
defmodule Notary.Lock do
  @moduledoc """
  Records hashes of the human-authored spec files in `specs/.notary.lock`.
  `mix notary.verify` fails when a spec changed since the human last ran
  `mix notary.lock`, which makes unreviewed spec edits (e.g. by an LLM) visible.
  """

  alias Notary.{Config, Error}

  @file_name ".notary.lock"

  @type change :: {:changed | :unlocked | :removed, String.t()}

  @spec path(String.t()) :: String.t()
  def path(dir \\ Config.specs_dir()), do: Path.join(dir, @file_name)

  @spec write(String.t()) :: {:ok, [String.t()]}
  def write(dir \\ Config.specs_dir()) do
    hashes = current(dir) |> Enum.sort()

    entries = Enum.map_join(hashes, ",\n", fn {file, hash} -> "    #{JSON.encode!(file)}: #{JSON.encode!(hash)}" end)
    File.write!(path(dir), "{\n  \"version\": 1,\n  \"files\": {\n#{entries}\n  }\n}\n")
    {:ok, Enum.map(hashes, &elem(&1, 0))}
  end

  @spec changes(String.t()) :: [change()]
  def changes(dir \\ Config.specs_dir()) do
    locked = read(dir)
    current = current(dir)

    changed = for {f, h} <- current, Map.has_key?(locked, f), locked[f] != h, do: {:changed, f}
    unlocked = for {f, _} <- current, not Map.has_key?(locked, f), do: {:unlocked, f}
    removed = for {f, _} <- locked, not Map.has_key?(current, f), do: {:removed, f}
    Enum.sort(changed ++ unlocked ++ removed)
  end

  @spec check(String.t()) :: :ok | {:error, Error.t()}
  def check(dir \\ Config.specs_dir()) do
    case changes(dir) do
      [] -> :ok
      changes -> {:error, Error.new(:spec_lock_mismatch, message(changes), %{changes: changes})}
    end
  end

  defp message(changes) do
    lines = Enum.map_join(changes, "\n", fn {kind, file} -> "  #{kind}: #{file}" end)

    """
    Spec files differ from specs/.notary.lock:
    #{lines}
    Specs are human-authored. If you are an LLM agent: do not edit specs; revert the change and ask the human.
    If you are the human and the change is intentional, run `mix notary.lock`.\
    """
  end

  defp current(dir) do
    for file <- Path.wildcard(Path.join(dir, "*.{tla,cfg}")), into: %{} do
      {Path.basename(file), file |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    end
  end

  defp read(dir) do
    case File.read(path(dir)) do
      {:ok, body} -> body |> JSON.decode!() |> Map.fetch!("files")
      {:error, :enoent} -> %{}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/lock_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/notary/lock.ex test/notary/lock_test.exs
git commit -m "feat: spec integrity lock file"
```

---

### Task 7: Tools, TLC runner and `Notary.TLC`, plus fixture specs

**Files:**
- Create: `lib/notary/tools.ex`, `lib/notary/tools/tlc_runner.ex`, `lib/notary/tlc.ex`
- Create fixture specs: `test/fixtures/specs/{Counter,Bank,Workflow}.{tla,cfg}`, `test/fixtures/specs_bad/{Broken,Inv}.{tla,cfg}`
- Test: `test/notary/tools_test.exs`, `test/notary/tlc_test.exs`

**Interfaces:**
- Consumes: `Notary.Config`, `Notary.Error`, `Notary.Spec`, `Notary.Cache`, `Notary.StateGraph.parse_dot/1`, `Notary.TLC.Output.items/1` and `interpret/2`.
- Produces:
  - `Tools.find_java() :: {:ok, path} | {:error, %Error{kind: :java_not_found | :java_too_old}}`
  - `Tools.find_jar() :: {:ok, path} | {:error, %Error{kind: :jar_not_found}}`
  - `Tools.ensure_ready() :: {:ok, %{java: path, jar: path}} | {:error, Error.t()}`
  - `Tools.install(opts) :: {:ok, path} | {:error, %Error{kind: :download_failed | :checksum_mismatch}}`, with opts `:force`, `:url`, `:sha256`.
  - `Tools.java_major_version(output) :: integer | nil`
  - `Tools.sha256_file(path) :: hex`
  - `TLCRunner.run(tlc_args, java:, jar:, timeout:, max_states:, cd:) :: {:ok, %{exit_status, output}} | {:error, %Error{kind: :tlc_timeout | :too_many_states}}`
  - `TLCRunner.distinct_states(line) :: integer | nil`
  - `TLC.check(Spec.t, opts) :: Output.result`
  - `TLC.dump(Spec.t, dot_path, opts) :: Output.result`, which also writes the DOT file on success.
  - `TLC.graph(Spec.t, opts) :: {:ok, StateGraph.t, stats} | {:violation, v} | {:error, Error.t}`, cached via `Notary.Cache`, with opt `force: true` to bypass the cache.
  - Common opts: `:timeout`, `:max_states`.

- [ ] **Step 1: Write the fixture specs**

`test/fixtures/specs/Counter.tla`:
```tla
---- MODULE Counter ----
EXTENDS Naturals
CONSTANT Max
VARIABLE x

TypeOK == x \in 0..Max

Init == x = 0

Inc == /\ x < Max
       /\ x' = x + 1

Reset == x' = 0

Next == Inc \/ Reset

Spec == Init /\ [][Next]_x
====
```
`test/fixtures/specs/Counter.cfg`:
```
CONSTANT Max = 3
INIT Init
NEXT Next
INVARIANT TypeOK
```

`test/fixtures/specs/Bank.tla` (`lastOp` is a hidden variable the mapping does not observe):
```tla
---- MODULE Bank ----
EXTENDS Naturals
CONSTANT MaxBal
VARIABLES balance, lastOp

TypeOK == /\ balance \in 0..MaxBal
          /\ lastOp \in {"none", "deposit", "withdraw"}

Init == balance = 0 /\ lastOp = "none"

Deposit(a) == /\ balance + a <= MaxBal
              /\ balance' = balance + a
              /\ lastOp' = "deposit"

Withdraw(a) == /\ a <= balance
               /\ balance' = balance - a
               /\ lastOp' = "withdraw"

Next == \E a \in 1..2 : Deposit(a) \/ Withdraw(a)

Spec == Init /\ [][Next]_<<balance, lastOp>>
====
```
`test/fixtures/specs/Bank.cfg`:
```
CONSTANT MaxBal = 3
INIT Init
NEXT Next
INVARIANT TypeOK
```

`test/fixtures/specs/Workflow.tla` (two actors, plus an external payment gateway modeled as actions):
```tla
---- MODULE Workflow ----
CONSTANT Users
VARIABLES status, gateway

TypeOK == /\ status \in [Users -> {"cart", "paid", "shipped"}]
          /\ gateway \in {"up", "down"}

Init == /\ status = [u \in Users |-> "cart"]
        /\ gateway = "up"

Pay(u) == /\ status[u] = "cart"
          /\ gateway = "up"
          /\ status' = [status EXCEPT ![u] = "paid"]
          /\ UNCHANGED gateway

Ship(u) == /\ status[u] = "paid"
           /\ status' = [status EXCEPT ![u] = "shipped"]
           /\ UNCHANGED gateway

GatewayDown == /\ gateway = "up"
               /\ gateway' = "down"
               /\ UNCHANGED status

GatewayUp == /\ gateway = "down"
             /\ gateway' = "up"
             /\ UNCHANGED status

Next == \/ \E u \in Users : Pay(u) \/ Ship(u)
        \/ GatewayDown
        \/ GatewayUp

Spec == Init /\ [][Next]_<<status, gateway>>
====
```
`test/fixtures/specs/Workflow.cfg`:
```
CONSTANT Users = {u1, u2}
INIT Init
NEXT Next
INVARIANT TypeOK
```

`test/fixtures/specs_bad/Inv.tla`:
```tla
---- MODULE Inv ----
EXTENDS Naturals
VARIABLE x
Small == x < 2
Init == x = 0
Next == x' = x + 1
====
```
`test/fixtures/specs_bad/Inv.cfg`:
```
INIT Init
NEXT Next
INVARIANT Small
```
`test/fixtures/specs_bad/Broken.tla`:
```tla
---- MODULE Broken ----
VARIABLE x
Init == x =
Next == x' = x
====
```
`test/fixtures/specs_bad/Broken.cfg`:
```
INIT Init
NEXT Next
```

- [ ] **Step 2: Write the failing tests**

`test/notary/tools_test.exs`:
```elixir
defmodule Notary.ToolsTest do
  use ExUnit.Case, async: false

  alias Notary.Tools

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      Application.delete_env(:notary, :tla2tools_path)
      Application.delete_env(:notary, :java)
    end)
  end

  test "parses java version banners" do
    assert Tools.java_major_version(~s(openjdk version "21.0.12.1" 2026-08-18)) == 21
    assert Tools.java_major_version(~s(java version "1.8.0_382")) == 8
    assert Tools.java_major_version(~s(openjdk version "11.0.2" 2019-01-15)) == 11
    assert Tools.java_major_version("garbage") == nil
  end

  test "missing java is an actionable error" do
    Application.put_env(:notary, :java, "definitely-not-java-xyz")
    assert {:error, %Notary.Error{kind: :java_not_found, message: msg}} = Tools.find_java()
    assert msg =~ "nix"
  end

  test "missing jar points at mix notary.install", %{tmp_dir: dir} do
    Application.put_env(:notary, :tla2tools_path, Path.join(dir, "missing.jar"))
    assert {:error, %Notary.Error{kind: :jar_not_found, message: msg}} = Tools.find_jar()
    assert msg =~ "mix notary.install"
  end

  test "install is a no-op when the jar already matches the checksum", %{tmp_dir: dir} do
    jar = Path.join(dir, "tla2tools.jar")
    File.write!(jar, "pretend jar")
    Application.put_env(:notary, :tla2tools_path, jar)
    sha = Tools.sha256_file(jar)
    assert Tools.install(sha256: sha, url: "https://invalid.example/never-fetched") == {:ok, jar}
  end

  @tag :network
  test "downloads and verifies the pinned jar", %{tmp_dir: dir} do
    Application.put_env(:notary, :tla2tools_path, Path.join(dir, "tla2tools.jar"))
    assert {:ok, path} = Tools.install()
    assert Tools.sha256_file(path) == Notary.Config.jar_sha256()
  end

  @tag :network
  test "a checksum mismatch is rejected and nothing is written", %{tmp_dir: dir} do
    jar = Path.join(dir, "tla2tools.jar")
    Application.put_env(:notary, :tla2tools_path, jar)
    assert {:error, %Notary.Error{kind: :checksum_mismatch}} = Tools.install(sha256: String.duplicate("0", 64))
    refute File.exists?(jar)
  end
end
```

`test/notary/tlc_test.exs`:
```elixir
defmodule Notary.TLCTest do
  use ExUnit.Case, async: false

  alias Notary.{Cache, Spec, StateGraph, TLC}
  alias Notary.Tools.TLCRunner

  test "distinct_states/1 reads progress and final stats lines" do
    assert TLCRunner.distinct_states("14 states generated, 10 distinct states found, 0 states left") == 10
    assert TLCRunner.distinct_states("Progress(4): 2,000 states generated (1 s/min), 1,234 distinct states found") == 1234
    assert TLCRunner.distinct_states("Finished computing initial states: 1 distinct state generated") == nil
  end

  describe "with TLC" do
    @describetag :tlc
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
      on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
    end

    test "check passes for a correct spec" do
      {:ok, spec} = Spec.fetch("Counter", "test/fixtures/specs")
      assert {:ok, %{distinct_states: 4}} = TLC.check(spec)
    end

    test "check reports invariant violations with a trace" do
      {:ok, spec} = Spec.fetch("Inv", "test/fixtures/specs_bad")
      assert {:violation, %{kind: :invariant, name: "Small", trace: trace}} = TLC.check(spec)
      assert List.last(trace).state == %{"x" => 2}
    end

    test "check reports spec errors with location" do
      {:ok, spec} = Spec.fetch("Broken", "test/fixtures/specs_bad")
      assert {:error, %Notary.Error{kind: :spec_error, details: %{location: %{line: 3}}}} = TLC.check(spec)
    end

    test "two runs in the same second do not collide" do
      {:ok, spec} = Spec.fetch("Counter", "test/fixtures/specs")
      tasks = for _ <- 1..2, do: Task.async(fn -> TLC.check(spec) end)
      assert [{:ok, _}, {:ok, _}] = Task.await_many(tasks, 60_000)
    end

    test "state limit stops TLC" do
      {:ok, spec} = Spec.fetch("Bank", "test/fixtures/specs")
      assert {:error, %Notary.Error{kind: :too_many_states}} = TLC.check(spec, max_states: 2)
    end

    test "timeout stops TLC" do
      {:ok, spec} = Spec.fetch("Bank", "test/fixtures/specs")
      assert {:error, %Notary.Error{kind: :tlc_timeout}} = TLC.check(spec, timeout: 1)
    end

    test "graph builds, caches and reuses the state graph" do
      {:ok, spec} = Spec.fetch("Workflow", "test/fixtures/specs")
      assert {:ok, graph, %{distinct_states: n}} = TLC.graph(spec)
      assert StateGraph.size(graph) == n
      assert graph.actions == MapSet.new(["Pay", "Ship", "GatewayDown", "GatewayUp"])
      assert {:ok, _} = Cache.get(Cache.key(spec))
      assert {:ok, ^graph, _} = TLC.graph(spec)
    end

    test "graph does not cache failing specs" do
      {:ok, spec} = Spec.fetch("Inv", "test/fixtures/specs_bad")
      assert {:violation, _} = TLC.graph(spec)
      assert Cache.get(Cache.key(spec)) == :miss
    end
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/tools_test.exs test/notary/tlc_test.exs --include tlc`
Expected: FAIL, `Notary.Tools.java_major_version/1 is undefined`. The `:tlc` tests can't pass until the jar exists, which Step 5 installs.

- [ ] **Step 4: Implement**

`lib/notary/tools.ex`:
```elixir
defmodule Notary.Tools do
  @moduledoc "Locates, installs and validates Java and the pinned TLA+ tools jar."

  alias Notary.{Config, Error}

  @spec ensure_ready() :: {:ok, %{java: String.t(), jar: String.t()}} | {:error, Error.t()}
  def ensure_ready do
    with {:ok, java} <- find_java(), {:ok, jar} <- find_jar(), do: {:ok, %{java: java, jar: jar}}
  end

  @spec find_java() :: {:ok, String.t()} | {:error, Error.t()}
  def find_java do
    java = Config.get(:java)

    case System.find_executable(java) do
      nil ->
        {:error,
         Error.new(
           :java_not_found,
           "Java was not found (looked for #{inspect(java)}). Install a JDK >= 11 " <>
             "(the Notary nix flake provides one: `nix develop`) or set `config :notary, java: \"/path/to/java\"`."
         )}

      path ->
        {output, _} = System.cmd(path, ["-version"], stderr_to_stdout: true)

        case java_major_version(output) do
          version when is_integer(version) and version >= 11 ->
            {:ok, path}

          version ->
            {:error, Error.new(:java_too_old, "TLC needs Java >= 11, found #{inspect(version)} at #{path}.")}
        end
    end
  end

  @spec find_jar() :: {:ok, String.t()} | {:error, Error.t()}
  def find_jar do
    jar = Config.jar_path()

    if File.exists?(jar),
      do: {:ok, jar},
      else: {:error, Error.new(:jar_not_found, "tla2tools.jar not found at #{jar}. Run `mix notary.install`.")}
  end

  @spec install(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def install(opts \\ []) do
    dest = Config.jar_path()
    sha = Keyword.get(opts, :sha256, Config.jar_sha256())
    url = Keyword.get(opts, :url, Config.jar_url())

    if File.exists?(dest) and sha256_file(dest) == sha and not Keyword.get(opts, :force, false) do
      {:ok, dest}
    else
      with {:ok, body} <- download(url), :ok <- verify(body, sha) do
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, body)
        {:ok, dest}
      end
    end
  end

  @spec java_major_version(String.t()) :: integer() | nil
  def java_major_version(output) do
    case Regex.run(~r/version "(\d+)(?:\.(\d+))?/, output) do
      [_, "1", minor] -> String.to_integer(minor)
      [_, major | _] -> String.to_integer(major)
      nil -> nil
    end
  end

  @spec sha256_file(String.t()) :: String.t()
  def sha256_file(path), do: path |> File.read!() |> sha256()

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp verify(body, expected) do
    case sha256(body) do
      ^expected -> :ok
      actual -> {:error, Error.new(:checksum_mismatch, "Checksum mismatch for tla2tools.jar: expected #{expected}, got #{actual}.")}
    end
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [ssl: ssl, autoredirect: true, timeout: 120_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, Error.new(:download_failed, "Downloading #{url} failed with HTTP #{status}.")}

      {:error, reason} ->
        {:error, Error.new(:download_failed, "Downloading #{url} failed: #{inspect(reason)}")}
    end
  end
end
```

`lib/notary/tools/tlc_runner.ex`:
```elixir
defmodule Notary.Tools.TLCRunner do
  @moduledoc """
  Runs TLC as an OS process through a port. Enforces a wall-clock timeout and a
  distinct-state limit (read from TLC's progress and final stats lines); either
  one kills the OS process.
  """

  alias Notary.Error

  @type result :: %{exit_status: non_neg_integer(), output: String.t()}

  @spec run([String.t()], keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(tlc_args, opts) do
    java = Keyword.fetch!(opts, :java)
    jar = Keyword.fetch!(opts, :jar)
    timeout = Keyword.fetch!(opts, :timeout)
    max_states = Keyword.fetch!(opts, :max_states)
    cd = Keyword.get(opts, :cd, File.cwd!())

    port =
      Port.open({:spawn_executable, java}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:line, 65_536},
        {:cd, cd},
        {:args, ["-XX:+UseParallelGC", "-cp", jar, "tlc2.TLC" | tlc_args]}
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    loop(port, %{lines: [], partial: "", deadline: deadline, timeout: timeout, max_states: max_states})
  end

  defp loop(port, st) do
    remaining = max(st.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        loop(port, %{st | partial: st.partial <> chunk})

      {^port, {:data, {:eol, chunk}}} ->
        line = st.partial <> chunk
        st = %{st | lines: [line | st.lines], partial: ""}

        case distinct_states(line) do
          n when is_integer(n) and n > st.max_states ->
            kill(port)

            {:error,
             Error.new(
               :too_many_states,
               "TLC found more than #{st.max_states} distinct states (#{n} so far) and was stopped. " <>
                 "Use smaller CONSTANTS in the .cfg, or raise `config :notary, max_states: ...`.",
               %{distinct_states: n}
             )}

          _ ->
            loop(port, st)
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{exit_status: status, output: output(st)}}
    after
      remaining ->
        kill(port)

        {:error,
         Error.new(:tlc_timeout, "TLC did not finish within #{st.timeout}ms and was stopped.", %{
           output_tail: st.lines |> Enum.take(20) |> Enum.reverse() |> Enum.join("\n")
         })}
    end
  end

  @spec distinct_states(String.t()) :: non_neg_integer() | nil
  def distinct_states(line) do
    case Regex.run(~r/([\d,]+) distinct states found/, line) do
      [_, n] -> n |> String.replace(",", "") |> String.to_integer()
      nil -> nil
    end
  end

  defp output(st), do: Enum.reverse([st.partial | st.lines]) |> Enum.join("\n")

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    Port.close(port)
    flush(port)
  catch
    _, _ -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
```

`lib/notary/tlc.ex`:
```elixir
defmodule Notary.TLC do
  @moduledoc "Runs TLC for a spec: model checking, DOT dumps, and the cached state graph."

  alias Notary.{Cache, Config, Error, Spec, StateGraph, Tools}
  alias Notary.TLC.Output
  alias Notary.Tools.TLCRunner

  @spec check(Spec.t(), keyword()) :: Output.result()
  def check(%Spec{} = spec, opts \\ []), do: run_tlc(spec, nil, opts)

  @spec dump(Spec.t(), String.t(), keyword()) :: Output.result()
  def dump(%Spec{} = spec, dot_path, opts \\ []), do: run_tlc(spec, Path.expand(dot_path), opts)

  @spec graph(Spec.t(), keyword()) ::
          {:ok, StateGraph.t(), Output.stats()} | {:violation, Output.violation()} | {:error, Error.t()}
  def graph(%Spec{} = spec, opts \\ []) do
    key = Cache.key(spec)

    cached = if Keyword.get(opts, :force, false), do: :miss, else: Cache.get(key)

    case cached do
      {:ok, %{graph: graph, stats: stats}} -> {:ok, graph, stats}
      _ -> build_graph(spec, key, opts)
    end
  end

  defp build_graph(spec, key, opts) do
    dot = Path.join([Config.work_dir(), "tmp", "#{spec.name}-#{System.unique_integer([:positive])}.dot"])
    File.mkdir_p!(Path.dirname(dot))

    try do
      with {:ok, stats} <- dump(spec, dot, opts),
           {:ok, graph} <- dot |> File.read!() |> StateGraph.parse_dot() do
        :ok = Cache.put(key, %{graph: graph, stats: stats})
        {:ok, graph, stats}
      end
    after
      File.rm(dot)
    end
  end

  defp run_tlc(spec, dot_path, opts) do
    with {:ok, tools} <- Tools.ensure_ready() do
      metadir = Path.join([Config.work_dir(), "tmp", "meta-#{spec.name}-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(metadir)

      args =
        ["-tool", "-workers", to_string(Config.get(:tlc_workers)), "-metadir", metadir] ++
          ["-config", Path.basename(spec.cfg_path)] ++
          dump_args(dot_path) ++ [Path.basename(spec.tla_path)]

      runner_opts = [
        java: tools.java,
        jar: tools.jar,
        cd: spec.dir,
        timeout: Keyword.get(opts, :timeout, Config.get(:tlc_timeout)),
        max_states: Keyword.get(opts, :max_states, Config.get(:max_states))
      ]

      try do
        case TLCRunner.run(args, runner_opts) do
          {:ok, %{exit_status: status, output: output}} -> output |> Output.items() |> Output.interpret(status)
          {:error, _} = error -> error
        end
      after
        File.rm_rf(metadir)
      end
    end
  end

  defp dump_args(nil), do: []
  defp dump_args(path), do: ["-dump", "dot,actionlabels", path]
end
```

- [ ] **Step 5: Install the jar and run the tests**

`mix notary.install` arrives in Task 12, so install the jar with `mix run`:
```bash
nix develop -c mix run -e 'IO.inspect(Notary.Tools.install())'
nix develop -c mix test test/notary/tools_test.exs test/notary/tlc_test.exs --include tlc --include network
```
Expected: `{:ok, ".../_build/notary/tla2tools.jar"}`, then all tests pass. If the `max_states: 2` test returns `{:ok, _}`, the runner isn't seeing the 2199 line. Check that the line regex matches `"N distinct states found"` exactly as in the Verified TLC facts.

- [ ] **Step 6: Commit**

```bash
git add lib/notary/tools.ex lib/notary/tools lib/notary/tlc.ex test/notary/tools_test.exs test/notary/tlc_test.exs test/fixtures/specs test/fixtures/specs_bad
git commit -m "feat: run TLC via port with timeout, state limit and graph cache"
```

---

### Task 8: Fixture implementations, committed graphs, and the `Notary.Conformance` contract

**Files:**
- Create: `lib/notary/conformance.ex`, `lib/notary/conformance/step.ex`, `lib/notary/conformance/failure.ex`
- Create: `test/fixtures/regen_graphs.exs`, `test/fixtures/graphs/{Counter,Bank,Workflow}.dot` (generated)
- Create: `test/support/fixtures.ex`, `test/support/fixtures/counter.ex`, `test/support/fixtures/bank.ex`, `test/support/fixtures/orders.ex`, `test/support/fixtures/counter_specs.ex`, `test/support/fixtures/bank_specs.ex`, `test/support/fixtures/workflow_specs.ex`
- Test: `test/notary/conformance_test.exs`, `test/notary/fixture_graphs_test.exs`

**Interfaces:**
- Consumes: `Notary.StateGraph`, `Notary.Spec.from_path/1`, `Notary.TLC.dump/3` and `graph/2`, `Notary.Error`.
- Produces:
  - Behaviour `Notary.Conformance` with callbacks `init/0 :: {:ok, ctx}`, `actions/0 :: %{String.t() => StreamData.t(map)}`, `action/3 :: {:ok, ctx} | {:rejected, reason, ctx}`, `project/1 :: %{String.t() => Value.t()}`, and optional `teardown/1`.
  - `use Notary.Conformance, spec: path, observe: [vars] | nil, discover: boolean \\ true` defines `__notary__/0 :: %{spec_path: String.t(), observe: [String.t()] | nil, discover: boolean}` and imports `Notary.Value.model/1` and `set/1`.
  - `Notary.Conformance.spec(module) :: Spec.t()`.
  - `Notary.Conformance.observed_vars(module, graph) :: [String.t()]`.
  - `Notary.Conformance.validate(module, graph) :: :ok | {:error, %Error{kind: :invalid_mapping}}`.
  - `Notary.Conformance.discover_mappings(app :: atom) :: %{spec_name => module}` skips `discover: false` modules.
  - `%Notary.Conformance.Step{index, action, params, outcome :: :ok | {:rejected, term}, projection, candidates :: [state_id], allowed :: [projection]}`.
  - `%Notary.Conformance.Failure{kind, seed, steps :: [Step.t], details :: map}` with `Failure.new(kind, steps, details)` and `Failure.explanation(kind) :: String.t()`.
  - Test helper: `Notary.Fixtures.graph(name) :: StateGraph.t()` (parses the committed DOT file).

- [ ] **Step 1: Write the regen script and generate the committed graphs**

`test/fixtures/regen_graphs.exs`:
```elixir
# Regenerates test/fixtures/graphs/*.dot from test/fixtures/specs with TLC.
# Run: nix develop -c mix run test/fixtures/regen_graphs.exs
for name <- ~w(Counter Bank Workflow) do
  {:ok, spec} = Notary.Spec.fetch(name, "test/fixtures/specs")
  dest = Path.expand("test/fixtures/graphs/#{name}.dot")
  File.mkdir_p!(Path.dirname(dest))
  {:ok, stats} = Notary.TLC.dump(spec, dest)
  IO.puts("#{name}: #{stats.distinct_states} states -> #{dest}")
end
```
Run: `nix develop -c mix run test/fixtures/regen_graphs.exs`
Expected: `Counter: 4 states`, `Bank: 7 states`, `Workflow: 18 states`, each with a path.

- [ ] **Step 2: Write fixture implementations and mapping modules**

`test/support/fixtures.ex`:
```elixir
defmodule Notary.Fixtures do
  @moduledoc false
  def graph(name) do
    {:ok, graph} = "test/fixtures/graphs/#{name}.dot" |> File.read!() |> Notary.StateGraph.parse_dot()
    graph
  end
end
```

`test/support/fixtures/counter.ex`:
```elixir
defmodule Notary.Fixtures.Counter do
  @moduledoc false
  use Agent

  def start_link(max), do: Agent.start_link(fn -> %{x: 0, max: max} end)

  def inc(pid) do
    Agent.get_and_update(pid, fn
      %{x: x, max: max} = s when x < max -> {:ok, %{s | x: x + 1}}
      s -> {{:error, :at_max}, s}
    end)
  end

  def reset(pid), do: Agent.update(pid, &%{&1 | x: 0})
  def value(pid), do: Agent.get(pid, & &1.x)
end
```

`test/support/fixtures/counter_specs.ex` (one correct mapping plus deliberately buggy ones; the buggy ones use `discover: false`):
```elixir
defmodule Notary.Fixtures.CounterSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla"
  alias Notary.Fixtures.Counter

  @impl true
  def init, do: Counter.start_link(3)

  @impl true
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Reset" => StreamData.constant(%{})}

  @impl true
  def action("Inc", _, pid) do
    case Counter.inc(pid) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:rejected, reason, pid}
    end
  end

  def action("Reset", _, pid) do
    Counter.reset(pid)
    {:ok, pid}
  end

  @impl true
  def project(pid), do: %{"x" => Counter.value(pid)}

  @impl true
  def teardown(pid), do: Agent.stop(pid)
end

defmodule Notary.Fixtures.CounterNoGuardSpec do
  @moduledoc false
  # Bug: Inc ignores the Max guard.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid) do
    Agent.update(pid, &(&1 + 1))
    {:ok, pid}
  end
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadResetSpec do
  @moduledoc false
  # Bug: Reset goes to 1 instead of 0.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Reset" => StreamData.constant(%{})}
  def action("Reset", _, pid) do
    Agent.update(pid, fn _ -> 1 end)
    {:ok, pid}
  end
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterSideEffectSpec do
  @moduledoc false
  # Bug: a rejected Inc still changes state.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    if Agent.get(pid, & &1) < 3 do
      Agent.update(pid, &(&1 + 1))
      {:ok, pid}
    else
      Agent.update(pid, fn _ -> 0 end)
      {:rejected, :at_max, pid}
    end
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadInitSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 7 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadProjectionSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(_pid), do: %{"x" => 0, "extra" => 1}
end

defmodule Notary.Fixtures.CounterRaisingSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, _pid), do: raise("boom")
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterSlowSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid) do
    Process.sleep(1_000)
    {:ok, pid}
  end
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterUnknownActionSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", observe: ["x", "nope"], discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Decrement" => StreamData.constant(%{})}
  def action(_, _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end
```
`test/support/fixtures/bank.ex`:
```elixir
defmodule Notary.Fixtures.Bank do
  @moduledoc false
  use Agent

  def start_link(opts) do
    Agent.start_link(fn -> %{balance: 0, max: opts[:max], allow_overdraft: Keyword.get(opts, :allow_overdraft, false)} end)
  end

  def deposit(pid, amount) do
    Agent.get_and_update(pid, fn
      %{balance: b, max: max} = s when b + amount <= max -> {:ok, %{s | balance: b + amount}}
      s -> {{:error, :over_limit}, s}
    end)
  end

  def withdraw(pid, amount) do
    Agent.get_and_update(pid, fn
      %{balance: b, allow_overdraft: o} = s when amount <= b or o -> {:ok, %{s | balance: b - amount}}
      s -> {{:error, :insufficient_funds}, s}
    end)
  end

  def balance(pid), do: Agent.get(pid, & &1.balance)
end
```

`test/support/fixtures/bank_specs.ex`:
```elixir
defmodule Notary.Fixtures.BankSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Bank.tla", observe: ["balance"]
  alias Notary.Fixtures.Bank

  @impl true
  def init, do: Bank.start_link(max: 3)

  @impl true
  def actions do
    amount = StreamData.fixed_map(%{a: StreamData.integer(1..2)})
    %{"Deposit" => amount, "Withdraw" => amount}
  end

  @impl true
  def action("Deposit", %{a: a}, pid), do: reply(Bank.deposit(pid, a), pid)
  def action("Withdraw", %{a: a}, pid), do: reply(Bank.withdraw(pid, a), pid)

  @impl true
  def project(pid), do: %{"balance" => Bank.balance(pid)}

  defp reply(:ok, pid), do: {:ok, pid}
  defp reply({:error, reason}, pid), do: {:rejected, reason, pid}
end

defmodule Notary.Fixtures.BankOverdraftSpec do
  @moduledoc false
  # Bug: overdrafts allowed.
  use Notary.Conformance, spec: "test/fixtures/specs/Bank.tla", observe: ["balance"], discover: false
  alias Notary.Fixtures.Bank

  def init, do: Bank.start_link(max: 3, allow_overdraft: true)
  defdelegate actions(), to: Notary.Fixtures.BankSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.BankSpec
  defdelegate project(pid), to: Notary.Fixtures.BankSpec
end
```

`test/support/fixtures/orders.ex`:
```elixir
defmodule Notary.Fixtures.FakeGateway do
  @moduledoc false
  use Agent
  def start_link, do: Agent.start_link(fn -> :up end)
  def set(pid, status), do: Agent.update(pid, fn _ -> status end)
  def status(pid), do: Agent.get(pid, & &1)
  def charge(pid), do: if(status(pid) == :up, do: :ok, else: {:error, :gateway_down})
end

defmodule Notary.Fixtures.Orders do
  @moduledoc false
  use GenServer
  alias Notary.Fixtures.FakeGateway

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def pay(pid, user), do: GenServer.call(pid, {:pay, user})
  def ship(pid, user), do: GenServer.call(pid, {:ship, user})
  def statuses(pid), do: GenServer.call(pid, :statuses)

  @impl true
  def init(opts) do
    {:ok,
     %{
       orders: Map.new(Keyword.fetch!(opts, :users), &{&1, :cart}),
       gateway: Keyword.fetch!(opts, :gateway),
       check_gateway: Keyword.get(opts, :check_gateway, true)
     }}
  end

  @impl true
  def handle_call({:pay, user}, _from, s) do
    cond do
      s.orders[user] != :cart -> {:reply, {:error, :not_in_cart}, s}
      s.check_gateway and FakeGateway.charge(s.gateway) != :ok -> {:reply, {:error, :declined}, s}
      true -> {:reply, :ok, put_in(s.orders[user], :paid)}
    end
  end

  def handle_call({:ship, user}, _from, s) do
    if s.orders[user] == :paid,
      do: {:reply, :ok, put_in(s.orders[user], :shipped)},
      else: {:reply, {:error, :not_paid}, s}
  end

  def handle_call(:statuses, _from, s), do: {:reply, s.orders, s}
end
```

`test/support/fixtures/workflow_specs.ex`:
```elixir
defmodule Notary.Fixtures.WorkflowSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Workflow.tla"
  alias Notary.Fixtures.{FakeGateway, Orders}

  @users ["u1", "u2"]

  @impl true
  def init do
    {:ok, gateway} = FakeGateway.start_link()
    {:ok, orders} = Orders.start_link(users: @users, gateway: gateway)
    {:ok, %{orders: orders, gateway: gateway}}
  end

  @impl true
  def actions do
    user = StreamData.fixed_map(%{u: StreamData.member_of(@users)})
    none = StreamData.constant(%{})
    %{"Pay" => user, "Ship" => user, "GatewayDown" => none, "GatewayUp" => none}
  end

  @impl true
  def action("Pay", %{u: u}, ctx), do: reply(Orders.pay(ctx.orders, u), ctx)
  def action("Ship", %{u: u}, ctx), do: reply(Orders.ship(ctx.orders, u), ctx)
  # External effects: the mapping drives the fake gateway.
  def action("GatewayDown", _, ctx), do: flip(ctx, :up, :down)
  def action("GatewayUp", _, ctx), do: flip(ctx, :down, :up)

  @impl true
  def project(ctx) do
    status = Map.new(Orders.statuses(ctx.orders), fn {u, s} -> {model(u), Atom.to_string(s)} end)
    %{"status" => status, "gateway" => Atom.to_string(FakeGateway.status(ctx.gateway))}
  end

  defp flip(ctx, from, to) do
    if FakeGateway.status(ctx.gateway) == from do
      FakeGateway.set(ctx.gateway, to)
      {:ok, ctx}
    else
      {:rejected, :already, ctx}
    end
  end

  defp reply(:ok, ctx), do: {:ok, ctx}
  defp reply({:error, reason}, ctx), do: {:rejected, reason, ctx}
end

defmodule Notary.Fixtures.WorkflowIgnoresGatewaySpec do
  @moduledoc false
  # Bug: payments succeed while the gateway is down.
  use Notary.Conformance, spec: "test/fixtures/specs/Workflow.tla", discover: false
  alias Notary.Fixtures.{FakeGateway, Orders}

  def init do
    {:ok, gateway} = FakeGateway.start_link()
    {:ok, orders} = Orders.start_link(users: ["u1", "u2"], gateway: gateway, check_gateway: false)
    {:ok, %{orders: orders, gateway: gateway}}
  end

  defdelegate actions(), to: Notary.Fixtures.WorkflowSpec
  defdelegate action(name, params, ctx), to: Notary.Fixtures.WorkflowSpec
  defdelegate project(ctx), to: Notary.Fixtures.WorkflowSpec
end
```

- [ ] **Step 3: Write the failing tests**

`test/notary/conformance_test.exs`:
```elixir
defmodule Notary.ConformanceTest do
  use ExUnit.Case, async: true

  alias Notary.{Conformance, Fixtures}
  alias Notary.Conformance.Failure

  test "__notary__/0 records the mapping options" do
    assert Fixtures.BankSpec.__notary__() ==
             %{spec_path: "test/fixtures/specs/Bank.tla", observe: ["balance"], discover: true}

    assert Conformance.spec(Fixtures.BankSpec).name == "Bank"
  end

  test "observed vars default to all spec variables" do
    graph = Fixtures.graph("Bank")
    assert Conformance.observed_vars(Fixtures.BankSpec, graph) == ["balance"]
    assert Conformance.observed_vars(Fixtures.CounterSpec, Fixtures.graph("Counter")) == ["x"]
  end

  test "validate accepts correct mappings" do
    assert Conformance.validate(Fixtures.CounterSpec, Fixtures.graph("Counter")) == :ok
    assert Conformance.validate(Fixtures.WorkflowSpec, Fixtures.graph("Workflow")) == :ok
  end

  test "validate rejects unknown actions and unknown observed variables" do
    assert {:error, %Notary.Error{kind: :invalid_mapping, message: msg}} =
             Conformance.validate(Fixtures.CounterUnknownActionSpec, Fixtures.graph("Counter"))

    assert msg =~ "Decrement"
    assert msg =~ "nope"
  end

  test "discover_mappings finds discoverable mappings only" do
    mappings = Conformance.discover_mappings(:notary)
    assert mappings["Counter"] == Fixtures.CounterSpec
    assert mappings["Bank"] == Fixtures.BankSpec
    assert mappings["Workflow"] == Fixtures.WorkflowSpec
  end

  test "every failure kind has an explanation" do
    for kind <- Failure.kinds(), do: assert(Failure.explanation(kind) =~ ~r/\w/)
  end
end
```

`test/notary/fixture_graphs_test.exs`:
```elixir
defmodule Notary.FixtureGraphsTest do
  use ExUnit.Case, async: false

  @moduletag :tlc
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :work_dir, dir)
    on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
  end

  for name <- ~w(Counter Bank Workflow) do
    test "committed #{name}.dot matches what TLC produces now" do
      {:ok, spec} = Notary.Spec.fetch(unquote(name), "test/fixtures/specs")
      {:ok, fresh, _} = Notary.TLC.graph(spec, force: true)
      committed = Notary.Fixtures.graph(unquote(name))

      assert MapSet.new(Map.values(fresh.states)) == MapSet.new(Map.values(committed.states)),
             "test/fixtures/graphs/#{unquote(name)}.dot is stale: run mix run test/fixtures/regen_graphs.exs"
    end
  end
end
```

- [ ] **Step 4: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/conformance_test.exs`
Expected: compile error, `module Notary.Conformance is not available` (the fixtures `use` it).

- [ ] **Step 5: Implement**

`lib/notary/conformance/step.ex`:
```elixir
defmodule Notary.Conformance.Step do
  @moduledoc """
  One step of a conformance run. Index 0 is the initial state (`action: nil`).
  `candidates` are the spec states consistent with the implementation after this
  step; `allowed` are the observed projections the spec permitted here.
  """
  defstruct [:index, :action, :params, :outcome, :projection, candidates: [], allowed: []]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          action: String.t() | nil,
          params: map() | nil,
          outcome: :ok | {:rejected, term()},
          projection: map(),
          candidates: [String.t()],
          allowed: [map()]
        }
end
```

`lib/notary/conformance/failure.ex`:
```elixir
defmodule Notary.Conformance.Failure do
  @moduledoc "A conformance failure: what went wrong and the (shrunk) steps leading to it."

  alias Notary.Conformance.Step

  defstruct [:kind, :seed, steps: [], details: %{}]

  @type kind ::
          :init_mismatch
          | :illegal_transition
          | :action_not_enabled
          | :rejected_with_side_effect
          | :invalid_projection
          | :invalid_action_result
          | :exception
          | :timeout
          | :crashed

  @type t :: %__MODULE__{kind: kind(), seed: integer() | nil, steps: [Step.t()], details: map()}

  @explanations %{
    init_mismatch: "The implementation's initial state does not match any initial state of the spec.",
    illegal_transition: "The implementation's new state is not one the spec allows after this action.",
    action_not_enabled:
      "The implementation accepted an action the spec does not allow in this state. It should have returned {:rejected, reason, ctx}.",
    rejected_with_side_effect: "The implementation rejected the action, but its observable state changed.",
    invalid_projection: "project/1 must return exactly the observed spec variables.",
    invalid_action_result: "action/3 must return {:ok, ctx} or {:rejected, reason, ctx}.",
    exception: "The mapping module or the implementation raised an exception.",
    timeout: "A callback did not return within the action timeout.",
    crashed: "The process running the implementation crashed."
  }

  @spec new(kind(), [Step.t()], map()) :: t()
  def new(kind, steps, details), do: %__MODULE__{kind: kind, steps: steps, details: details}

  @spec kinds() :: [kind()]
  def kinds, do: Map.keys(@explanations)

  @spec explanation(kind()) :: String.t()
  def explanation(kind), do: Map.fetch!(@explanations, kind)
end
```

`lib/notary/conformance.ex`:
```elixir
defmodule Notary.Conformance do
  @moduledoc """
  The contract between a TLA+ spec and its Elixir implementation.

      defmodule MyApp.Specs.Bank do
        use Notary.Conformance, spec: "specs/Bank.tla", observe: ["balance"]

        def init, do: MyApp.Bank.start_link()
        def actions, do: %{"Deposit" => StreamData.fixed_map(%{a: StreamData.integer(1..2)})}
        def action("Deposit", %{a: a}, pid), do: ...  # {:ok, pid} | {:rejected, reason, pid}
        def project(pid), do: %{"balance" => MyApp.Bank.balance(pid)}
      end

  Options:
    * `:spec` (required): path to the `.tla` file, relative to the project root.
    * `:observe`: spec variables `project/1` returns (default: all).
    * `:discover`: set `false` to hide the module from `mix notary.test` discovery.

  `project/1` must return values in the `Notary.Value` representation; `model/1`
  and `set/1` are imported. Prefer unnamed processes (or stop them in
  `teardown/1`): every run calls `init/0` again.
  """

  alias Notary.{Error, Spec, StateGraph}

  @type ctx :: term()

  @callback init() :: {:ok, ctx()}
  @callback actions() :: %{String.t() => StreamData.t(map())}
  @callback action(String.t(), map(), ctx()) :: {:ok, ctx()} | {:rejected, term(), ctx()}
  @callback project(ctx()) :: %{String.t() => Notary.Value.t()}
  @callback teardown(ctx()) :: any()
  @optional_callbacks teardown: 1

  defmacro __using__(opts) do
    spec = Keyword.fetch!(opts, :spec)
    observe = Keyword.get(opts, :observe)
    discover = Keyword.get(opts, :discover, true)

    quote do
      @behaviour Notary.Conformance
      import Notary.Value, only: [model: 1, set: 1]

      @doc false
      def __notary__,
        do: %{spec_path: unquote(spec), observe: unquote(observe), discover: unquote(discover)}
    end
  end

  @spec spec(module()) :: Spec.t()
  def spec(module), do: Spec.from_path(module.__notary__().spec_path)

  @spec observed_vars(module(), StateGraph.t()) :: [String.t()]
  def observed_vars(module, %StateGraph{} = graph), do: module.__notary__().observe || graph.variables

  @spec validate(module(), StateGraph.t()) :: :ok | {:error, Error.t()}
  def validate(module, %StateGraph{} = graph) do
    actions = module.actions() |> Map.keys() |> Enum.sort()
    unknown_actions = Enum.reject(actions, &MapSet.member?(graph.actions, &1))
    unknown_vars = Enum.reject(observed_vars(module, graph), &(&1 in graph.variables))

    problems =
      [
        actions == [] && "actions/0 returned no actions.",
        unknown_actions != [] &&
          "actions/0 names actions that never occur in the spec's state graph: #{Enum.join(unknown_actions, ", ")}. " <>
            "Known actions: #{graph.actions |> Enum.sort() |> Enum.join(", ")}. (An action that is never enabled under the .cfg constants does not appear.)",
        unknown_vars != [] &&
          "observe: lists variables the spec does not have: #{Enum.join(unknown_vars, ", ")}. Spec variables: #{Enum.join(graph.variables, ", ")}."
      ]
      |> Enum.filter(&is_binary/1)

    case problems do
      [] -> :ok
      _ -> {:error, Error.new(:invalid_mapping, "Invalid mapping #{inspect(module)}:\n  " <> Enum.join(problems, "\n  "))}
    end
  end

  @spec discover_mappings(atom()) :: %{String.t() => module()}
  def discover_mappings(app) do
    Application.load(app)

    for module <- Application.spec(app, :modules) || [],
        Code.ensure_loaded?(module),
        function_exported?(module, :__notary__, 0),
        module.__notary__().discover,
        into: %{} do
      {spec(module).name, module}
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/conformance_test.exs && nix develop -c mix test test/notary/fixture_graphs_test.exs --include tlc`
Expected: 6 tests and 3 tests, 0 failures. If Step 1 reported state counts other than 4/7/18, trust TLC and only check that the specs match this plan's text. The tests don't hardcode those counts.

- [ ] **Step 7: Commit**

```bash
git add lib/notary/conformance.ex lib/notary/conformance test/support test/fixtures/graphs test/fixtures/regen_graphs.exs test/notary/conformance_test.exs test/notary/fixture_graphs_test.exs
git commit -m "feat: conformance mapping contract and fixture specs"
```

---

### Task 9: `Notary.Conformance.Runner` — drive, check, shrink

**Files:**
- Create: `lib/notary/conformance/runner.ex`
- Modify: `lib/notary/conformance.ex` (add `check/3`)
- Test: `test/notary/conformance/runner_test.exs`

**Interfaces:**
- Consumes: `Notary.StateGraph.initial_states/1`, `successors/3`, `state/2`; `Notary.Conformance.validate/2`, `observed_vars/2`; `Step`, `Failure`; `Notary.Config.get/1`.
- Produces:
  - `Runner.steps_generator(actions_map, max_steps) :: StreamData.t([{name, params}])`.
  - `Runner.run(module, graph, observe, steps, action_timeout) :: {:ok, [Step.t]} | {:error, Failure.t}` performs one run in a fresh process.
  - `Runner.check(module, graph, observe, opts) :: {:ok, %{runs, seed}} | {:error, Failure.t}` takes opts `:seed`, `:max_runs`, `:max_steps`, `:action_timeout`, and returns the shrunk failure with `seed` set.
  - `Notary.Conformance.check(module, graph, opts) :: {:ok, %{runs, seed}} | {:error, Failure.t} | {:error, Error.t}` validates first.

Semantics (spec §5): `C` = candidate state ids. Init: `C = {s ∈ initial : observed(s) == p0}`; empty → `:init_mismatch`. For each step, `E` = the union of `successors(c, name)`. Then:
- If the implementation accepts while `E == []`, the run fails with `:action_not_enabled`.
- If it accepts otherwise, `C' = {t ∈ E : observed(t) == p'}`, and an empty `C'` fails with `:illegal_transition`.
- If it rejects, the projection must equal the previous one (else `:rejected_with_side_effect`), and `C` is unchanged.
- `project/1` keys must equal `observe` (else `:invalid_projection`).

Each callback gets `action_timeout`. Failures that come from the worker process dying are reported as `:crashed`.

- [ ] **Step 1: Write the failing tests**

`test/notary/conformance/runner_test.exs`:
```elixir
defmodule Notary.Conformance.RunnerTest do
  use ExUnit.Case, async: true

  alias Notary.{Conformance, Fixtures}
  alias Notary.Conformance.{Failure, Runner, Step}

  defp check(module, graph_name, opts \\ []) do
    Conformance.check(module, Fixtures.graph(graph_name), Keyword.merge([seed: 42, max_runs: 200], opts))
  end

  describe "correct implementations pass" do
    test "Counter" do
      assert {:ok, %{runs: 200, seed: 42}} = check(Fixtures.CounterSpec, "Counter")
    end

    test "Bank with an unobserved variable" do
      assert {:ok, _} = check(Fixtures.BankSpec, "Bank")
    end

    test "Workflow with two actors and an external gateway" do
      assert {:ok, _} = check(Fixtures.WorkflowSpec, "Workflow")
    end
  end

  describe "buggy implementations fail with a shrunk trace" do
    test "missing guard -> action_not_enabled after exactly Max+1 increments" do
      assert {:error, %Failure{kind: :action_not_enabled, seed: 42, steps: steps}} =
               check(Fixtures.CounterNoGuardSpec, "Counter")

      assert [%Step{index: 0, action: nil} | rest] = steps
      assert Enum.map(rest, & &1.action) == ["Inc", "Inc", "Inc", "Inc"]
      assert List.last(steps).projection == %{"x" => 4}
      assert List.last(steps).allowed == []
    end

    test "wrong transition -> illegal_transition with what the spec allowed" do
      assert {:error, %Failure{kind: :illegal_transition, steps: steps}} =
               check(Fixtures.CounterBadResetSpec, "Counter")

      last = List.last(steps)
      assert last.action == "Reset"
      assert last.projection == %{"x" => 1}
      assert last.allowed == [%{"x" => 0}]
      assert length(steps) == 2
    end

    test "rejected with side effect" do
      assert {:error, %Failure{kind: :rejected_with_side_effect, steps: steps}} =
               check(Fixtures.CounterSideEffectSpec, "Counter")

      assert List.last(steps).outcome == {:rejected, :at_max}
    end

    test "overdraft in Bank shrinks to a single withdrawal of 1" do
      assert {:error, %Failure{kind: :action_not_enabled, steps: [_init, step]}} =
               check(Fixtures.BankOverdraftSpec, "Bank")

      assert step.action == "Withdraw"
      assert step.params == %{a: 1}
    end

    test "Workflow paying while the gateway is down" do
      assert {:error, %Failure{kind: :action_not_enabled, steps: steps}} =
               check(Fixtures.WorkflowIgnoresGatewaySpec, "Workflow")

      assert Enum.map(steps, & &1.action) == [nil, "GatewayDown", "Pay"]
    end

    test "init mismatch" do
      assert {:error, %Failure{kind: :init_mismatch, steps: [%Step{projection: %{"x" => 7}, allowed: [%{"x" => 0}]}]}} =
               check(Fixtures.CounterBadInitSpec, "Counter")
    end

    test "invalid projection" do
      assert {:error, %Failure{kind: :invalid_projection, details: %{got: ["extra", "x"], expected: ["x"]}}} =
               check(Fixtures.CounterBadProjectionSpec, "Counter")
    end

    test "exceptions are reported with the callback that raised" do
      assert {:error, %Failure{kind: :exception, details: details}} = check(Fixtures.CounterRaisingSpec, "Counter")
      assert details.exception =~ "boom"
      assert details.during =~ "action/3 Inc"
    end

    test "slow callbacks time out" do
      assert {:error, %Failure{kind: :timeout, details: %{during: during}}} =
               check(Fixtures.CounterSlowSpec, "Counter", action_timeout: 50, max_runs: 20)

      assert during =~ "Inc"
    end
  end

  test "invalid mappings are rejected before running" do
    assert {:error, %Notary.Error{kind: :invalid_mapping}} = check(Fixtures.CounterUnknownActionSpec, "Counter")
  end

  test "processes started by init are cleaned up after each run" do
    before = length(Process.list())
    assert {:ok, _} = check(Fixtures.WorkflowSpec, "Workflow", max_runs: 50)
    Process.sleep(50)
    assert length(Process.list()) - before < 5
  end

  test "the generator emits only declared actions, up to max_steps" do
    gen = Runner.steps_generator(%{"Inc" => StreamData.constant(%{})}, 3)

    for steps <- Enum.take(gen, 50) do
      assert length(steps) <= 3
      assert Enum.all?(steps, &(&1 == {"Inc", %{}}))
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/conformance/runner_test.exs`
Expected: FAIL, `Notary.Conformance.check/3 is undefined`.

- [ ] **Step 3: Implement `lib/notary/conformance/runner.ex`**

```elixir
defmodule Notary.Conformance.Runner do
  @moduledoc """
  Drives an implementation through generated action sequences and checks every
  step against the spec's state graph (see the Notary spec §5). Each run happens
  in a fresh process, which exits with `:shutdown` afterwards so processes linked
  to it by `init/0` are cleaned up.
  """

  alias Notary.{Config, StateGraph}
  alias Notary.Conformance.{Failure, Step}

  @spec check(module(), StateGraph.t(), [String.t()], keyword()) ::
          {:ok, %{runs: non_neg_integer(), seed: integer()}} | {:error, Failure.t()}
  def check(module, graph, observe, opts) do
    seed = Keyword.get_lazy(opts, :seed, fn -> :rand.uniform(1_000_000) end)
    max_runs = Keyword.get(opts, :max_runs, Config.get(:max_runs))
    max_steps = Keyword.get(opts, :max_steps, Config.get(:max_steps))
    timeout = Keyword.get(opts, :action_timeout, Config.get(:action_timeout))

    generator = steps_generator(module.actions(), max_steps)
    options = [initial_seed: {0, 0, seed}, max_runs: max_runs, max_shrinking_steps: 500]

    result =
      StreamData.check_all(generator, options, fn steps ->
        case run(module, graph, observe, steps, timeout) do
          {:ok, _steps} -> {:ok, nil}
          {:error, failure} -> {:error, failure}
        end
      end)

    case result do
      {:ok, _} -> {:ok, %{runs: max_runs, seed: seed}}
      {:error, %{shrunk_failure: failure}} -> {:error, %{failure | seed: seed}}
    end
  end

  @spec steps_generator(%{String.t() => StreamData.t(map())}, non_neg_integer()) :: StreamData.t(list())
  def steps_generator(actions, max_steps) do
    actions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, params} -> StreamData.tuple({StreamData.constant(name), params}) end)
    |> StreamData.one_of()
    |> StreamData.list_of(max_length: max_steps)
  end

  @spec run(module(), StateGraph.t(), [String.t()], [{String.t(), map()}], timeout()) ::
          {:ok, [Step.t()]} | {:error, Failure.t()}
  def run(module, graph, observe, steps, timeout) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        notify = fn event -> send(parent, {ref, :progress, event}) end
        send(parent, {ref, :done, execute(module, graph, observe, steps, notify)})
        exit(:shutdown)
      end)

    await(%{ref: ref, pid: pid, monitor: monitor, timeout: timeout}, [], nil)
  end

  defp await(w, steps, during) do
    %{ref: ref, pid: pid, monitor: monitor} = w

    receive do
      {^ref, :progress, {:started, label}} ->
        await(w, steps, label)

      {^ref, :progress, {:step, step}} ->
        await(w, [step | steps], nil)

      {^ref, :done, :ok} ->
        Process.demonitor(monitor, [:flush])
        {:ok, Enum.reverse(steps)}

      {^ref, :done, {:fail, kind, details}} ->
        Process.demonitor(monitor, [:flush])
        {:error, Failure.new(kind, Enum.reverse(steps), Map.put_new(details, :during, during))}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, Failure.new(:crashed, Enum.reverse(steps), %{reason: inspect(reason), during: during})}
    after
      w.timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, Failure.new(:timeout, Enum.reverse(steps), %{during: during, timeout: w.timeout})}
    end
  end

  # -- worker -----------------------------------------------------------------

  defp execute(m, graph, observe, steps, notify) do
    {:ok, ctx} = call(notify, "init/0", fn -> m.init() end)
    p0 = project(m, ctx, observe, notify)
    initial = StateGraph.initial_states(graph)
    allowed = initial |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
    candidates = Enum.filter(initial, &(observed(graph, &1, observe) == p0))

    notify.({:step,
     %Step{index: 0, outcome: :ok, projection: p0, candidates: candidates, allowed: allowed}})

    {result, ctx} =
      if candidates == [],
        do: {{:fail, :init_mismatch, %{}}, ctx},
        else: walk(m, graph, observe, steps, 1, ctx, p0, candidates, notify)

    if function_exported?(m, :teardown, 1), do: call(notify, "teardown/1", fn -> m.teardown(ctx) end)
    result
  rescue
    e -> {:fail, :exception, %{exception: Exception.format(:error, e, __STACKTRACE__)}}
  catch
    {:notary_fail, kind, details} -> {:fail, kind, details}
  end

  defp walk(_m, _graph, _observe, [], _i, ctx, _p, _candidates, _notify), do: {:ok, ctx}

  defp walk(m, graph, observe, [{name, params} | rest], i, ctx, p, candidates, notify) do
    succ = candidates |> Enum.flat_map(&StateGraph.successors(graph, &1, name)) |> Enum.uniq()

    case call(notify, "action/3 #{name} #{inspect(params)}", fn -> m.action(name, params, ctx) end) do
      {:ok, ctx} ->
        p2 = project(m, ctx, observe, notify)
        allowed = succ |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
        next = Enum.filter(succ, &(observed(graph, &1, observe) == p2))

        notify.({:step,
         %Step{index: i, action: name, params: params, outcome: :ok, projection: p2, candidates: next, allowed: allowed}})

        cond do
          succ == [] -> {{:fail, :action_not_enabled, %{}}, ctx}
          next == [] -> {{:fail, :illegal_transition, %{}}, ctx}
          true -> walk(m, graph, observe, rest, i + 1, ctx, p2, next, notify)
        end

      {:rejected, reason, ctx} ->
        p2 = project(m, ctx, observe, notify)

        notify.({:step,
         %Step{index: i, action: name, params: params, outcome: {:rejected, reason}, projection: p2, candidates: candidates, allowed: [p]}})

        if p2 == p,
          do: walk(m, graph, observe, rest, i + 1, ctx, p, candidates, notify),
          else: {{:fail, :rejected_with_side_effect, %{}}, ctx}

      other ->
        throw({:notary_fail, :invalid_action_result, %{got: inspect(other)}})
    end
  end

  defp call(notify, label, fun) do
    notify.({:started, label})
    fun.()
  end

  defp project(m, ctx, observe, notify) do
    projection = call(notify, "project/1", fn -> m.project(ctx) end)
    got = if is_map(projection), do: projection |> Map.keys() |> Enum.sort(), else: projection
    expected = Enum.sort(observe)

    if got == expected,
      do: projection,
      else: throw({:notary_fail, :invalid_projection, %{got: got, expected: expected}})
  end

  defp observed(graph, id, observe), do: graph |> StateGraph.state(id) |> Map.take(observe)
end
```

Add `check/3` to `lib/notary/conformance.ex` (after `validate/2`):
```elixir
  @spec check(module(), StateGraph.t(), keyword()) ::
          {:ok, %{runs: non_neg_integer(), seed: integer()}}
          | {:error, Notary.Conformance.Failure.t()}
          | {:error, Error.t()}
  def check(module, %StateGraph{} = graph, opts \\ []) do
    with :ok <- validate(module, graph) do
      Notary.Conformance.Runner.check(module, graph, observed_vars(module, graph), opts)
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/conformance/runner_test.exs`
Expected: 15 tests, 0 failures. Some of these tests check that shrinking reaches a minimal case: Max+1 Incs, a single `Withdraw 1`, and `[GatewayDown, Pay]`. If one of them yields a longer list, raise `max_shrinking_steps`. Don't loosen the assertion: a minimal trace is a requirement in the spec (§1 success criteria).

- [ ] **Step 5: Commit**

```bash
git add lib/notary/conformance.ex lib/notary/conformance/runner.ex test/notary/conformance/runner_test.exs
git commit -m "feat: conformance runner with candidate-state tracking and shrinking"
```

---

### Task 10: `Notary.Report` — text and JSON

**Files:**
- Create: `lib/notary/report.ex`
- Test: `test/notary/report_test.exs`

**Interfaces:**
- Consumes: `Notary.Value.to_tla/1`, `Failure.explanation/1`, `Step`, `Notary.Error`, TLC `violation` maps (Task 4).
- Produces:
  - Stage/report shapes, used by Task 11:
    - `stage :: %{stage: :lock | :check | :conformance, status: :pass | :fail | :error | :skipped, payload: term}`
    - `spec_result :: %{spec: String.t(), status: :pass | :fail, stages: [stage]}`
    - `report :: %{status: :pass | :fail, lock: stage | nil, specs: [spec_result]}`
  - `Report.format(report) :: String.t()`
  - `Report.to_json(report) :: map` (JSON-encodable)
  - `Report.format_failure(spec_name, Failure.t) :: String.t()`
  - `Report.format_violation(spec_name, violation) :: String.t()`
  - `Report.format_state(map) :: String.t()`, e.g. `balance = 1, lastOp = "deposit"`

Payloads per stage:
- lock: `:ok | {:error, Error}`
- check: `{:ok, stats} | {:violation, v} | {:error, Error}`
- conformance: `{:ok, %{runs, seed}} | {:error, Failure} | {:error, Error} | :skipped`

- [ ] **Step 1: Write the failing tests**

`test/notary/report_test.exs`:
```elixir
defmodule Notary.ReportTest do
  use ExUnit.Case, async: true

  alias Notary.{Error, Report, Value}
  alias Notary.Conformance.{Failure, Step}

  @failure %Failure{
    kind: :action_not_enabled,
    seed: 1234,
    steps: [
      %Step{index: 0, outcome: :ok, projection: %{"balance" => 0}, allowed: [%{"balance" => 0}]},
      %Step{index: 1, action: "Withdraw", params: %{a: 1}, outcome: :ok, projection: %{"balance" => -1}, allowed: []}
    ]
  }

  @violation %{
    kind: :invariant,
    name: "Small",
    message: "Invariant Small is violated.",
    trace: [%{index: 1, action: nil, state: %{"x" => 0}}, %{index: 2, action: "Next", state: %{"x" => 1}}]
  }

  defp report(stages, status \\ :fail),
    do: %{status: status, lock: %{stage: :lock, status: :pass, payload: :ok}, specs: [%{spec: "Bank", status: status, stages: stages}]}

  test "format_state uses TLA+ syntax" do
    assert Report.format_state(%{"b" => Value.set([1]), "a" => "x"}) == ~S(a = "x", b = {1})
  end

  test "format_failure explains, tabulates steps, marks divergence and gives next commands" do
    text = Report.format_failure("Bank", @failure)
    assert text =~ "Conformance failure in Bank: action_not_enabled (seed 1234)"
    assert text =~ "should have returned {:rejected, reason, ctx}"
    assert text =~ "(init)"
    assert text =~ "Withdraw %{a: 1}"
    assert text =~ "balance = -1"
    assert text =~ "<-- diverges here"
    assert text =~ "Spec allowed: (no Withdraw transition is enabled here)"
    assert text =~ "mix notary.test Bank --seed 1234"
    assert text =~ "mix notary.graph Bank --trace failure"
  end

  test "format_violation shows the counterexample" do
    text = Report.format_violation("Inv", @violation)
    assert text =~ "TLC found a violation in Inv: Invariant Small is violated. (invariant)"
    assert text =~ "1. (initial)  x = 0"
    assert text =~ "2. Next  x = 1"
  end

  test "format summarises all stages" do
    text =
      report([
        %{stage: :check, status: :pass, payload: {:ok, %{distinct_states: 8, states_generated: 20}}},
        %{stage: :conformance, status: :fail, payload: {:error, @failure}}
      ])
      |> Report.format()

    assert text =~ "lock: pass"
    assert text =~ "Bank: FAIL"
    assert text =~ "check: pass (8 distinct states)"
    assert text =~ "conformance: fail"
    assert text =~ "<-- diverges here"
  end

  test "to_json is encodable and structured for LLMs" do
    json =
      report([
        %{stage: :check, status: :fail, payload: {:violation, @violation}},
        %{stage: :conformance, status: :skipped, payload: :skipped}
      ])
      |> Report.to_json()

    encoded = JSON.encode!(json)
    assert %{"status" => "fail", "lock" => %{"status" => "pass"}, "specs" => [spec]} = JSON.decode!(encoded)
    assert [%{"stage" => "check", "violation" => v}, %{"stage" => "conformance", "status" => "skipped"}] = spec["stages"]
    assert v["kind"] == "invariant"
    assert [%{"index" => 1, "action" => nil, "state" => %{"x" => "0"}}, _] = v["trace"]
  end

  test "to_json renders failures and errors" do
    json =
      report([
        %{stage: :check, status: :pass, payload: {:ok, %{distinct_states: 8, states_generated: 20}}},
        %{stage: :conformance, status: :fail, payload: {:error, @failure}}
      ])
      |> Report.to_json()
      |> JSON.encode!()
      |> JSON.decode!()

    [_, conf] = hd(json["specs"])["stages"]
    f = conf["failure"]
    assert f["kind"] == "action_not_enabled"
    assert f["seed"] == 1234
    assert f["failed_step"] == 1
    assert f["explanation"] =~ "rejected"
    assert [%{"action" => nil}, %{"action" => "Withdraw", "params" => "%{a: 1}", "state" => %{"balance" => "-1"}, "spec_allowed" => []}] = f["steps"]

    err = Report.to_json(report([%{stage: :check, status: :error, payload: {:error, Error.new(:spec_error, "bad", %{location: %{line: 3}})}}]))
    assert %{"error" => %{"kind" => "spec_error", "message" => "bad", "details" => %{"location" => %{"line" => 3}}}} =
             err |> JSON.encode!() |> JSON.decode!() |> Map.fetch!("specs") |> hd() |> Map.fetch!("stages") |> hd()
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/report_test.exs`
Expected: FAIL, `Notary.Report.format_state/1 is undefined`.

- [ ] **Step 3: Implement `lib/notary/report.ex`**

```elixir
defmodule Notary.Report do
  @moduledoc "Renders Notary results as human-readable text and as JSON-ready maps."

  alias Notary.{Error, Value}
  alias Notary.Conformance.{Failure, Step}

  @type stage :: %{stage: :lock | :check | :conformance, status: :pass | :fail | :error | :skipped, payload: term()}
  @type spec_result :: %{spec: String.t(), status: :pass | :fail, stages: [stage()]}
  @type report :: %{status: :pass | :fail, lock: stage() | nil, specs: [spec_result()]}

  # -- text -------------------------------------------------------------------

  @spec format(report()) :: String.t()
  def format(%{lock: lock, specs: specs, status: status}) do
    lock_text =
      case lock do
        nil -> []
        %{status: :pass} -> ["lock: pass"]
        %{payload: {:error, %Error{} = e}} -> ["lock: FAIL", indent(e.message)]
      end

    spec_texts = Enum.map(specs, &format_spec/1)
    summary = if status == :pass, do: "Notary: all checks passed.", else: "Notary: verification FAILED."
    Enum.join(lock_text ++ spec_texts ++ [summary], "\n\n")
  end

  defp format_spec(%{spec: name, status: status, stages: stages}) do
    header = "#{name}: #{if status == :pass, do: "pass", else: "FAIL"}"
    Enum.join([header | Enum.map(stages, &format_stage(name, &1))], "\n")
  end

  defp format_stage(_name, %{stage: :check, payload: {:ok, stats}}),
    do: "  check: pass (#{stats.distinct_states} distinct states)"

  defp format_stage(_name, %{stage: stage, status: :skipped}), do: "  #{stage}: skipped"

  defp format_stage(_name, %{stage: :conformance, payload: {:ok, %{runs: runs, seed: seed}}}),
    do: "  conformance: pass (#{runs} runs, seed #{seed})"

  defp format_stage(name, %{stage: stage, status: status, payload: payload}) do
    body =
      case payload do
        {:violation, v} -> format_violation(name, v)
        {:error, %Failure{} = f} -> format_failure(name, f)
        {:error, %Error{} = e} -> e.message
      end

    "  #{stage}: #{status}\n" <> indent(body, 4)
  end

  @spec format_failure(String.t(), Failure.t()) :: String.t()
  def format_failure(spec_name, %Failure{} = f) do
    last = List.last(f.steps)
    rows = Enum.map(f.steps, &step_row(&1, &1 == last))
    width = rows |> Enum.map(fn {_, a, _, _, _} -> String.length(a) end) |> Enum.max(fn -> 6 end)

    table =
      Enum.map_join(rows, "\n", fn {i, action, outcome, state, mark} ->
        "  #{String.pad_trailing(i, 5)} #{String.pad_trailing(action, width)}  #{String.pad_trailing(outcome, 10)}  #{state}#{mark}"
      end)

    allowed =
      case last do
        nil -> []
        %Step{allowed: [], action: action} when is_binary(action) -> ["Spec allowed: (no #{action} transition is enabled here)"]
        %Step{allowed: allowed} -> ["Spec allowed: " <> Enum.map_join(allowed, " | ", &format_state/1)]
      end

    details = f.details |> Map.drop([:during]) |> Enum.map(fn {k, v} -> "#{k}: #{detail(v)}" end)
    during = if f.details[:during], do: ["During: #{f.details.during}"], else: []
    seed = if f.seed, do: " (seed #{f.seed})", else: ""
    reproduce = if f.seed, do: "mix notary.test #{spec_name} --seed #{f.seed}", else: "mix notary.test #{spec_name}"

    Enum.join(
      ["Conformance failure in #{spec_name}: #{f.kind}#{seed}", Failure.explanation(f.kind), "", "  step  action / params / outcome / implementation state", table, ""] ++
        allowed ++ during ++ details ++
        ["", "Reproduce: #{reproduce}", "Visualize: mix notary.graph #{spec_name} --trace failure --open"],
      "\n"
    )
  end

  defp step_row(%Step{} = s, last?) do
    action = if s.action, do: "#{s.action} #{inspect(s.params)}", else: "(init)"

    outcome =
      case s.outcome do
        :ok -> "ok"
        {:rejected, reason} -> "rejected #{inspect(reason)}"
      end

    {Integer.to_string(s.index), action, outcome, format_state(s.projection), if(last?, do: "   <-- diverges here", else: "")}
  end

  @spec format_violation(String.t(), map()) :: String.t()
  def format_violation(spec_name, v) do
    trace = Enum.map_join(v.trace, "\n", &trace_line/1)
    "TLC found a violation in #{spec_name}: #{v.message} (#{v.kind})\nCounterexample:\n#{trace}\n" <>
      "Visualize: mix notary.graph #{spec_name} --trace counterexample --open"
  end

  defp trace_line(%{stuttering: true, index: i}), do: "  #{i}. (stuttering forever)"
  defp trace_line(%{back_to: n, index: _}), do: "  -> loops back to state #{n}"
  defp trace_line(%{index: i, action: a, state: s}), do: "  #{i}. #{a || "(initial)"}  #{format_state(s)}"

  @spec format_state(map()) :: String.t()
  def format_state(state) when is_map(state),
    do: state |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k} = #{Value.to_tla(v)}" end)

  def format_state(other), do: inspect(other)

  defp detail(v) when is_binary(v), do: v
  defp detail(v), do: inspect(v)

  defp indent(text, n \\ 2), do: text |> String.split("\n") |> Enum.map_join("\n", &(String.duplicate(" ", n) <> &1))

  # -- JSON -------------------------------------------------------------------

  @spec to_json(report()) :: map()
  def to_json(%{status: status, lock: lock, specs: specs}) do
    %{
      "status" => Atom.to_string(status),
      "lock" => lock && stage_json(lock),
      "specs" =>
        Enum.map(specs, fn s ->
          %{"spec" => s.spec, "status" => Atom.to_string(s.status), "stages" => Enum.map(s.stages, &stage_json/1)}
        end)
    }
  end

  defp stage_json(%{stage: stage, status: status, payload: payload}) do
    Map.merge(%{"stage" => Atom.to_string(stage), "status" => Atom.to_string(status)}, payload_json(payload))
  end

  defp payload_json(:ok), do: %{}
  defp payload_json(:skipped), do: %{}
  defp payload_json({:ok, %{distinct_states: d, states_generated: g}}), do: %{"distinct_states" => d, "states_generated" => g}
  defp payload_json({:ok, %{runs: r, seed: s}}), do: %{"runs" => r, "seed" => s}
  defp payload_json({:violation, v}), do: %{"violation" => violation_json(v)}
  defp payload_json({:error, %Failure{} = f}), do: %{"failure" => failure_json(f)}
  defp payload_json({:error, %Error{} = e}), do: %{"error" => error_json(e)}

  defp violation_json(v) do
    %{
      "kind" => Atom.to_string(v.kind),
      "name" => v.name,
      "message" => v.message,
      "trace" =>
        Enum.map(v.trace, fn
          %{state: s} = step -> %{"index" => step.index, "action" => step.action, "state" => state_json(s)}
          %{back_to: n, index: i} -> %{"index" => i, "back_to" => n}
          %{stuttering: true, index: i} -> %{"index" => i, "stuttering" => true}
        end)
    }
  end

  defp failure_json(%Failure{} = f) do
    %{
      "kind" => Atom.to_string(f.kind),
      "explanation" => Failure.explanation(f.kind),
      "seed" => f.seed,
      "failed_step" => f.steps |> List.last() |> then(&(&1 && &1.index)),
      "steps" =>
        Enum.map(f.steps, fn s ->
          %{
            "index" => s.index,
            "action" => s.action,
            "params" => s.params && inspect(s.params),
            "outcome" => if(s.outcome == :ok, do: "ok", else: "rejected: #{inspect(elem(s.outcome, 1))}"),
            "state" => state_json(s.projection),
            "spec_allowed" => Enum.map(s.allowed, &state_json/1)
          }
        end),
      "details" => jsonable(f.details)
    }
  end

  defp error_json(%Error{} = e),
    do: %{"kind" => Atom.to_string(e.kind), "message" => e.message, "details" => jsonable(e.details)}

  defp state_json(state) when is_map(state), do: Map.new(state, fn {k, v} -> {k, Value.to_tla(v)} end)
  defp state_json(other), do: inspect(other)

  defp jsonable(map) when is_map(map) and not is_struct(map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(v) when is_atom(v), do: Atom.to_string(v)
  defp jsonable(v), do: inspect(v)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/report_test.exs`
Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/notary/report.ex test/notary/report_test.exs
git commit -m "feat: text and JSON reports"
```

---
### Task 11: `Notary.Verify`, `Notary.CLI`, and `mix notary.check | test | verify | lock`

**Files:**
- Create: `lib/notary/verify.ex`, `lib/notary/cli.ex`, `lib/mix/tasks/notary.check.ex`, `lib/mix/tasks/notary.test.ex`, `lib/mix/tasks/notary.verify.ex`, `lib/mix/tasks/notary.lock.ex`
- Modify: `lib/notary/conformance.ex` (add `assert_conforms/2`)
- Test: `test/mix/tasks/notary_tasks_test.exs`

**Interfaces:**
- Consumes: `Notary.Lock.check/1` and `write/1`, `Notary.TLC.check/2` and `graph/2`, `Notary.Conformance.check/3` and `discover_mappings/1`, `Notary.Report` (stage, spec_result and report shapes, plus `format/1` and `to_json/1`), `Notary.Spec.select/2`.
- Produces:
  - `Verify.lock_stage(dir) :: stage`
  - `Verify.check_spec(Spec.t, opts) :: spec_result`
  - `Verify.test_spec(Spec.t, mappings :: %{name => module}, opts) :: spec_result`, with opts `:seed`, `:max_runs`, `:max_steps`, `:action_timeout`, `:force`, `:timeout`, `:max_states`
  - `Verify.report(lock_stage | nil, [spec_result]) :: report`
  - `Notary.Conformance.assert_conforms(module, opts \\ []) :: :ok`, which raises `%Notary.Error{kind: :conformance_failed}` whose message is the text report
  - `Notary.CLI.parse!/2`, `specs!/1`, `ensure_test_env!/1`, `load_mappings!/0`, `conformance_opts/1`, `finish/2`

- [ ] **Step 1: Write the failing tests**

`test/mix/tasks/notary_tasks_test.exs`:
```elixir
defmodule Mix.Tasks.NotaryTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tlc
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    specs = Path.join(dir, "specs")
    File.mkdir_p!(specs)
    for f <- Path.wildcard("test/fixtures/specs/*.{tla,cfg}"), do: File.cp!(f, Path.join(specs, Path.basename(f)))
    Application.put_env(:notary, :specs_dir, specs)
    Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Enum.each([:specs_dir, :work_dir], &Application.delete_env(:notary, &1)) end)
    %{specs: specs, work: Path.join(dir, "work")}
  end

  # Runs a mix task, capturing stdout and the exit code (tasks exit({:shutdown, 1}) on failure).
  defp run_task(task, args) do
    parent = self()

    output =
      capture_io(fn ->
        code =
          try do
            Mix.Task.rerun(task, args)
            0
          catch
            :exit, {:shutdown, code} -> code
          end

        send(parent, {:exit_code, code})
      end)

    assert_received {:exit_code, code}
    {output, code}
  end

  defp last_json(output), do: output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

  test "notary.check passes and writes report.json", %{work: work} do
    {out, 0} = run_task("notary.check", ["--json"])
    assert %{"status" => "pass", "specs" => specs} = last_json(out)
    assert Enum.map(specs, & &1["spec"]) == ["Bank", "Counter", "Workflow"]
    assert File.exists?(Path.join(work, "report.json"))
  end

  test "notary.check fails on bad specs with violation and spec errors" do
    Application.put_env(:notary, :specs_dir, "test/fixtures/specs_bad")
    {out, 1} = run_task("notary.check", ["--json"])
    %{"status" => "fail", "specs" => [broken, inv]} = last_json(out)
    assert [%{"stage" => "check", "status" => "error", "error" => %{"kind" => "spec_error"}}] = broken["stages"]
    assert [%{"stage" => "check", "status" => "fail", "violation" => %{"name" => "Small"}}] = inv["stages"]
  end

  test "notary.check text output" do
    {out, 0} = run_task("notary.check", ["Counter"])
    assert out =~ "Counter: pass"
    assert out =~ "all checks passed"
  end

  test "notary.test runs conformance for every discovered mapping" do
    {out, 0} = run_task("notary.test", ["--json", "--seed", "7", "--max-runs", "30"])
    %{"status" => "pass", "specs" => specs} = last_json(out)

    for spec <- specs do
      assert [%{"stage" => "check", "status" => "pass"}, %{"stage" => "conformance", "status" => "pass", "seed" => 7, "runs" => 30}] =
               spec["stages"]
    end
  end

  test "notary.test reports specs with no mapping", %{specs: specs} do
    File.write!(Path.join(specs, "Lonely.tla"), File.read!(Path.join(specs, "Counter.tla")) |> String.replace("MODULE Counter", "MODULE Lonely"))
    File.cp!(Path.join(specs, "Counter.cfg"), Path.join(specs, "Lonely.cfg"))
    {out, 1} = run_task("notary.test", ["Lonely", "--json"])
    %{"specs" => [%{"stages" => [_, conf]}]} = last_json(out)
    assert conf["error"]["kind"] == "missing_mapping"
  end

  test "notary.verify requires a lock, passes after notary.lock, fails after a spec edit", %{specs: specs} do
    {out, 1} = run_task("notary.verify", ["--json", "--max-runs", "20"])
    assert %{"lock" => %{"status" => "fail"}} = last_json(out)

    {lock_out, 0} = run_task("notary.lock", [])
    assert lock_out =~ "Locked 6 spec files"

    {out, 0} = run_task("notary.verify", ["--json", "--max-runs", "20"])
    assert %{"status" => "pass", "lock" => %{"status" => "pass"}} = last_json(out)

    File.write!(Path.join(specs, "Counter.tla"), File.read!(Path.join(specs, "Counter.tla")) <> "\n\\* edited\n")
    {out, 1} = run_task("notary.verify", [])
    assert out =~ "changed: Counter.tla"
    assert out =~ "do not edit specs"
  end

  test "assert_conforms passes for correct mappings and raises a readable report for buggy ones" do
    assert Notary.Conformance.assert_conforms(Notary.Fixtures.CounterSpec, max_runs: 30) == :ok

    error =
      assert_raise Notary.Error, fn ->
        Notary.Conformance.assert_conforms(Notary.Fixtures.CounterNoGuardSpec, seed: 3)
      end

    assert error.kind == :conformance_failed
    assert error.message =~ "action_not_enabled"
    assert error.message =~ "<-- diverges here"
  end
end
```
`assert_conforms` resolves specs from the mapping's `spec:` path (`test/fixtures/specs/...`), not from `specs_dir`. That's intended: it serves plain `mix test`.

- [ ] **Step 2: Run them to verify they fail**

Run: `nix develop -c mix test test/mix/tasks/notary_tasks_test.exs --include tlc`
Expected: FAIL, `The task "notary.check" could not be found`.

- [ ] **Step 3: Implement**

`lib/notary/verify.ex`:
```elixir
defmodule Notary.Verify do
  @moduledoc "Runs Notary's verification stages and assembles reports (shared by the mix tasks)."

  alias Notary.{Conformance, Error, Lock, Report, Spec, TLC}
  alias Notary.Conformance.Failure

  @graph_opts [:force, :timeout, :max_states]
  @conformance_opts [:seed, :max_runs, :max_steps, :action_timeout]

  @spec lock_stage(String.t()) :: Report.stage()
  def lock_stage(dir) do
    case Lock.check(dir) do
      :ok -> stage(:lock, :pass, :ok)
      {:error, error} -> stage(:lock, :fail, {:error, error})
    end
  end

  @spec check_spec(Spec.t(), keyword()) :: Report.spec_result()
  def check_spec(%Spec{} = spec, opts \\ []) do
    stage =
      case TLC.check(spec, Keyword.take(opts, @graph_opts)) do
        {:ok, stats} -> stage(:check, :pass, {:ok, stats})
        {:violation, v} -> stage(:check, :fail, {:violation, v})
        {:error, error} -> stage(:check, :error, {:error, error})
      end

    spec_result(spec.name, [stage])
  end

  @spec test_spec(Spec.t(), %{String.t() => module()}, keyword()) :: Report.spec_result()
  def test_spec(%Spec{} = spec, mappings, opts \\ []) do
    stages =
      case TLC.graph(spec, Keyword.take(opts, @graph_opts)) do
        {:ok, graph, stats} ->
          [stage(:check, :pass, {:ok, stats}), conformance_stage(spec, graph, mappings, opts)]

        {:violation, v} ->
          [stage(:check, :fail, {:violation, v}), stage(:conformance, :skipped, :skipped)]

        {:error, error} ->
          [stage(:check, :error, {:error, error}), stage(:conformance, :skipped, :skipped)]
      end

    spec_result(spec.name, stages)
  end

  defp conformance_stage(spec, graph, mappings, opts) do
    case Map.fetch(mappings, spec.name) do
      :error ->
        stage(:conformance, :fail, {:error, missing_mapping(spec)})

      {:ok, module} ->
        case Conformance.check(module, graph, Keyword.take(opts, @conformance_opts)) do
          {:ok, summary} -> stage(:conformance, :pass, {:ok, summary})
          {:error, %Failure{} = failure} -> stage(:conformance, :fail, {:error, failure})
          {:error, %Error{} = error} -> stage(:conformance, :error, {:error, error})
        end
    end
  end

  defp missing_mapping(spec) do
    rel = Path.relative_to_cwd(spec.tla_path)

    Error.new(
      :missing_mapping,
      "No mapping module for spec #{spec.name}. Create one under test/notary/ with " <>
        "`use Notary.Conformance, spec: \"#{rel}\"` (see `mix notary.new`)."
    )
  end

  @spec report(Report.stage() | nil, [Report.spec_result()]) :: Report.report()
  def report(lock, specs) do
    ok? = (lock == nil or lock.status == :pass) and Enum.all?(specs, &(&1.status == :pass))
    %{status: if(ok?, do: :pass, else: :fail), lock: lock, specs: specs}
  end

  defp spec_result(name, stages) do
    ok? = Enum.all?(stages, &(&1.status in [:pass, :skipped]))
    %{spec: name, status: if(ok?, do: :pass, else: :fail), stages: stages}
  end

  defp stage(name, status, payload), do: %{stage: name, status: status, payload: payload}
end
```

Add to `lib/notary/conformance.ex`:
```elixir
  @doc """
  ExUnit-friendly conformance check for plain `mix test`:

      test "Bank conforms", do: Notary.Conformance.assert_conforms(MyApp.Specs.Bank)
  """
  @spec assert_conforms(module(), keyword()) :: :ok
  def assert_conforms(module, opts \\ []) do
    spec = spec(module)
    result = Notary.Verify.test_spec(spec, %{spec.name => module}, opts)

    if result.status == :pass do
      :ok
    else
      report = Notary.Report.format(%{status: :fail, lock: nil, specs: [result]})
      raise Error.new(:conformance_failed, report)
    end
  end
```

`lib/notary/cli.ex`:
```elixir
defmodule Notary.CLI do
  @moduledoc false
  # Shared plumbing for the mix tasks.

  alias Notary.{Config, Report, Spec}

  @switches [json: :boolean, seed: :integer, max_runs: :integer, max_steps: :integer, force: :boolean]

  def parse!(args, extra \\ []) do
    {opts, names, invalid} = OptionParser.parse(args, strict: @switches ++ extra)
    if invalid != [], do: Mix.raise("Unknown or invalid options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    {opts, names}
  end

  def specs!(names) do
    dir = Config.specs_dir()

    case Spec.select(names, dir) do
      {:ok, []} -> Mix.raise("No specs found in #{Path.relative_to_cwd(dir)}. Create one with `mix notary.new Name`.")
      {:ok, specs} -> specs
      {:error, error} -> Mix.raise(error.message)
    end
  end

  def ensure_test_env!(task) do
    if Mix.env() != :test do
      Mix.raise("""
      mix #{task} must run in the test environment (mapping modules live under test/notary/). Add to mix.exs:

          def cli, do: [preferred_envs: ["notary.test": :test, "notary.verify": :test]]

      or run: MIX_ENV=test mix #{task}
      """)
    end
  end

  def load_mappings! do
    Mix.Task.run("compile")
    Mix.Task.run("app.start")
    helper = "test/notary/notary_helper.exs"
    if File.exists?(helper), do: Code.require_file(helper)
    Notary.Conformance.discover_mappings(Mix.Project.config()[:app])
  end

  def conformance_opts(opts), do: Keyword.take(opts, [:seed, :max_runs, :max_steps, :force])

  def finish(report, opts) do
    if opts[:json] do
      json = JSON.encode!(Report.to_json(report))
      path = Path.join(Config.work_dir(), "report.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json)
      IO.puts(json)
    else
      IO.puts(Report.format(report))
    end

    if report.status != :pass, do: exit({:shutdown, 1})
    :ok
  end
end
```

`lib/mix/tasks/notary.check.ex`:
```elixir
defmodule Mix.Tasks.Notary.Check do
  @shortdoc "Model-checks TLA+ specs with TLC"
  @moduledoc """
  Runs TLC on every spec in the specs directory (or only the named ones).

      mix notary.check [Name ...] [--json]

  Exits with status 1 if any spec has a violation or error.
  """
  use Mix.Task

  alias Notary.{CLI, Verify}

  @impl true
  def run(args) do
    {opts, names} = CLI.parse!(args)
    results = Enum.map(CLI.specs!(names), &Verify.check_spec/1)
    CLI.finish(Verify.report(nil, results), opts)
  end
end
```

`lib/mix/tasks/notary.test.ex`:
```elixir
defmodule Mix.Tasks.Notary.Test do
  @shortdoc "Runs conformance tests of the implementation against the specs"
  @moduledoc """
  Builds (or loads the cached) state graph for each spec and drives the
  implementation through generated action sequences via its mapping module.

      mix notary.test [Name ...] [--json] [--seed N] [--max-runs N] [--max-steps N] [--force]

  Runs in the test environment. Requires `test/notary/notary_helper.exs` if your
  app needs setup (e.g. Ecto sandbox mode) before conformance runs.
  """
  use Mix.Task

  alias Notary.{CLI, Verify}

  @impl true
  def run(args) do
    CLI.ensure_test_env!("notary.test")
    {opts, names} = CLI.parse!(args)
    mappings = CLI.load_mappings!()
    results = Enum.map(CLI.specs!(names), &Verify.test_spec(&1, mappings, CLI.conformance_opts(opts)))
    CLI.finish(Verify.report(nil, results), opts)
  end
end
```

`lib/mix/tasks/notary.verify.ex`:
```elixir
defmodule Mix.Tasks.Notary.Verify do
  @shortdoc "Lock check, model check and conformance test for all specs"
  @moduledoc """
  The one command for humans, LLM agents and CI:

      mix notary.verify [--json] [--seed N] [--max-runs N] [--max-steps N] [--force]

  1. Fails if spec files changed since the last `mix notary.lock`.
  2. Model-checks every spec with TLC.
  3. Runs conformance tests through each spec's mapping module.

  With `--json`, the last line of stdout is the JSON report (also written to
  `_build/notary/report.json`).
  """
  use Mix.Task

  alias Notary.{CLI, Config, Verify}

  @impl true
  def run(args) do
    CLI.ensure_test_env!("notary.verify")
    {opts, names} = CLI.parse!(args)
    mappings = CLI.load_mappings!()
    lock = Verify.lock_stage(Config.specs_dir())
    results = Enum.map(CLI.specs!(names), &Verify.test_spec(&1, mappings, CLI.conformance_opts(opts)))
    CLI.finish(Verify.report(lock, results), opts)
  end
end
```

`lib/mix/tasks/notary.lock.ex`:
```elixir
defmodule Mix.Tasks.Notary.Lock do
  @shortdoc "Records the current spec files as reviewed (human step)"
  @moduledoc """
  Writes `specs/.notary.lock` with hashes of every `.tla`/`.cfg` in the specs
  directory. Run this yourself after intentionally changing a spec; LLM agents
  must never run it.

      mix notary.lock [--json]
  """
  use Mix.Task

  alias Notary.{CLI, Config, Lock}

  @impl true
  def run(args) do
    {opts, _} = CLI.parse!(args)
    dir = Config.specs_dir()
    {:ok, files} = Lock.write(dir)

    if opts[:json] do
      IO.puts(JSON.encode!(%{"status" => "pass", "locked" => files}))
    else
      Mix.shell().info(
        "Locked #{length(files)} spec files in #{Path.relative_to_cwd(Lock.path(dir))}:\n" <>
          Enum.map_join(files, "\n", &"  #{&1}")
      )
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c mix test test/mix/tasks/notary_tasks_test.exs --include tlc`
Expected: 7 tests, 0 failures. Then run the whole suite: `nix develop -c mix test --include tlc`, which should be all green.

- [ ] **Step 5: Commit**

```bash
git add lib/notary/verify.ex lib/notary/cli.ex lib/notary/conformance.ex lib/mix/tasks test/mix
git commit -m "feat: notary.check, notary.test, notary.verify and notary.lock tasks"
```

---

### Task 12: `mix notary.install` and `mix notary.new` (scaffolding + LLM rules)

**Files:**
- Create: `lib/notary/scaffold.ex`, `lib/mix/tasks/notary.install.ex`, `lib/mix/tasks/notary.new.ex`
- Create: `priv/templates/spec.tla.eex`, `priv/templates/spec.cfg.eex`, `priv/templates/mapping.ex.eex`, `priv/templates/conformance_test.exs.eex`, `priv/templates/AGENTS.md.eex`
- Test: `test/notary/scaffold_test.exs`

**Interfaces:**
- Consumes: `Notary.Tools.install/1` and `find_java/0`, `Notary.Config.specs_dir/0`, `Notary.Spec.fetch/2`, `Notary.TLC.check/2`.
- Produces:
  - `Scaffold.files(name, specs_dir: rel, app_module: "MyApp", mapping: boolean) :: [{rel_path, content, :create | :create_if_missing}]`
  - `Scaffold.write(files, root \\ File.cwd!()) :: {:ok, [rel_path]} | {:error, conflicts :: [rel_path]}`, which writes nothing on conflict
  - `Scaffold.next_steps(name, mapping?) :: String.t()`
  - Mapping module name `<AppModule>.Specs.<Name>`, at `test/notary/<snake>_spec.ex`, with test file `test/notary/<snake>_conformance_test.exs`

- [ ] **Step 1: Write the templates**

`priv/templates/spec.tla.eex`:
```
---------------------------- MODULE <%= @name %> ----------------------------
\* <%= @name %>: describe the feature this spec models.
\*
\* Notary conventions
\*  - Each disjunct of Next is an action the implementation can be asked to
\*    perform. Its name is the action name used in the mapping module.
\*  - Model the outside world (time passing, an external service failing) as
\*    actions too, e.g. GatewayDown. The mapping drives a stub for them.
\*  - Keep CONSTANTS small in <%= @name %>.cfg: Notary explores every reachable
\*    state and checks the implementation against all of them.
\*  - Variables the implementation cannot expose can be left out of the
\*    mapping's `observe:` list.
EXTENDS Naturals

CONSTANT Max

VARIABLE count

vars == <<count>>

TypeOK == count \in 0..Max

Init == count = 0

Increment == /\ count < Max
             /\ count' = count + 1

Reset == count' = 0

Next == Increment \/ Reset

Spec == Init /\ [][Next]_vars
=============================================================================
```

`priv/templates/spec.cfg.eex`:
```
\* TLC model for <%= @name %>. Keep constants small.
CONSTANT Max = 3
INIT Init
NEXT Next
INVARIANT TypeOK
```

`priv/templates/mapping.ex.eex`:
```elixir
defmodule <%= @module %> do
  @moduledoc """
  Conformance mapping between <%= @spec_path %> and the implementation.

  Written by the implementer (human or LLM) and reviewed by the spec author.
  See `Notary.Conformance` for the callbacks.
  """
  use Notary.Conformance, spec: "<%= @spec_path %>"

  @impl true
  def init do
    # Start the system under test; the returned value is the context passed
    # to action/3 and project/1.
    raise "implement init/0 for <%= @name %>"
  end

  @impl true
  def actions do
    # One entry per spec action: name => StreamData generator of params.
    %{
      "Increment" => StreamData.constant(%{}),
      "Reset" => StreamData.constant(%{})
    }
  end

  @impl true
  def action(_name, _params, _ctx) do
    # Call the implementation. Return {:ok, ctx} if it performed the action,
    # or {:rejected, reason, ctx} if it refused (state must be unchanged).
    raise "implement action/3 for <%= @name %>"
  end

  @impl true
  def project(_ctx) do
    # Map the implementation's state onto the spec's variables, e.g.
    # %{"count" => 0}. Use model/1 and set/1 for model values and sets.
    raise "implement project/1 for <%= @name %>"
  end
end
```

`priv/templates/conformance_test.exs.eex`:
```elixir
defmodule <%= @module %>Test do
  use ExUnit.Case, async: false

  @moduletag :notary

  test "<%= @name %> conforms to its TLA+ spec" do
    Notary.Conformance.assert_conforms(<%= @module %>)
  end
end
```

`priv/templates/AGENTS.md.eex`:
```markdown
# Specs: rules for LLM agents

The `.tla` and `.cfg` files in this directory are **human-authored TLA+
specifications**. They are the contract for what the code must do.

## Never
- Never edit `.tla`, `.cfg` or `.notary.lock` files.
- Never run `mix notary.lock`. Only the human runs it, after reviewing a spec change.
- Never weaken a mapping module (for example by not observing a variable) just
  to make verification pass.

If a spec looks wrong, ambiguous or impossible to implement, stop and ask the human.

## Implementing a spec
1. Read the spec: `Init` is the starting state, and each disjunct of `Next` is
   an action. Guards (the conditions in an action) say when it is allowed.
2. Write the implementation in `lib/`.
3. Complete the mapping module in `test/notary/` (`use Notary.Conformance`):
   `init/0` starts the implementation, `actions/0` lists every action with a
   params generator, `action/3` performs it (returning `{:rejected, reason, ctx}`
   when the implementation refuses, without changing state), and `project/1`
   returns the spec's variables.
4. Run `mix notary.verify --json`. The last line of output is a JSON report.

## When verification fails
- `check` failed: the spec itself has a problem. Report it to the human; do not fix it.
- `conformance` failed: read `failure.kind`, `failure.explanation` and the
  shrunk `failure.steps`. The last step is where the implementation diverged;
  `spec_allowed` lists what the spec permitted there. Fix the **code**.
- For a picture, run `mix notary.graph <Name> --format mermaid --trace failure`.
- Re-run with the reported `--seed` to reproduce.
```

- [ ] **Step 2: Write the failing tests**

`test/notary/scaffold_test.exs`:
```elixir
defmodule Notary.ScaffoldTest do
  use ExUnit.Case, async: false

  alias Notary.Scaffold

  @moduletag :tmp_dir

  defp files(opts \\ []), do: Scaffold.files("CheckoutFlow", Keyword.merge([specs_dir: "specs", app_module: "MyApp"], opts))

  test "generates spec, cfg, AGENTS.md, mapping and test" do
    paths = Enum.map(files(), &elem(&1, 0))

    assert paths == [
             "specs/CheckoutFlow.tla",
             "specs/CheckoutFlow.cfg",
             "specs/AGENTS.md",
             "test/notary/checkout_flow_spec.ex",
             "test/notary/checkout_flow_conformance_test.exs"
           ]

    contents = Map.new(files(), fn {path, content, _} -> {path, content} end)
    assert contents["specs/CheckoutFlow.tla"] =~ "MODULE CheckoutFlow"
    assert contents["test/notary/checkout_flow_spec.ex"] =~ "defmodule MyApp.Specs.CheckoutFlow do"
    assert contents["test/notary/checkout_flow_spec.ex"] =~ ~s(spec: "specs/CheckoutFlow.tla")
    assert contents["specs/AGENTS.md"] =~ "Never edit"
    assert {:ok, _} = Code.string_to_quoted(contents["test/notary/checkout_flow_spec.ex"])
    assert {:ok, _} = Code.string_to_quoted(contents["test/notary/checkout_flow_conformance_test.exs"])
  end

  test "--no-mapping generates only spec files" do
    assert Enum.map(files(mapping: false), &elem(&1, 0)) ==
             ["specs/CheckoutFlow.tla", "specs/CheckoutFlow.cfg", "specs/AGENTS.md"]
  end

  test "write refuses to overwrite, but leaves an existing AGENTS.md alone", %{tmp_dir: root} do
    assert {:ok, written} = Scaffold.write(files(), root)
    assert length(written) == 5
    assert {:error, ["specs/CheckoutFlow.tla" | _]} = Scaffold.write(files(), root)

    File.write!(Path.join(root, "specs/AGENTS.md"), "custom")
    other = Scaffold.files("Other", specs_dir: "specs", app_module: "MyApp")
    assert {:ok, written} = Scaffold.write(other, root)
    refute "specs/AGENTS.md" in written
    assert File.read!(Path.join(root, "specs/AGENTS.md")) == "custom"
  end

  test "next_steps mentions mix.exs setup, the CLAUDE.md snippet and the lock" do
    text = Scaffold.next_steps("CheckoutFlow", true)
    assert text =~ ~s(preferred_envs: ["notary.test": :test, "notary.verify": :test])
    assert text =~ ~s("test/notary")
    assert text =~ "specs/AGENTS.md"
    assert text =~ "mix notary.lock"
  end

  @tag :tlc
  test "the generated spec passes TLC", %{tmp_dir: root} do
    Application.put_env(:notary, :work_dir, Path.join(root, "work"))
    on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
    {:ok, _} = Scaffold.write(files(mapping: false), root)
    {:ok, spec} = Notary.Spec.fetch("CheckoutFlow", Path.join(root, "specs"))
    assert {:ok, %{distinct_states: 4}} = Notary.TLC.check(spec)
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/scaffold_test.exs --include tlc`
Expected: FAIL, `Notary.Scaffold.files/2 is undefined`.

- [ ] **Step 4: Implement**

`lib/notary/scaffold.ex`:
```elixir
defmodule Notary.Scaffold do
  @moduledoc "Generates the files for `mix notary.new`."

  @type file :: {String.t(), String.t(), :create | :create_if_missing}

  @spec files(String.t(), keyword()) :: [file()]
  def files(name, opts) do
    specs_dir = Keyword.fetch!(opts, :specs_dir)
    module = "#{Keyword.fetch!(opts, :app_module)}.Specs.#{name}"
    snake = Macro.underscore(name)
    spec_path = Path.join(specs_dir, "#{name}.tla")
    assigns = [name: name, module: module, spec_path: spec_path]

    spec_files = [
      {spec_path, render("spec.tla.eex", assigns), :create},
      {Path.join(specs_dir, "#{name}.cfg"), render("spec.cfg.eex", assigns), :create},
      {Path.join(specs_dir, "AGENTS.md"), render("AGENTS.md.eex", assigns), :create_if_missing}
    ]

    mapping_files =
      if Keyword.get(opts, :mapping, true) do
        [
          {"test/notary/#{snake}_spec.ex", render("mapping.ex.eex", assigns), :create},
          {"test/notary/#{snake}_conformance_test.exs", render("conformance_test.exs.eex", assigns), :create}
        ]
      else
        []
      end

    spec_files ++ mapping_files
  end

  @spec write([file()], String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def write(files, root \\ File.cwd!()) do
    conflicts = for {path, _, :create} <- files, File.exists?(Path.join(root, path)), do: path

    if conflicts != [] do
      {:error, conflicts}
    else
      written =
        for {path, content, mode} <- files,
            not (mode == :create_if_missing and File.exists?(Path.join(root, path))) do
          full = Path.join(root, path)
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, content)
          path
        end

      {:ok, written}
    end
  end

  @spec next_steps(String.t(), boolean()) :: String.t()
  def next_steps(name, mapping?) do
    mapping_step =
      if mapping?,
        do: "3. Implement it (or ask an LLM to), completing test/notary/#{Macro.underscore(name)}_spec.ex.\n",
        else: "3. When ready to implement, add a mapping module (rerun without --no-mapping for a template).\n"

    """

    Next steps:
    1. Write the spec: specs/#{name}.tla and specs/#{name}.cfg, then `mix notary.check #{name}`.
    2. When you are happy with it, record it as reviewed: `mix notary.lock`.
    #{mapping_step}4. Verify: `mix notary.verify`.

    One-time setup in mix.exs (if not done yet):

        def project do
          [..., elixirc_paths: elixirc_paths(Mix.env())]
        end

        def cli, do: [preferred_envs: ["notary.test": :test, "notary.verify": :test]]

        defp elixirc_paths(:test), do: ["lib", "test/support", "test/notary"]
        defp elixirc_paths(_), do: ["lib"]

    Add to your CLAUDE.md / AGENTS.md so LLM agents follow the rules:

        This project uses Notary (TLA+ specs in specs/). Before implementing or
        changing anything covered by a spec, read specs/AGENTS.md. Never edit
        specs; verify with `mix notary.verify --json`.
    """
  end

  defp render(template, assigns) do
    [:code.priv_dir(:notary), "templates", template] |> Path.join() |> EEx.eval_file(assigns: assigns)
  end
end
```

`lib/mix/tasks/notary.new.ex`:
```elixir
defmodule Mix.Tasks.Notary.New do
  @shortdoc "Scaffolds a new TLA+ spec (and its mapping module)"
  @moduledoc """
      mix notary.new Name [--no-mapping]

  Creates `specs/Name.tla`, `specs/Name.cfg`, `specs/AGENTS.md` (once), and
  unless `--no-mapping`, `test/notary/name_spec.ex` plus a conformance test.
  Never overwrites existing files.
  """
  use Mix.Task

  alias Notary.{Config, Scaffold}

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [no_mapping: :boolean])
    if invalid != [], do: Mix.raise("Unknown option. Usage: mix notary.new Name [--no-mapping]")

    name =
      case argv do
        [name] -> name
        _ -> Mix.raise("Usage: mix notary.new Name [--no-mapping]")
      end

    unless Regex.match?(~r/^[A-Z][A-Za-z0-9]*$/, name),
      do: Mix.raise("Spec name must be CamelCase, like Bank or CheckoutFlow (got #{inspect(name)}).")

    mapping? = not Keyword.get(opts, :no_mapping, false)
    app_module = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    files = Scaffold.files(name, specs_dir: Path.relative_to_cwd(Config.specs_dir()), app_module: app_module, mapping: mapping?)

    case Scaffold.write(files) do
      {:ok, written} ->
        Enum.each(written, &Mix.shell().info("* creating #{&1}"))
        Mix.shell().info(Scaffold.next_steps(name, mapping?))

      {:error, conflicts} ->
        Mix.raise("Refusing to overwrite existing files:\n" <> Enum.map_join(conflicts, "\n", &"  #{&1}"))
    end
  end
end
```

`lib/mix/tasks/notary.install.ex`:
```elixir
defmodule Mix.Tasks.Notary.Install do
  @shortdoc "Downloads the pinned TLA+ tools and checks Java"
  @moduledoc """
      mix notary.install [--force]

  Downloads tla2tools.jar (pinned version, checksum-verified) into
  `_build/notary/` and checks that Java >= 11 is available.
  """
  use Mix.Task

  alias Notary.{Config, Tools}

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean])

    case Tools.install(force: Keyword.get(opts, :force, false)) do
      {:ok, path} -> Mix.shell().info("tla2tools.jar v#{Config.tla_version()} ready at #{Path.relative_to_cwd(path)}")
      {:error, error} -> Mix.raise(error.message)
    end

    case Tools.find_java() do
      {:ok, java} -> Mix.shell().info("Java OK: #{java}")
      {:error, error} -> Mix.shell().error(error.message)
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/scaffold_test.exs --include tlc`
Expected: 5 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/notary/scaffold.ex lib/mix/tasks/notary.new.ex lib/mix/tasks/notary.install.ex priv/templates test/notary/scaffold_test.exs
git commit -m "feat: notary.new scaffolding with LLM rules, and notary.install"
```

---

### Task 13: Viewer (HTML + Mermaid), failure artifacts and `mix notary.graph`

**Files:**
- Create: `lib/notary/viewer.ex`, `lib/notary/viewer/mermaid.ex`, `lib/mix/tasks/notary.graph.ex`
- Create: `priv/viewer/viewer.html.eex`, `priv/viewer/viewer.js`, `priv/viewer/cytoscape.min.js` (vendored), `priv/viewer/VENDOR.md`
- Modify: `lib/notary/verify.ex` (write failure artifacts in `conformance_stage/4`)
- Test: `test/notary/viewer_test.exs`, `test/mix/tasks/notary_graph_test.exs`

**Interfaces:**
- Consumes: `Notary.StateGraph.edges/1`, `Notary.Value.to_tla/1`, `Failure`, the TLC `violation` map, `Notary.Config.work_dir/0`, `Notary.TLC.graph/2` and `check/2`, `Notary.CLI.specs!/1`.
- Produces:
  - `model :: %{title: String.t(), note: String.t() | nil, nodes: [%{id, vars :: %{var => tla_string}, initial :: boolean}], edges: [%{source, target, action}], highlight: [id]}`
  - `Viewer.from_graph(StateGraph.t, opts :: [title:, note:, highlight:]) :: model`
  - `Viewer.from_trace(title, violation) :: model`
  - `Viewer.failure_model(spec_name, graph, Failure.t) :: model`
  - `Viewer.html(model) :: String.t()`
  - `Viewer.write(basename, model) :: path` writes `<work_dir>/<basename>.html`
  - `Viewer.write_failure(spec_name, graph, failure) :: path` writes `<Name>-failure.html` and `<Name>-failure.term`
  - `Viewer.read_failure(spec_name) :: {:ok, Failure.t} | :error`
  - `Mermaid.render(model) :: String.t()`, which emits `stateDiagram-v2` and truncates above 50 states

- [ ] **Step 1: Vendor Cytoscape.js**

```bash
mkdir -p priv/viewer
curl -fsSL -o priv/viewer/cytoscape.min.js https://cdn.jsdelivr.net/npm/cytoscape@3.34.3/dist/cytoscape.min.js
sha256sum priv/viewer/cytoscape.min.js
```
Write `priv/viewer/VENDOR.md`:
```markdown
# Vendored assets

- `cytoscape.min.js`: Cytoscape.js 3.34.3 (MIT), from
  https://cdn.jsdelivr.net/npm/cytoscape@3.34.3/dist/cytoscape.min.js
  sha256: <paste the sha256sum output here>

Inlined into generated viewer HTML so the viewer works offline.
```

- [ ] **Step 2: Write the viewer template and script**

`priv/viewer/viewer.html.eex`:
```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><%= @title %></title>
<style>
:root { --bg:#fbfbfa; --fg:#1f2328; --muted:#6a737d; --panel:#ffffff; --border:#d0d7de; --node:#f3f4f6; --edge:#8c959f; --initial:#1a7f37; --hl:#d9480f; --hl-bg:#fff4e6; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0d1117; --fg:#e6edf3; --muted:#8b949e; --panel:#161b22; --border:#30363d; --node:#21262d; --edge:#6e7681; --initial:#3fb950; --hl:#ff922b; --hl-bg:#3b2410; }
}
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; }
body { display: grid; grid-template-columns: 280px 1fr; grid-template-rows: auto 1fr; height: 100vh; }
header { grid-column: 1 / -1; padding: 10px 16px; border-bottom: 1px solid var(--border); display: flex; gap: 16px; align-items: baseline; flex-wrap: wrap; }
header h1 { font-size: 16px; margin: 0; }
#count, #note { color: var(--muted); }
aside { padding: 12px 16px; border-right: 1px solid var(--border); overflow: auto; background: var(--panel); }
aside h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 16px 0 6px; }
aside label { display: block; padding: 2px 0; font: 12px ui-monospace, monospace; }
#details table { border-collapse: collapse; width: 100%; font: 12px ui-monospace, monospace; }
#details td { border-top: 1px solid var(--border); padding: 4px; vertical-align: top; }
#details td.value { word-break: break-word; }
#graph { min-width: 0; min-height: 0; }
button { font: inherit; padding: 4px 10px; border: 1px solid var(--border); background: var(--node); color: var(--fg); border-radius: 6px; cursor: pointer; }
.hint { color: var(--muted); font-size: 12px; }
@media (max-width: 700px) {
  body { grid-template-columns: 1fr; grid-template-rows: auto auto 1fr; }
  aside { border-right: 0; border-bottom: 1px solid var(--border); max-height: 40vh; }
}
</style>
</head>
<body>
<header><h1><%= @title %></h1><span id="count"></span><span id="note"></span><button id="fit" type="button">Fit</button></header>
<aside>
  <h2>Selected state</h2>
  <div id="details"><p class="hint">Click a state to see its variables.</p></div>
  <h2>Variables</h2>
  <p class="hint">Untick a variable to merge states that agree on the rest.</p>
  <div id="vars"></div>
  <h2>Actions</h2>
  <div id="actions"></div>
  <p class="hint">Large graphs start collapsed: double-click a state to expand its neighbours.</p>
</aside>
<div id="graph"></div>
<script type="application/json" id="notary-data"><%= @data %></script>
<script><%= @cytoscape %></script>
<script><%= @app %></script>
</body>
</html>
```

`priv/viewer/viewer.js`:
```js
(function () {
  "use strict";
  const data = JSON.parse(document.getElementById("notary-data").textContent);
  const BIG = 500;
  const varNames = Array.from(new Set(data.nodes.flatMap((n) => Object.keys(n.vars)))).sort();
  const actions = Array.from(new Set(data.edges.map((e) => e.action))).sort();
  const highlight = new Set(data.highlight);
  const state = { keepVars: new Set(varNames), hiddenActions: new Set(), visible: null };

  const out = new Map();
  const inn = new Map();
  for (const e of data.edges) {
    if (!out.has(e.source)) out.set(e.source, []);
    if (!inn.has(e.target)) inn.set(e.target, []);
    out.get(e.source).push(e);
    inn.get(e.target).push(e);
  }

  if (data.nodes.length > BIG) {
    state.visible = new Set(highlight);
    let frontier = data.nodes.filter((n) => n.initial).map((n) => n.id);
    frontier.forEach((id) => state.visible.add(id));
    for (let depth = 0; depth < 2; depth++) {
      const next = [];
      for (const id of frontier) {
        for (const e of out.get(id) || []) {
          if (!state.visible.has(e.target)) { state.visible.add(e.target); next.push(e.target); }
        }
      }
      frontier = next;
    }
  }

  const collapsed = () => state.keepVars.size < varNames.length;
  const keyOf = (n) => varNames.filter((v) => state.keepVars.has(v)).map((v) => v + "=" + n.vars[v]).join("\u0000");

  function elements() {
    const groups = new Map();
    const groupOf = new Map();
    for (const n of data.nodes) {
      if (state.visible && !state.visible.has(n.id)) continue;
      const gid = collapsed() ? "g:" + keyOf(n) : n.id;
      groupOf.set(n.id, gid);
      let g = groups.get(gid);
      if (!g) {
        g = { id: gid, vars: {}, initial: false, members: 0, highlighted: false };
        for (const v of varNames) if (state.keepVars.has(v)) g.vars[v] = n.vars[v];
        groups.set(gid, g);
      }
      g.members += 1;
      g.initial = g.initial || n.initial;
      g.highlighted = g.highlighted || highlight.has(n.id);
    }
    const els = [];
    for (const g of groups.values()) {
      const lines = Object.entries(g.vars).map(([k, v]) => k + " = " + v);
      if (g.members > 1) lines.push("(" + g.members + " states)");
      const classes = [g.initial ? "initial" : "", g.highlighted ? "hl" : ""].join(" ").trim();
      els.push({ group: "nodes", data: { id: g.id, label: lines.join("\n"), vars: g.vars, members: g.members }, classes });
    }
    const seen = new Set();
    for (const e of data.edges) {
      if (state.hiddenActions.has(e.action)) continue;
      const s = groupOf.get(e.source);
      const t = groupOf.get(e.target);
      if (!s || !t) continue;
      const id = s + "|" + e.action + "|" + t;
      if (seen.has(id)) continue;
      seen.add(id);
      const hl = highlight.has(e.source) && highlight.has(e.target);
      els.push({ group: "edges", data: { id, source: s, target: t, label: e.action }, classes: hl ? "hl" : "" });
    }
    return els;
  }

  const css = getComputedStyle(document.documentElement);
  const color = (name) => css.getPropertyValue(name).trim();
  const lineCount = (ele) => ele.data("label").split("\n").length;
  const longest = (ele) => Math.max(...ele.data("label").split("\n").map((l) => l.length));

  const cy = cytoscape({
    container: document.getElementById("graph"),
    wheelSensitivity: 0.2,
    style: [
      { selector: "node", style: {
        shape: "round-rectangle", label: "data(label)", "text-wrap": "wrap", "text-valign": "center",
        "font-family": "ui-monospace, monospace", "font-size": 10, color: color("--fg"),
        width: (ele) => Math.max(40, longest(ele) * 6.2 + 16), height: (ele) => lineCount(ele) * 13 + 12,
        "background-color": color("--node"), "border-width": 1, "border-color": color("--border") } },
      { selector: "node.initial", style: { "border-width": 3, "border-color": color("--initial") } },
      { selector: "node.hl", style: { "background-color": color("--hl-bg"), "border-color": color("--hl"), "border-width": 3 } },
      { selector: "edge", style: {
        "curve-style": "bezier", "target-arrow-shape": "triangle", label: "data(label)", "font-size": 9,
        color: color("--muted"), "line-color": color("--edge"), "target-arrow-color": color("--edge"),
        "text-background-color": color("--bg"), "text-background-opacity": 1, "text-background-padding": "2px" } },
      { selector: "edge.hl", style: { "line-color": color("--hl"), "target-arrow-color": color("--hl"), width: 3 } }
    ]
  });

  function render() {
    cy.elements().remove();
    cy.add(elements());
    const roots = cy.nodes(".initial");
    cy.layout({ name: "breadthfirst", directed: true, roots: roots.length ? roots : undefined, spacingFactor: 1.1, animate: false }).run();
    document.getElementById("count").textContent = cy.nodes().length + " shown of " + data.nodes.length + " states";
  }

  cy.on("tap", "node", (evt) => {
    const d = evt.target.data();
    const panel = document.getElementById("details");
    panel.replaceChildren();
    const title = document.createElement("p");
    title.textContent = d.members > 1 ? d.members + " merged states" : "One state";
    panel.appendChild(title);
    const table = document.createElement("table");
    for (const [k, v] of Object.entries(d.vars)) {
      const row = table.insertRow();
      row.insertCell().textContent = k;
      const cell = row.insertCell();
      cell.textContent = v;
      cell.className = "value";
    }
    panel.appendChild(table);
  });

  cy.on("dbltap", "node", (evt) => {
    if (!state.visible || collapsed()) return;
    const id = evt.target.id();
    for (const e of (out.get(id) || []).concat(inn.get(id) || [])) {
      state.visible.add(e.source);
      state.visible.add(e.target);
    }
    render();
  });

  function checkboxes(containerId, items, onChange) {
    const box = document.getElementById(containerId);
    for (const item of items) {
      const label = document.createElement("label");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = true;
      input.addEventListener("change", () => { onChange(item, input.checked); render(); });
      label.append(input, " " + item);
      box.appendChild(label);
    }
  }

  checkboxes("vars", varNames, (v, on) => (on ? state.keepVars.add(v) : state.keepVars.delete(v)));
  checkboxes("actions", actions, (a, on) => (on ? state.hiddenActions.delete(a) : state.hiddenActions.add(a)));
  document.getElementById("fit").addEventListener("click", () => cy.fit(undefined, 30));
  if (data.note) document.getElementById("note").textContent = data.note;
  render();
})();
```

- [ ] **Step 3: Write the failing tests**

`test/notary/viewer_test.exs`:
```elixir
defmodule Notary.ViewerTest do
  use ExUnit.Case, async: false

  alias Notary.{Fixtures, Viewer}
  alias Notary.Viewer.Mermaid
  alias Notary.Conformance.{Failure, Step}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :work_dir, dir)
    on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
  end

  test "from_graph renders vars as TLA+ and keeps edges and initial states" do
    graph = Fixtures.graph("Counter")
    model = Viewer.from_graph(graph, title: "Counter", highlight: graph.initial)
    assert length(model.nodes) == 4
    assert Enum.count(model.nodes, & &1.initial) == 1
    assert Enum.all?(model.nodes, &match?(%{vars: %{"x" => x}} when is_binary(x), &1))
    assert length(model.edges) == length(Notary.StateGraph.edges(graph))
    assert model.highlight == graph.initial
  end

  test "html is self-contained and embeds the data safely" do
    model = %{title: "A <b> & </script>", note: nil, nodes: [%{id: "1", vars: %{"s" => ~S("</script>")}, initial: true}], edges: [], highlight: []}
    html = Viewer.html(model)
    assert html =~ "<title>A &lt;b&gt; &amp; &lt;/script&gt;</title>"
    assert html =~ "cytoscape"
    refute html =~ ~r/<script[^>]+src=/
    refute html =~ ~r/<link[^>]+href=/
    [_, json] = Regex.run(~r{<script type="application/json" id="notary-data">(.*?)</script>}s, html)
    assert %{"nodes" => [%{"vars" => %{"s" => ~S("</script>")}}]} = JSON.decode!(String.replace(json, "<\\/", "</"))
  end

  test "from_trace builds a linear path with loop and stutter edges" do
    v = %{
      kind: :liveness, name: nil, message: "Temporal properties were violated.",
      trace: [
        %{index: 1, action: nil, state: %{"x" => 0}},
        %{index: 2, action: "Flip", state: %{"x" => 1}},
        %{index: 1, back_to: 1}
      ]
    }

    model = Viewer.from_trace("Loop", v)
    assert Enum.map(model.nodes, & &1.id) == ["t1", "t2"]
    assert %{source: "t1", target: "t2", action: "Flip"} in model.edges
    assert %{source: "t2", target: "t1", action: "(loop)"} in model.edges
    assert model.highlight == ["t1", "t2"]
  end

  test "write_failure stores html and a readable failure term" do
    graph = Fixtures.graph("Counter")
    [init] = graph.initial
    failure = %Failure{kind: :illegal_transition, seed: 1, steps: [%Step{index: 0, outcome: :ok, projection: %{"x" => 0}, candidates: [init]}]}
    path = Viewer.write_failure("Counter", graph, failure)
    assert Path.basename(path) == "Counter-failure.html"
    assert File.read!(path) =~ "conformance failure"
    assert Viewer.read_failure("Counter") == {:ok, failure}
    assert Viewer.read_failure("Nope") == :error
    assert Viewer.failure_model("Counter", graph, failure).highlight == [init]
  end

  describe "mermaid" do
    test "renders states, initial markers, labelled edges and highlight classes" do
      graph = Fixtures.graph("Counter")
      text = Mermaid.render(Viewer.from_graph(graph, highlight: graph.initial))
      assert text =~ ~r/^stateDiagram-v2\n/
      assert text =~ ~s(state "x = 0" as s)
      assert text =~ ~r/\[\*\] --> s\d+/
      assert text =~ ~r/s\d+ --> s\d+ : Inc/
      assert text =~ "classDef path"
      assert text =~ ~r/class s\d+ path/
    end

    test "escapes quotes and angle brackets" do
      model = %{title: "t", note: nil, nodes: [%{id: "1", vars: %{"l" => ~S(<<"a">>)}, initial: true}], edges: [], highlight: []}
      assert Mermaid.render(model) =~ ~s(state "l = #lt;#lt;#quot;a#quot;#gt;#gt;" as s0)
    end

    test "truncates large graphs to the highlighted path or a BFS prefix" do
      nodes = for i <- 1..60, do: %{id: "#{i}", vars: %{"x" => "#{i}"}, initial: i == 1}
      edges = for i <- 1..59, do: %{source: "#{i}", target: "#{i + 1}", action: "Inc"}
      big = %{title: "t", note: nil, nodes: nodes, edges: edges, highlight: []}

      text = Mermaid.render(big)
      assert text =~ "%% truncated: showing 50 of 60 states"
      assert length(Regex.scan(~r/^    state /m, text)) == 50

      text = Mermaid.render(%{big | highlight: ["5", "6"]})
      assert text =~ "%% truncated: showing 2 highlighted of 60 states"
    end
  end
end
```

`test/mix/tasks/notary_graph_test.exs`:
```elixir
defmodule Mix.Tasks.NotaryGraphTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tlc
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :specs_dir, "test/fixtures/specs")
    Application.put_env(:notary, :work_dir, dir)
    on_exit(fn -> Enum.each([:specs_dir, :work_dir], &Application.delete_env(:notary, &1)) end)
    %{work: dir}
  end

  test "html is the default and is written to the work dir", %{work: work} do
    out = capture_io(fn -> Mix.Task.rerun("notary.graph", ["Counter"]) end)
    assert out =~ "Counter.html"
    assert File.exists?(Path.join(work, "Counter.html"))
  end

  test "mermaid goes to stdout" do
    out = capture_io(fn -> Mix.Task.rerun("notary.graph", ["Workflow", "--format", "mermaid"]) end)
    assert out =~ "stateDiagram-v2"
    assert out =~ ": GatewayDown"
  end

  test "--trace failure without a recorded failure explains what to run" do
    assert_raise Mix.Error, ~r/mix notary.test Counter/, fn ->
      Mix.Task.rerun("notary.graph", ["Counter", "--trace", "failure"])
    end
  end

  test "--trace failure renders a recorded failure" do
    {:ok, graph, _} = Notary.TLC.graph(elem(Notary.Spec.fetch("Counter", "test/fixtures/specs"), 1))
    {:error, failure} = Notary.Conformance.check(Notary.Fixtures.CounterBadResetSpec, graph, seed: 1)
    Notary.Viewer.write_failure("Counter", graph, failure)
    out = capture_io(fn -> Mix.Task.rerun("notary.graph", ["Counter", "--trace", "failure", "--format", "mermaid"]) end)
    assert out =~ "class "
  end

  test "--trace counterexample renders the TLC trace" do
    Application.put_env(:notary, :specs_dir, "test/fixtures/specs_bad")
    out = capture_io(fn -> Mix.Task.rerun("notary.graph", ["Inv", "--trace", "counterexample", "--format", "mermaid"]) end)
    assert out =~ ~s(state "x = 2")
  end
end
```

- [ ] **Step 4: Run them to verify they fail**

Run: `nix develop -c mix test test/notary/viewer_test.exs test/mix/tasks/notary_graph_test.exs --include tlc`
Expected: FAIL, `Notary.Viewer.from_graph/2 is undefined`.

- [ ] **Step 5: Implement**

`lib/notary/viewer.ex`:
```elixir
defmodule Notary.Viewer do
  @moduledoc """
  Builds viewer models from state graphs, TLC counterexamples and conformance
  failures, and renders them as a self-contained interactive HTML page.
  """

  alias Notary.{Config, StateGraph, Value}
  alias Notary.Conformance.Failure

  @type model :: %{
          title: String.t(),
          note: String.t() | nil,
          nodes: [%{id: String.t(), vars: %{String.t() => String.t()}, initial: boolean()}],
          edges: [%{source: String.t(), target: String.t(), action: String.t()}],
          highlight: [String.t()]
        }

  @spec from_graph(StateGraph.t(), keyword()) :: model()
  def from_graph(%StateGraph{} = graph, opts \\ []) do
    initial = MapSet.new(graph.initial)

    %{
      title: Keyword.get(opts, :title, "State graph"),
      note: Keyword.get(opts, :note),
      nodes: for({id, vars} <- Enum.sort(graph.states), do: %{id: id, vars: render_vars(vars), initial: MapSet.member?(initial, id)}),
      edges: for({from, action, to} <- StateGraph.edges(graph), do: %{source: from, target: to, action: action}),
      highlight: Keyword.get(opts, :highlight, [])
    }
  end

  @spec from_trace(String.t(), map()) :: model()
  def from_trace(title, %{trace: trace} = violation) do
    states = Enum.filter(trace, &Map.has_key?(&1, :state))
    nodes = Enum.map(states, &%{id: "t#{&1.index}", vars: render_vars(&1.state), initial: &1.index == 1})

    forward =
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> %{source: "t#{a.index}", target: "t#{b.index}", action: b.action || "?"} end)

    last = states |> List.last() |> then(&"t#{&1.index}")

    extra =
      Enum.flat_map(trace, fn
        %{back_to: n} -> [%{source: last, target: "t#{n}", action: "(loop)"}]
        %{stuttering: true} -> [%{source: last, target: last, action: "(stutter)"}]
        _ -> []
      end)

    %{title: title, note: violation.message, nodes: nodes, edges: forward ++ extra, highlight: Enum.map(nodes, & &1.id)}
  end

  @spec failure_model(String.t(), StateGraph.t(), Failure.t()) :: model()
  def failure_model(spec_name, graph, %Failure{} = failure) do
    highlight = failure.steps |> Enum.flat_map(& &1.candidates) |> Enum.uniq()
    last = List.last(failure.steps)

    note =
      "#{failure.kind} at step #{last && last.index}: implementation state " <>
        "#{last && Notary.Report.format_state(last.projection)}. Highlighted: spec states the run passed through."

    from_graph(graph, title: "#{spec_name}: conformance failure (#{failure.kind})", note: note, highlight: highlight)
  end

  @spec html(model()) :: String.t()
  def html(model) do
    data = model |> JSON.encode!() |> String.replace("</", "<\\/")

    EEx.eval_file(asset("viewer.html.eex"),
      assigns: [
        title: escape_html(model.title),
        data: data,
        cytoscape: inline_js(asset("cytoscape.min.js")),
        app: inline_js(asset("viewer.js"))
      ]
    )
  end

  @spec write(String.t(), model()) :: String.t()
  def write(basename, model) do
    path = Path.join(Config.work_dir(), basename <> ".html")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, html(model))
    path
  end

  @spec write_failure(String.t(), StateGraph.t(), Failure.t()) :: String.t()
  def write_failure(spec_name, graph, %Failure{} = failure) do
    File.mkdir_p!(Config.work_dir())
    File.write!(failure_term_path(spec_name), :erlang.term_to_binary(failure))
    write(spec_name <> "-failure", failure_model(spec_name, graph, failure))
  end

  @spec read_failure(String.t()) :: {:ok, Failure.t()} | :error
  def read_failure(spec_name) do
    case File.read(failure_term_path(spec_name)) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _} -> :error
    end
  end

  defp failure_term_path(spec_name), do: Path.join(Config.work_dir(), spec_name <> "-failure.term")

  defp render_vars(vars), do: Map.new(vars, fn {k, v} -> {k, Value.to_tla(v)} end)

  defp asset(name), do: Path.join([:code.priv_dir(:notary), "viewer", name])

  defp inline_js(path), do: path |> File.read!() |> String.replace("</script", "<\\/script")

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
```

`lib/notary/viewer/mermaid.ex`:
```elixir
defmodule Notary.Viewer.Mermaid do
  @moduledoc """
  Renders a viewer model as a Mermaid `stateDiagram-v2`, which displays inline in
  GitHub and markdown and is easy for LLMs to read. Above #{50} states, only the
  highlighted path (or a breadth-first prefix from the initial states) is shown.
  """

  @max 50

  @spec render(Notary.Viewer.model()) :: String.t()
  def render(model) do
    {nodes, note} = select(model)
    alias_of = nodes |> Enum.with_index() |> Map.new(fn {n, i} -> {n.id, "s#{i}"} end)
    shown = Map.keys(alias_of) |> MapSet.new()

    lines =
      ["stateDiagram-v2"] ++
        if(note, do: ["    %% #{note}"], else: []) ++
        Enum.map(nodes, &~s(    state "#{label(&1)}" as #{alias_of[&1.id]})) ++
        for(n <- nodes, n.initial, do: "    [*] --> #{alias_of[n.id]}") ++
        for(
          e <- model.edges,
          MapSet.member?(shown, e.source) and MapSet.member?(shown, e.target),
          do: "    #{alias_of[e.source]} --> #{alias_of[e.target]} : #{e.action}"
        ) ++ highlight_lines(model.highlight, alias_of)

    Enum.join(lines, "\n") <> "\n"
  end

  defp select(%{nodes: nodes}) when length(nodes) <= @max, do: {nodes, nil}

  defp select(%{nodes: nodes, highlight: [_ | _] = highlight}) do
    wanted = MapSet.new(highlight)
    picked = Enum.filter(nodes, &MapSet.member?(wanted, &1.id)) |> Enum.take(@max)
    {picked, "truncated: showing #{length(picked)} highlighted of #{length(nodes)} states"}
  end

  defp select(%{nodes: nodes, edges: edges}) do
    by_id = Map.new(nodes, &{&1.id, &1})
    out = Enum.group_by(edges, & &1.source, & &1.target)
    start = nodes |> Enum.filter(& &1.initial) |> Enum.map(& &1.id)
    ids = bfs(start, out, MapSet.new(start), start)
    {Enum.map(ids, &by_id[&1]), "truncated: showing #{length(ids)} of #{length(nodes)} states (breadth-first from the initial states)"}
  end

  defp bfs(_frontier, _out, _seen, acc) when length(acc) >= @max, do: Enum.take(acc, @max)
  defp bfs([], _out, _seen, acc), do: acc

  defp bfs(frontier, out, seen, acc) do
    next = frontier |> Enum.flat_map(&Map.get(out, &1, [])) |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))
    bfs(next, out, MapSet.union(seen, MapSet.new(next)), acc ++ next)
  end

  defp highlight_lines([], _alias_of), do: []

  defp highlight_lines(highlight, alias_of) do
    aliases = highlight |> Enum.map(&alias_of[&1]) |> Enum.reject(&is_nil/1)
    if aliases == [], do: [], else: ["    classDef path stroke-width:3px,stroke:#d9480f", "    class #{Enum.join(aliases, ",")} path"]
  end

  defp label(node) do
    node.vars
    |> Enum.sort()
    |> Enum.map_join("<br/>", fn {k, v} -> escape("#{k} = #{v}") end)
  end

  defp escape(text) do
    text
    |> String.replace("\"", "#quot;")
    |> String.replace("<", "#lt;")
    |> String.replace(">", "#gt;")
  end
end
```

`lib/mix/tasks/notary.graph.ex`:
```elixir
defmodule Mix.Tasks.Notary.Graph do
  @shortdoc "Renders a spec's state graph as an interactive HTML page or Mermaid"
  @moduledoc """
      mix notary.graph Name [--format html|mermaid] [--trace failure|counterexample] [--open]

    * no `--trace`: the full reachable state graph
    * `--trace failure`: the last conformance failure recorded by `mix notary.test`
    * `--trace counterexample`: TLC's counterexample for a failing spec

  HTML is written to `_build/notary/`; Mermaid is printed to stdout.
  """
  use Mix.Task

  alias Notary.{CLI, TLC, Viewer}
  alias Notary.Viewer.Mermaid

  @usage "Usage: mix notary.graph Name [--format html|mermaid] [--trace failure|counterexample] [--open]"

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [format: :string, trace: :string, open: :boolean])
    if invalid != [], do: Mix.raise(@usage)

    name =
      case argv do
        [name] -> name
        _ -> Mix.raise(@usage)
      end

    [spec] = CLI.specs!([name])
    {basename, model} = model!(spec, opts[:trace])

    case Keyword.get(opts, :format, "html") do
      "html" ->
        path = Viewer.write(basename, model)
        Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
        if opts[:open], do: open(path)

      "mermaid" ->
        IO.write(Mermaid.render(model))

      other ->
        Mix.raise("Unknown --format #{other}. #{@usage}")
    end
  end

  defp model!(spec, nil) do
    case TLC.graph(spec) do
      {:ok, graph, _} -> {spec.name, Viewer.from_graph(graph, title: "#{spec.name} state graph")}
      {:violation, _} -> Mix.raise("#{spec.name} fails model checking, so there is no complete graph. Use --trace counterexample.")
      {:error, error} -> Mix.raise(error.message)
    end
  end

  defp model!(spec, "failure") do
    with {:ok, failure} <- Viewer.read_failure(spec.name),
         {:ok, graph, _} <- TLC.graph(spec) do
      {spec.name <> "-failure", Viewer.failure_model(spec.name, graph, failure)}
    else
      :error -> Mix.raise("No recorded conformance failure for #{spec.name}. Run `mix notary.test #{spec.name}` first.")
      {:violation, _} -> Mix.raise("#{spec.name} fails model checking. Use --trace counterexample.")
      {:error, error} -> Mix.raise(error.message)
    end
  end

  defp model!(spec, "counterexample") do
    case TLC.check(spec) do
      {:violation, v} -> {spec.name <> "-counterexample", Viewer.from_trace("#{spec.name}: counterexample", v)}
      {:ok, _} -> Mix.raise("#{spec.name} passes model checking; there is no counterexample.")
      {:error, error} -> Mix.raise(error.message)
    end
  end

  defp model!(_spec, other), do: Mix.raise("Unknown --trace #{other}. #{@usage}")

  defp open(path) do
    command =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:win32, _} -> "explorer"
        _ -> "xdg-open"
      end

    System.cmd(command, [path], stderr_to_stdout: true)
  end
end
```

Modify `lib/notary/verify.ex` (in `conformance_stage/4`) so failures are recorded for `--trace failure`:
```elixir
          {:error, %Failure{} = failure} ->
            Notary.Viewer.write_failure(spec.name, graph, failure)
            stage(:conformance, :fail, {:error, failure})
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `nix develop -c mix test test/notary/viewer_test.exs test/mix/tasks/notary_graph_test.exs --include tlc`
Expected: 9 + 5 tests, 0 failures. Then open a viewer once by hand: `nix develop -c mix run -e 'Application.put_env(:notary, :specs_dir, "test/fixtures/specs"); Mix.Task.run("notary.graph", ["Workflow", "--open"])'`. Check that pan/zoom works, that clicking a state shows its variables, that unticking `gateway` merges states, and that unticking an action hides its edges. Check it in both a light and a dark OS theme.

- [ ] **Step 7: Commit**

```bash
git add lib/notary/viewer.ex lib/notary/viewer lib/mix/tasks/notary.graph.ex lib/notary/verify.ex priv/viewer test/notary/viewer_test.exs test/mix/tasks/notary_graph_test.exs
git commit -m "feat: interactive HTML and Mermaid state-graph viewer"
```

---

### Task 14: End-to-end consumer project and README

**Files:**
- Create: `e2e/sample_app/mix.exs`, `e2e/sample_app/config/config.exs`, `e2e/sample_app/lib/sample_app/counter.ex`, `e2e/sample_app/buggy/counter.ex`, `e2e/sample_app/specs/Counter.tla`, `e2e/sample_app/specs/Counter.cfg`, `e2e/sample_app/test/test_helper.exs`, `e2e/sample_app/test/notary/counter_spec.ex`, `e2e/sample_app/test/notary/counter_conformance_test.exs`
- Create: `test/e2e_test.exs`, `README.md`

The sample app lives in `e2e/`, outside `test/`, so Notary's own `mix test` doesn't pick up its `_test.exs` files.

**Interfaces:**
- Consumes: every mix task, exactly as a user's project would.

- [ ] **Step 1: Write the sample app**

`e2e/sample_app/mix.exs`:
```elixir
defmodule SampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:notary, path: System.get_env("NOTARY_PATH", "../.."), only: [:dev, :test]}]
    ]
  end

  def cli, do: [preferred_envs: ["notary.test": :test, "notary.verify": :test]]

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/notary"]
  defp elixirc_paths(_), do: ["lib"]
end
```

`e2e/sample_app/config/config.exs`:
```elixir
import Config

if jar = System.get_env("NOTARY_TLA2TOOLS") do
  config :notary, tla2tools_path: jar
end
```

`e2e/sample_app/lib/sample_app/counter.ex`:
```elixir
defmodule SampleApp.Counter do
  use Agent

  @max 3

  def start_link, do: Agent.start_link(fn -> 0 end)

  def inc(pid) do
    Agent.get_and_update(pid, fn
      x when x < @max -> {:ok, x + 1}
      x -> {{:error, :at_max}, x}
    end)
  end

  def reset(pid), do: Agent.update(pid, fn _ -> 0 end)
  def value(pid), do: Agent.get(pid, & &1)
end
```

`e2e/sample_app/buggy/counter.ex` (copied over the real one by the e2e test):
```elixir
defmodule SampleApp.Counter do
  use Agent

  def start_link, do: Agent.start_link(fn -> 0 end)

  # Bug: no upper bound.
  def inc(pid), do: Agent.update(pid, &(&1 + 1))

  def reset(pid), do: Agent.update(pid, fn _ -> 0 end)
  def value(pid), do: Agent.get(pid, & &1)
end
```

`e2e/sample_app/specs/Counter.tla` and `Counter.cfg`: identical to `test/fixtures/specs/Counter.tla` and `Counter.cfg` from Task 7 (copy the files).

`e2e/sample_app/test/test_helper.exs`:
```elixir
ExUnit.start()
```

`e2e/sample_app/test/notary/counter_spec.ex`:
```elixir
defmodule SampleApp.Specs.Counter do
  use Notary.Conformance, spec: "specs/Counter.tla"

  alias SampleApp.Counter

  @impl true
  def init, do: Counter.start_link()

  @impl true
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Reset" => StreamData.constant(%{})}

  @impl true
  def action("Inc", _, pid) do
    case Counter.inc(pid) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:rejected, reason, pid}
    end
  end

  def action("Reset", _, pid) do
    Counter.reset(pid)
    {:ok, pid}
  end

  @impl true
  def project(pid), do: %{"x" => Counter.value(pid)}
end
```

`e2e/sample_app/test/notary/counter_conformance_test.exs`:
```elixir
defmodule SampleApp.Specs.CounterTest do
  use ExUnit.Case, async: false

  test "Counter conforms to its TLA+ spec" do
    Notary.Conformance.assert_conforms(SampleApp.Specs.Counter)
  end
end
```

- [ ] **Step 2: Write the e2e test**

`test/e2e_test.exs`:
```elixir
defmodule Notary.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  setup %{tmp_dir: tmp} do
    app = Path.join(tmp, "sample_app")
    File.cp_r!("e2e/sample_app", app)
    File.rm_rf!(Path.join(app, "_build"))
    File.rm_rf!(Path.join(app, "deps"))
    env = [{"NOTARY_PATH", File.cwd!()}, {"NOTARY_TLA2TOOLS", Notary.Config.jar_path()}, {"MIX_ENV", nil}]
    ctx = %{app: app, env: env}
    {_, 0} = mix(ctx, ["deps.get"])
    ctx
  end

  defp mix(ctx, args), do: System.cmd("mix", args, cd: ctx.app, env: ctx.env, stderr_to_stdout: true)
  defp last_json(out), do: out |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

  test "the full human + LLM workflow in a consumer project", ctx do
    {out, 0} = mix(ctx, ["notary.lock"])
    assert out =~ "Locked 2 spec files"

    {out, 0} = mix(ctx, ["notary.verify", "--json"])
    assert %{"status" => "pass"} = last_json(out)

    {out, 0} = mix(ctx, ["test"])
    assert out =~ "1 test, 0 failures"

    File.cp!(Path.join(ctx.app, "buggy/counter.ex"), Path.join(ctx.app, "lib/sample_app/counter.ex"))
    {out, 1} = mix(ctx, ["notary.verify", "--json"])
    %{"specs" => [%{"stages" => [_, conf]}]} = last_json(out)
    assert conf["failure"]["kind"] == "action_not_enabled"
    assert length(conf["failure"]["steps"]) == 5
    assert File.exists?(Path.join(ctx.app, "_build/notary/Counter-failure.html"))

    {out, 0} = mix(ctx, ["notary.graph", "Counter", "--trace", "failure", "--format", "mermaid"])
    assert out =~ "stateDiagram-v2"

    spec = Path.join(ctx.app, "specs/Counter.tla")
    File.write!(spec, File.read!(spec) <> "\n\\* an LLM was here\n")
    {out, 1} = mix(ctx, ["notary.verify"])
    assert out =~ "changed: Counter.tla"

    {out, 0} = mix(ctx, ["notary.new", "Thing"])
    assert out =~ "creating specs/Thing.tla"
    assert out =~ "creating specs/AGENTS.md"
    {out, 0} = mix(ctx, ["notary.check", "Thing"])
    assert out =~ "Thing: pass"
  end
end
```

- [ ] **Step 3: Run it**

Run: `nix develop -c mix test test/e2e_test.exs --include e2e`
Expected: 1 test, 0 failures. It takes a few minutes, because it compiles a fresh project and runs TLC several times. If `deps.get` fails offline, that's expected: `:e2e` needs network for `stream_data`.

- [ ] **Step 4: Write `README.md`**

````markdown
# Notary

> Any behavior not in the spec is uncertified.

Notary makes **TLA+ specifications the contract between you and an LLM** in
Elixir projects. You write the spec. TLC model-checks it. The LLM implements it.
Notary then proves the implementation behaves like the spec, by driving it
through generated action sequences and checking every step against the spec's
full state graph.

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
mix notary.install      # pinned tla2tools.jar; needs Java >= 11 (or use this repo's nix flake)
```

## Workflow

| Who | Step |
|---|---|
| You | `mix notary.new Checkout`, then write `specs/Checkout.tla` and `.cfg` |
| You | `mix notary.check Checkout` until TLC is happy, then `mix notary.lock` |
| LLM | Implement it in `lib/`, and complete `test/notary/checkout_spec.ex` |
| LLM / CI | `mix notary.verify --json` (lock check, model check, conformance) |

`specs/AGENTS.md` tells agents the rules: specs are yours, and agents never
edit them. If a spec changes without `mix notary.lock`, verification fails.

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
  state unchanged. Notary checks guards too.
- Model the outside world (time, failing services) as spec actions, and have
  the mapping drive a stub.

## Seeing the state space

```bash
mix notary.graph Bank --open                      # interactive HTML
mix notary.graph Bank --trace failure --open      # where the last conformance run diverged
mix notary.graph Bank --format mermaid            # for PRs and LLMs
```

## Limits (v1)

Actions are driven sequentially, so code-level races are not exercised. TLC
still checks the design across all interleavings. Liveness is checked only on
the spec. Keep `.cfg` constants small.

## Developing Notary

```bash
nix develop
mix deps.get && mix run -e 'Notary.Tools.install()'
mix test --include tlc                 # add --include e2e for the end-to-end test
mix run test/fixtures/regen_graphs.exs # after changing fixture specs
```
````

- [ ] **Step 5: Run the full suite and commit**

```bash
nix develop -c mix format --check-formatted
nix develop -c mix compile --warnings-as-errors
nix develop -c mix test --include tlc --include network --include e2e
git add -A
git commit -m "test: end-to-end consumer project; docs: README"
```
Expected: no formatting diffs, no warnings, and all tests pass. If `mix format --check-formatted` reports diffs, run `mix format` and include the result in the commit.

---

## Out of scope for this plan

These are covered by later plans:
- **Phase 1.5:** Notary's own `specs/` (TLCRunner lifecycle, cache and lock protocol), and CI that runs the fixture suite before self-verification.
- **Phase 2:** LiveView conformance, written spec-first. That includes adding Postgres to the flake for the Ecto sandbox helpers.
