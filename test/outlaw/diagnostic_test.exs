defmodule Outlaw.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Outlaw.Conformance.{Failure, Step}
  alias Outlaw.{Conformance, Diagnostic, Fixtures, Spec}

  @counter_spec Spec.from_path("test/fixtures/specs/Counter.tla")
  @async_spec Spec.from_path("test/fixtures/specs/Async.tla")

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

  test "action_not_enabled points at the guard conjunct in the spec, with the pre-action state" do
    text = render(Fixtures.CounterNoGuardSpec, "Counter")

    assert text =~ "error[action_not_enabled]"
    assert text =~ "test/fixtures/specs/Counter.tla:10:8"
    assert text =~ "Inc == /\\ x < Max"
    assert text =~ "false here: x = 3"
    assert text =~ "help: return {:rejected, reason, ctx}"
  end

  test "illegal_transition falls back to the Reset == line when the body has no /\\ list" do
    text = render(Fixtures.CounterBadResetSpec, "Counter")

    assert text =~ "error[illegal_transition]"
    assert text =~ "test/fixtures/specs/Counter.tla:13:1"
    assert text =~ "Reset == x' = 0"
    assert text =~ "implementation reached x = 1"
    assert text =~ "note: spec allowed: x = 0"
  end

  test "rejected_with_side_effect points at the action's name" do
    text = render(Fixtures.CounterSideEffectSpec, "Counter")

    assert text =~ "error[rejected_with_side_effect]"
    assert text =~ "test/fixtures/specs/Counter.tla:10:1"
    assert text =~ "rejected, but the state changed x = 3 → x = 0"
  end

  test "init_mismatch points at Init's definition with the spec's initial states" do
    text = render(Fixtures.CounterBadInitSpec, "Counter")

    assert text =~ "error[init_mismatch]"
    assert text =~ "test/fixtures/specs/Counter.tla:8:1"
    assert text =~ "Init == x = 0"
    assert text =~ "implementation starts at x = 7"
    assert text =~ "note: spec's initial states: x = 0"
  end

  test "internal_action_stalled points at the pending action's definition and its WF_ occurrence" do
    text = render(Fixtures.AsyncStalledSpec, "Async", [settle_timeout: 50], @async_spec)

    assert text =~ "error[internal_action_stalled]"
    assert text =~ "test/fixtures/specs/Async.tla"
    assert text =~ "Complete == /\\ status = \"pending\""
    assert text =~ "WF_status(Complete)"
    assert text =~ "fairness requires this to happen"
  end

  test "invalid_projection points at def project in the mapping module" do
    text = render(Fixtures.CounterBadProjectionSpec, "Counter")

    assert text =~ "error[invalid_projection]"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def project(_pid), do: %{\"x\" => 0, \"extra\" => 1}"
    assert text =~ "help: expected variables: x; got: extra, x"
  end

  test "exception points at the raising line in the mapping module, with the exception message as a note" do
    text = render(Fixtures.CounterRaisingSpec, "Counter")

    assert text =~ "error[exception]"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def action(\"Inc\", _, _pid), do: raise(\"boom\")"
    assert text =~ "note: ** (RuntimeError) boom"
  end

  test "timeout points at the matching def action clause" do
    text = render(Fixtures.CounterSlowSpec, "Counter", action_timeout: 50, max_runs: 20)

    assert text =~ "error[timeout]"
    assert text =~ "test/support/fixtures/counter_specs.ex"
    assert text =~ "def action(\"Inc\", _, pid) do"
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
