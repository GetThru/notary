defmodule Outlaw.DiagnosticTest.CrashedMapping do
  @moduledoc false
  # A mapping whose action kills its own (already-spawned, unlinked) worker
  # process -- the runner observes this as `:crashed`, not `:exception`
  # (there's nothing to rescue; the process just dies). Used by the
  # "crashed points at ..." test below, which needs a real, located `:crashed`
  # failure (`Outlaw.Mapping.Locate` resolves to this very file).
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, _pid), do: Process.exit(self(), :kill)
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Outlaw.Conformance.{Failure, Step}
  alias Outlaw.{Conformance, Diagnostic, Fixtures, Spec, TLC}
  alias Outlaw.DiagnosticTest.CrashedMapping

  @counter_spec Spec.from_path("test/fixtures/specs/Counter.tla")
  @async_spec Spec.from_path("test/fixtures/specs/Async.tla")
  @workflow_spec Spec.from_path("test/fixtures/specs/Workflow.tla")

  defp check(module, graph_name, opts) do
    Conformance.check(
      module,
      Fixtures.graph(graph_name),
      Keyword.merge([seed: 42, max_runs: 200], opts)
    )
  end

  defp render(module, graph_name, opts \\ [], spec \\ @counter_spec) do
    {:error, failure} = check(module, graph_name, opts)

    failure
    |> Diagnostic.failure(spec: spec, mapping: module)
    |> Diagnostic.render(colors: false)
  end

  test "action_not_enabled points at the guard conjunct's expression (not the leading /\\), with the pre-action state" do
    text = render(Fixtures.CounterNoGuardSpec, "Counter")

    assert text =~ "error[action_not_enabled]"
    assert text =~ "Inc was accepted, but the spec doesn't allow it in x = 3"
    assert text =~ "test/fixtures/specs/Counter.tla:10:11"
    assert text =~ "Inc == /\\ x < Max"
    assert text =~ "false here: x = 3"
    assert text =~ "help: return {:rejected, reason, ctx}"
  end

  test "action_not_offered points at the guard that made it enabled and names the selector" do
    text = render(Fixtures.CounterNotOfferedSpec, "Counter")

    assert text =~ "error[action_not_offered]"
    assert text =~ "Inc was not offered, but the spec allows it in x = "
    assert text =~ "test/fixtures/specs/Counter.tla:10:11"
    assert text =~ "true here: x = "
    assert text =~ "help: the UI must offer Inc here; \"#inc\" was missing or disabled"
  end

  test "illegal_transition falls back to the Reset == line when the body has no /\\ list" do
    text = render(Fixtures.CounterBadResetSpec, "Counter")

    assert text =~ "error[illegal_transition]"
    assert text =~ "Reset reached a state the spec doesn't allow"
    assert text =~ "test/fixtures/specs/Counter.tla:13:1"
    assert text =~ "Reset == x' = 0"
    assert text =~ "implementation reached x = 1"
    assert text =~ "note: spec allowed: x = 0"
  end

  test "rejected_with_side_effect points at the action's name" do
    text = render(Fixtures.CounterSideEffectSpec, "Counter")

    assert text =~ "error[rejected_with_side_effect]"
    assert text =~ "Inc was rejected, but the state changed"
    assert text =~ "test/fixtures/specs/Counter.tla:10:1"
    assert text =~ "rejected, but the state changed x = 3 → x = 0"
  end

  test "init_mismatch points at Init's definition with the spec's initial states" do
    text = render(Fixtures.CounterBadInitSpec, "Counter")

    assert text =~ "error[init_mismatch]"
    assert text =~ "The initial state isn't one the spec allows"
    assert text =~ "test/fixtures/specs/Counter.tla:8:1"
    assert text =~ "Init == x = 0"
    assert text =~ "implementation starts at x = 7"
    assert text =~ "note: spec's initial states: x = 0"
  end

  test "internal_action_stalled points at the pending action's definition and its WF_ occurrence" do
    text = render(Fixtures.AsyncStalledSpec, "Async", [settle_timeout: 50], @async_spec)

    assert text =~ "error[internal_action_stalled]"
    assert text =~ "Complete never happened, but the spec requires it (fairness)"
    assert text =~ "test/fixtures/specs/Async.tla"
    assert text =~ "Complete == /\\ status = \"pending\""
    assert text =~ "WF_status(Complete)"
    assert text =~ "fairness requires this to happen"
  end

  test "invalid_projection points at def project in the mapping module" do
    text = render(Fixtures.CounterBadProjectionSpec, "Counter")

    assert text =~ "error[invalid_projection]"
    assert text =~ "project/1 returned the wrong variables/values"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def project(_pid), do: %{\"x\" => 0, \"extra\" => 1}"
    assert text =~ "help: expected variables: x; got: extra, x"
  end

  test "exception points at the raising line in the mapping module, with the exception message as a note" do
    text = render(Fixtures.CounterRaisingSpec, "Counter")

    assert text =~ "error[exception]"
    assert text =~ "Inc raised RuntimeError"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def action(\"Inc\", _, _pid), do: raise(\"boom\")"
    assert text =~ "note: ** (RuntimeError) boom"
  end

  test "timeout points at the matching def action clause" do
    text = render(Fixtures.CounterSlowSpec, "Counter", action_timeout: 50, max_runs: 20)

    assert text =~ "error[timeout]"
    assert text =~ "action/3 Inc didn't return within 50 ms"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def action(\"Inc\", _, pid) do"
  end

  test "timeout during settling points at def project, with a softer message than \"timed out here\"" do
    failure = %Failure{
      kind: :timeout,
      seed: 1,
      steps: [%Step{index: 0, outcome: :ok, projection: %{"x" => 0}, allowed: [%{"x" => 0}]}],
      details: %{during: "settle", timeout: 500}
    }

    text =
      failure
      |> Diagnostic.failure(spec: @counter_spec, mapping: Fixtures.CounterSpec)
      |> Diagnostic.render(colors: false)

    assert text =~ "error[timeout]"
    assert text =~ "settling (project/1) didn't return within 500 ms"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def project(pid), do: %{\"x\" => Counter.value(pid)}"
    assert text =~ "settling (polling project/1) timed out"
    refute text =~ "timed out here"
  end

  test "invalid_action_result points at def init when init/0 doesn't return {:ok, ctx}" do
    text = render(Fixtures.CounterBadInitResultSpec, "Counter")

    assert text =~ "error[invalid_action_result]"
    assert text =~ "init/0 returned an invalid result: got :ok"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def init, do: :ok"
  end

  test "crashed points at the matching def action clause" do
    text = render(CrashedMapping, "Counter")

    assert text =~ "error[crashed]"
    assert text =~ "the implementation process crashed during action/3 Inc"
    assert text =~ "test/outlaw/diagnostic_test.exs"
    assert text =~ "def action(\"Inc\", _, _pid), do: Process.exit(self(), :kill)"
  end

  test "action_not_enabled with several guard conjuncts labels each one, never claiming which is false" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "outlaw_diag_several_guards_#{System.unique_integer([:positive])}.tla"
      )

    File.write!(tmp, """
    ---- MODULE Temp ----
    VARIABLE x
    Init == x = 0
    Act == /\\ a
           /\\ b
           /\\ x' = x + 1
    Next == Act
    ====
    """)

    on_exit(fn -> File.rm(tmp) end)

    spec = Spec.from_path(tmp)

    failure = %Failure{
      kind: :action_not_enabled,
      seed: 1,
      steps: [
        %Step{index: 0, outcome: :ok, projection: %{"x" => 0}, allowed: [%{"x" => 0}]},
        %Step{index: 1, action: "Act", outcome: :ok, projection: %{"x" => 1}, allowed: []}
      ]
    }

    text =
      failure
      |> Diagnostic.failure(spec: spec, mapping: nil)
      |> Diagnostic.render(colors: false)

    assert text =~ "Act was accepted, but the spec doesn't allow it in x = 0"
    refute text =~ "false here"
    # One label per guard conjunct, not a single merged span -- both carry
    # the same "never claim which one" wording.
    assert length(:binary.matches(text, "one of these is false in x = 0")) == 2
    # Each conjunct gets its own underline/branch pair (pentiment renders
    # sensibly: no merged or collided labels across the two guard lines).
    assert length(:binary.matches(text, "╰── one of these is false in x = 0")) == 2
    assert text =~ "/\\ a"
    assert text =~ "/\\ b"
  end

  test "illegal_transition labels every effect conjunct when an action has several" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "outlaw_diag_several_effects_#{System.unique_integer([:positive])}.tla"
      )

    File.write!(tmp, """
    ---- MODULE Temp ----
    VARIABLE x, y
    Init == x = 0 /\\ y = 0
    Act == /\\ x' = x + 1
           /\\ y' = y + 1
    Next == Act
    ====
    """)

    on_exit(fn -> File.rm(tmp) end)

    spec = Spec.from_path(tmp)

    failure = %Failure{
      kind: :illegal_transition,
      seed: 1,
      steps: [
        %Step{
          index: 0,
          outcome: :ok,
          projection: %{"x" => 0, "y" => 0},
          allowed: [%{"x" => 0, "y" => 0}]
        },
        %Step{
          index: 1,
          action: "Act",
          outcome: :ok,
          projection: %{"x" => 1, "y" => 5},
          allowed: [%{"x" => 1, "y" => 1}]
        }
      ]
    }

    text =
      failure
      |> Diagnostic.failure(spec: spec, mapping: nil)
      |> Diagnostic.render(colors: false)

    assert text =~ "Act reached a state the spec doesn't allow"
    # One label per effect conjunct, each carrying the same "implementation
    # reached ..." message -- never claiming which effect is wrong.
    assert length(:binary.matches(text, "implementation reached x = 1, y = 5")) == 2
    assert text =~ "/\\ x' = x + 1"
    assert text =~ "/\\ y' = y + 1"
    assert text =~ "note: spec allowed: x = 1, y = 1"
  end

  test "illegal_transition on Ship(u): UNCHANGED gateway is labelled as an effect when the implementation changes it" do
    failure = %Failure{
      kind: :illegal_transition,
      seed: 1,
      steps: [
        %Step{
          index: 0,
          outcome: :ok,
          projection: %{"status" => "paid", "gateway" => "up"},
          allowed: [%{"status" => "paid", "gateway" => "up"}]
        },
        %Step{
          index: 1,
          action: "Ship",
          outcome: :ok,
          projection: %{"status" => "shipped", "gateway" => "down"},
          allowed: []
        }
      ]
    }

    text =
      failure
      |> Diagnostic.failure(spec: @workflow_spec, mapping: nil)
      |> Diagnostic.render(colors: false)

    assert text =~ "error[illegal_transition]"
    assert text =~ "Ship reached a state the spec doesn't allow"
    assert text =~ "/\\ status' = [status EXCEPT ![u] = \"shipped\"]"
    assert text =~ "/\\ UNCHANGED gateway"
    # Both effect conjuncts are labelled, including the one under UNCHANGED
    # (classified as an effect, not a guard -- item 2).
    assert length(
             :binary.matches(
               text,
               ~s(implementation reached gateway = "down", status = "shipped")
             )
           ) == 2
  end

  test "action_not_enabled on Ship(u): only the real guard is labelled, UNCHANGED gateway is not a guard" do
    failure = %Failure{
      kind: :action_not_enabled,
      seed: 1,
      steps: [
        %Step{
          index: 0,
          outcome: :ok,
          projection: %{"status" => "cart", "gateway" => "up"},
          allowed: [%{"status" => "cart", "gateway" => "up"}]
        },
        %Step{
          index: 1,
          action: "Ship",
          outcome: :ok,
          projection: %{"status" => "cart", "gateway" => "up"},
          allowed: []
        }
      ]
    }

    text =
      failure
      |> Diagnostic.failure(spec: @workflow_spec, mapping: nil)
      |> Diagnostic.render(colors: false)

    assert text =~ "error[action_not_enabled]"
    assert text =~ "/\\ status[u] = \"paid\""
    # Exactly one guard conjunct in Ship(u) -- a single "false here" label
    # (not the several-guards "one of these" wording), and the UNCHANGED
    # gateway effect conjunct gets no label of its own.
    assert length(:binary.matches(text, ~s(╰── false here: gateway = "up", status = "cart"))) == 1
  end

  test "invalid_mapping points at the use Outlaw.Conformance line, def actions as secondary, help from the error" do
    module = Fixtures.CounterUnknownActionSpec
    {:error, error} = Conformance.validate(module, Fixtures.graph("Counter"))

    text =
      error
      |> Diagnostic.error(spec: nil, mapping: module)
      |> Diagnostic.render(colors: false)

    assert text =~ "error[invalid_mapping]"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "use Outlaw.Conformance,"
    assert text =~ "╰── use Outlaw.Conformance here"
    assert text =~ "def actions, do: %{\"Inc\" => StreamData.constant"
    assert text =~ "╰── def actions"
    assert text =~ "help:"
    assert text =~ "Decrement"
    assert text =~ "nope"
  end

  test "error/2 returns nil for invalid_mapping when no mapping is given" do
    module = Fixtures.CounterUnknownActionSpec
    {:error, error} = Conformance.validate(module, Fixtures.graph("Counter"))

    assert Diagnostic.error(error, spec: nil, mapping: nil) == nil
  end

  test "error/2 returns nil for spec_error when the location has no module, instead of raising" do
    error =
      Outlaw.Error.new(:spec_error, "TLA+ spec error", %{
        location: %{module: nil, line: 1, column: 1}
      })

    assert Diagnostic.error(error, spec: @counter_spec, mapping: nil) == nil
  end

  describe "spec_error (needs TLC)" do
    @describetag :tlc
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      Application.put_env(:outlaw, :work_dir, Path.join(dir, "work"))
      on_exit(fn -> Application.delete_env(:outlaw, :work_dir) end)
    end

    test "spec_error points at SANY's reported line/column, with the rest of its text as a note" do
      {:ok, spec} = Spec.fetch("Broken", "test/fixtures/specs_bad")
      {:error, error} = TLC.check(spec)

      text =
        error
        |> Diagnostic.error(spec: spec, mapping: nil)
        |> Diagnostic.render(colors: false)

      assert text =~ "error[spec_error]"
      assert text =~ "test/fixtures/specs_bad/Broken.tla:3:9"
      assert text =~ "Init == x ="
      assert text =~ "***Parse Error***"
      assert text =~ "note:"
    end
  end

  test "failure/2 returns nil when the action name can't be located in the spec" do
    failure = %Failure{
      kind: :action_not_enabled,
      seed: 1,
      steps: [
        %Step{index: 0, outcome: :ok, projection: %{"x" => 0}, allowed: [%{"x" => 0}]},
        %Step{
          index: 1,
          action: "NopeNotInSpec",
          outcome: :ok,
          projection: %{"x" => 1},
          allowed: []
        }
      ]
    }

    assert Diagnostic.failure(failure, spec: @counter_spec, mapping: nil) == nil
  end

  test "failure/2 returns nil for kinds needing a mapping when none is given" do
    failure = %Failure{
      kind: :invalid_projection,
      seed: 1,
      steps: [%Step{index: 0, outcome: :ok, projection: %{"x" => 0}, allowed: []}],
      details: %{got: ["extra", "x"], expected: ["x"]}
    }

    assert Diagnostic.failure(failure, spec: @counter_spec, mapping: nil) == nil
  end

  test "render/2 passes nil straight through" do
    assert Diagnostic.render(nil, colors: false) == nil
  end
end
