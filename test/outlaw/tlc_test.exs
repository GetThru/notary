defmodule Outlaw.TLCTest do
  use ExUnit.Case, async: false

  alias Outlaw.{Cache, Spec, StateGraph, TLC}
  alias Outlaw.Tools.TLCRunner

  test "distinct_states/1 reads progress and final stats lines" do
    assert TLCRunner.distinct_states(
             "14 states generated, 10 distinct states found, 0 states left"
           ) ==
             10

    assert TLCRunner.distinct_states(
             "Progress(4): 2,000 states generated (1 s/min), 1,234 distinct states found"
           ) == 1234

    assert TLCRunner.distinct_states(
             "Finished computing initial states: 1 distinct state generated"
           ) ==
             nil
  end

  describe "with TLC" do
    @describetag :tlc
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      Application.put_env(:outlaw, :work_dir, Path.join(dir, "work"))
      on_exit(fn -> Application.delete_env(:outlaw, :work_dir) end)
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

      assert {:error, %Outlaw.Error{kind: :spec_error, details: %{location: %{line: 3}}}} =
               TLC.check(spec)
    end

    test "two runs in the same second do not collide" do
      {:ok, spec} = Spec.fetch("Counter", "test/fixtures/specs")
      tasks = for _ <- 1..2, do: Task.async(fn -> TLC.check(spec) end)
      assert [{:ok, _}, {:ok, _}] = Task.await_many(tasks, 60_000)
    end

    test "6 concurrent runs of a spec that EXTENDS Naturals do not collide on java.io.tmpdir" do
      # TLC extracts standard modules (Naturals.tla, ...) from the jar into
      # java.io.tmpdir and parses them there; without a per-run -Djava.io.tmpdir
      # pointed at that run's own metadir, concurrent JVMs can overwrite/delete
      # each other's extracted copies mid-parse, intermittently producing a
      # SANY NullPointerException (surfaced as a confusing :spec_error).
      {:ok, spec} = Spec.fetch("Counter", "test/fixtures/specs")
      tasks = for _ <- 1..6, do: Task.async(fn -> TLC.check(spec) end)
      results = Task.await_many(tasks, 120_000)
      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    end

    test "state limit stops TLC" do
      {:ok, spec} = Spec.fetch("Bank", "test/fixtures/specs")
      assert {:error, %Outlaw.Error{kind: :too_many_states}} = TLC.check(spec, max_states: 2)
    end

    test "timeout stops TLC" do
      {:ok, spec} = Spec.fetch("Bank", "test/fixtures/specs")
      assert {:error, %Outlaw.Error{kind: :tlc_timeout}} = TLC.check(spec, timeout: 1)
    end

    test "graph builds, caches and reuses the state graph" do
      {:ok, spec} = Spec.fetch("Workflow", "test/fixtures/specs")
      assert {:ok, graph, %{distinct_states: n}} = TLC.graph(spec)
      assert StateGraph.size(graph) == n
      assert graph.actions == MapSet.new(["Pay", "Ship", "GatewayDown", "GatewayUp"])
      assert {:ok, _} = Cache.get(elem(Cache.key(spec), 1))
      assert {:ok, ^graph, _} = TLC.graph(spec)
    end

    test "graph does not cache failing specs" do
      {:ok, spec} = Spec.fetch("Inv", "test/fixtures/specs_bad")
      assert {:violation, _} = TLC.graph(spec)
      assert Cache.get(elem(Cache.key(spec), 1)) == :miss
    end
  end
end
