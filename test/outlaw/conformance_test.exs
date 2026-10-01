defmodule Outlaw.ConformanceTest do
  use ExUnit.Case, async: true

  alias Outlaw.{Conformance, Fixtures}
  alias Outlaw.Conformance.Failure

  test "__outlaw__/0 records the mapping options" do
    assert Fixtures.BankSpec.__outlaw__() ==
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
    assert {:error, %Outlaw.Error{kind: :invalid_mapping, message: msg}} =
             Conformance.validate(Fixtures.CounterUnknownActionSpec, Fixtures.graph("Counter"))

    assert msg =~ "Decrement"
    assert msg =~ "nope"
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
