defmodule Outlaw.ConformanceTest do
  use ExUnit.Case, async: true

  alias Outlaw.{Conformance, Fixtures}
  alias Outlaw.Conformance.Failure

  test "__outlaw__/0 records the mapping options" do
    assert Fixtures.BankSpec.__outlaw__() ==
             %{
               spec_path: "test/fixtures/specs/Bank.tla",
               observe: ["balance"],
               discover: true,
               internal: [],
               generation: :walk
             }

    assert Conformance.spec(Fixtures.BankSpec).name == "Bank"
  end

  test "__outlaw__/0 includes declared internal actions" do
    assert Fixtures.AsyncSpec.__outlaw__() == %{
             spec_path: "test/fixtures/specs/Async.tla",
             observe: nil,
             discover: true,
             internal: ["Complete"],
             generation: :walk
           }
  end

  test "__outlaw__/0 records generation: :uniform when requested" do
    assert Fixtures.CounterUniformSpec.__outlaw__().generation == :uniform
  end

  test "a generation: :uniform mapping passes a check" do
    assert {:ok, %{runs: 50, seed: 42}} =
             Conformance.check(Fixtures.CounterUniformSpec, Fixtures.graph("Counter"),
               seed: 42,
               max_runs: 50
             )
  end

  test "validate rejects a generation: other than :walk or :uniform" do
    assert {:error, %Outlaw.Error{kind: :invalid_mapping, message: msg}} =
             Conformance.validate(Fixtures.CounterBadGenerationSpec, Fixtures.graph("Counter"))

    assert msg =~ "generation:"
    assert msg =~ ":nope"
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
    assert {:error, %Outlaw.Error{kind: :invalid_mapping, message: msg}} =
             Conformance.validate(Fixtures.CounterUnknownActionSpec, Fixtures.graph("Counter"))

    assert msg =~ "Decrement"
    assert msg =~ "nope"
  end

  test "validate rejects an internal action that is not a graph action" do
    assert {:error, %Outlaw.Error{kind: :invalid_mapping, message: msg}} =
             Conformance.validate(Fixtures.AsyncUnknownInternalSpec, Fixtures.graph("Async"))

    assert msg =~ "Nope"
  end

  test "validate rejects an internal action that also appears in actions/0" do
    assert {:error, %Outlaw.Error{kind: :invalid_mapping, message: msg}} =
             Conformance.validate(
               Fixtures.AsyncInternalAlsoExternalSpec,
               Fixtures.graph("Async")
             )

    assert msg =~ "Complete"
  end

  test "internal_actions/1 and fair_internal_actions/1 read the spec's fairness" do
    assert Conformance.internal_actions(Fixtures.AsyncSpec) == ["Complete"]
    assert Conformance.fair_internal_actions(Fixtures.AsyncSpec) == ["Complete"]
  end

  test "TLCRunner's own mapping: Reap is fair (WF_vars(Reap)), LimitKill is not" do
    assert Conformance.internal_actions(Outlaw.Specs.TLCRunner) == ["LimitKill", "Reap"]
    assert Conformance.fair_internal_actions(Outlaw.Specs.TLCRunner) == ["Reap"]
  end

  test "discover_mappings finds discoverable mappings only" do
    mappings = Conformance.discover_mappings(:outlaw)
    assert mappings["Counter"] == Fixtures.CounterSpec
    assert mappings["Bank"] == Fixtures.BankSpec
    assert mappings["Workflow"] == Fixtures.WorkflowSpec
  end

  test "every failure kind has an explanation" do
    for kind <- Failure.kinds(), do: assert(Failure.explanation(kind) =~ ~r/\w/)
  end
end
