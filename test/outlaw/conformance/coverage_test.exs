defmodule Outlaw.Conformance.CoverageTest do
  use ExUnit.Case, async: true

  alias Outlaw.StateGraph
  alias Outlaw.Conformance.{Coverage, Step}

  # A small Counter-shaped graph: 0 --Inc--> 1 --Inc--> 2, and Reset from
  # every state back to 0 (0's Reset is a self-loop).
  defp line_graph do
    %StateGraph{
      states: %{"0" => %{"x" => 0}, "1" => %{"x" => 1}, "2" => %{"x" => 2}},
      edges: %{
        {"0", "Inc"} => ["1"],
        {"1", "Inc"} => ["2"],
        {"0", "Reset"} => ["0"],
        {"1", "Reset"} => ["0"],
        {"2", "Reset"} => ["0"]
      },
      initial: ["0"],
      actions: MapSet.new(["Inc", "Reset"]),
      variables: ["x"]
    }
  end

  defp init_step(candidates, x),
    do: %Step{index: 0, outcome: :ok, projection: %{"x" => x}, candidates: candidates}

  defp ok_step(i, action, x, candidates),
    do: %Step{
      index: i,
      action: action,
      params: %{},
      outcome: :ok,
      projection: %{"x" => x},
      candidates: candidates
    }

  defp rejected_step(i, action, x, candidates),
    do: %Step{
      index: i,
      action: action,
      params: %{},
      outcome: {:rejected, :reason},
      projection: %{"x" => x},
      candidates: candidates
    }

  describe "new/4: totals from the graph" do
    test "actions = external keys of actions/0 plus declared internal, nothing reached yet" do
      cov = Coverage.new(line_graph(), ["x"], [], ["Inc", "Reset"])
      summary = Coverage.summary(cov)

      assert summary.actions == %{reached: 0, total: 2, unreached: ["Inc", "Reset"]}
    end

    test "states = distinct projections of all graph states" do
      cov = Coverage.new(line_graph(), ["x"], [], ["Inc", "Reset"])
      summary = Coverage.summary(cov)

      assert summary.states.total == 3
      assert summary.states.reached == 0
      assert Enum.sort(summary.states.unreached) == [%{"x" => 0}, %{"x" => 1}, %{"x" => 2}]
    end

    test "transitions = distinct (obs(from), action, obs(to)) over external-action edges" do
      cov = Coverage.new(line_graph(), ["x"], [], ["Inc", "Reset"])
      summary = Coverage.summary(cov)

      # 2 Inc edges + 3 Reset edges (one a self-loop) = 5 distinct triples.
      assert summary.transitions.total == 5
      assert summary.transitions.reached == 0
    end

    test "an action label in the graph that is neither an external key nor declared internal is excluded" do
      graph = %{line_graph() | actions: MapSet.new(["Inc", "Reset", "Phantom"])}
      cov = Coverage.new(graph, ["x"], [], ["Inc", "Reset"])
      summary = Coverage.summary(cov)

      assert summary.actions.total == 2
      refute "Phantom" in summary.actions.unreached
    end
  end

  describe "add_run/2: a fully-covering run reaches everything" do
    test "actions, states and transitions all reach total" do
      steps = [
        init_step(["0"], 0),
        ok_step(1, "Inc", 1, ["1"]),
        ok_step(2, "Inc", 2, ["2"]),
        ok_step(3, "Reset", 0, ["0"])
      ]

      summary =
        line_graph()
        |> Coverage.new(["x"], [], ["Inc", "Reset"])
        |> Coverage.add_run(steps)
        |> Coverage.summary()

      assert summary.actions == %{reached: 2, total: 2, unreached: []}
      assert summary.states == %{reached: 3, total: 3, unreached: []}

      assert summary.transitions.reached == 3
      assert summary.transitions.total == 5

      assert Enum.sort(summary.transitions.unreached) ==
               Enum.sort([
                 {%{"x" => 0}, "Reset", %{"x" => 0}},
                 {%{"x" => 1}, "Reset", %{"x" => 0}}
               ])
    end
  end

  describe "a synthetic step list where an action is never accepted -> unreached" do
    test "a rejected step does not credit its action, but still counts the observed state" do
      steps = [init_step(["0"], 0), rejected_step(1, "Inc", 0, ["0"])]

      summary =
        line_graph()
        |> Coverage.new(["x"], [], ["Inc", "Reset"])
        |> Coverage.add_run(steps)
        |> Coverage.summary()

      assert summary.actions == %{reached: 0, total: 2, unreached: ["Inc", "Reset"]}
      assert summary.states.reached == 1
      assert summary.transitions.reached == 0
    end
  end

  describe "internal actions (Outlaw design spec §5.2)" do
    # a --Go--> b --React--> c (React is internal). "Go" accepted while the
    # implementation has already reacted means the step's candidates ("c")
    # are disjoint from the direct, no-internal-hop successors of "Go" ("b"):
    # every internal edge from closure(["b"], ["React"]) into "c" is credited.
    defp react_graph do
      %StateGraph{
        states: %{"a" => %{"v" => 0}, "b" => %{"v" => 1}, "c" => %{"v" => 2}},
        edges: %{{"a", "Go"} => ["b"], {"b", "React"} => ["c"]},
        initial: ["a"],
        actions: MapSet.new(["Go", "React"]),
        variables: ["v"]
      }
    end

    test "an internal action is credited when the new candidates skip past it" do
      steps = [
        %Step{index: 0, outcome: :ok, projection: %{"v" => 0}, candidates: ["a"]},
        %Step{
          index: 1,
          action: "Go",
          params: %{},
          outcome: :ok,
          projection: %{"v" => 2},
          candidates: ["c"]
        }
      ]

      summary =
        react_graph()
        |> Coverage.new(["v"], ["React"], ["Go"])
        |> Coverage.add_run(steps)
        |> Coverage.summary()

      assert summary.actions == %{reached: 2, total: 2, unreached: []}
    end

    test "a (settle) step credits internal actions the same way, using C_prev as E" do
      steps = [
        %Step{index: 0, outcome: :ok, projection: %{"v" => 1}, candidates: ["b"]},
        %Step{
          index: 1,
          action: "(settle)",
          params: nil,
          outcome: :ok,
          projection: %{"v" => 2},
          candidates: ["c"]
        }
      ]

      summary =
        react_graph()
        |> Coverage.new(["v"], ["React"], ["Go"])
        |> Coverage.add_run(steps)
        |> Coverage.summary()

      assert summary.actions.reached == 1
      refute "React" in summary.actions.unreached
      assert "Go" in summary.actions.unreached
    end

    test "no internal action is credited when the new candidates were already directly reachable" do
      # "Go" lands straight on "b", and the step's own candidates are "b" too
      # (no internal hop happened): candidates ∩ E is non-empty, so nothing
      # past "Go" itself is credited.
      steps = [
        %Step{index: 0, outcome: :ok, projection: %{"v" => 0}, candidates: ["a"]},
        %Step{
          index: 1,
          action: "Go",
          params: %{},
          outcome: :ok,
          projection: %{"v" => 1},
          candidates: ["b"]
        }
      ]

      summary =
        react_graph()
        |> Coverage.new(["v"], ["React"], ["Go"])
        |> Coverage.add_run(steps)
        |> Coverage.summary()

      assert summary.actions.reached == 1
      assert summary.actions.unreached == ["React"]
    end
  end

  describe "unreached lists are capped at 20 and sorted" do
    test "more than 20 unreached states are capped" do
      states = for n <- 0..24, into: %{}, do: {Integer.to_string(n), %{"n" => n}}

      graph = %StateGraph{
        states: states,
        edges: %{},
        initial: ["0"],
        actions: MapSet.new(),
        variables: ["n"]
      }

      summary = graph |> Coverage.new(["n"], [], []) |> Coverage.summary()

      assert summary.states.total == 25
      assert summary.states.reached == 0
      assert length(summary.states.unreached) == 20
      assert summary.states.unreached == Enum.sort(summary.states.unreached)
      assert hd(summary.states.unreached) == %{"n" => 0}
    end
  end

  describe "accumulates across multiple runs" do
    test "add_run/2 is additive, not a replacement" do
      cov = Coverage.new(line_graph(), ["x"], [], ["Inc", "Reset"])

      run1 = [init_step(["0"], 0), ok_step(1, "Inc", 1, ["1"])]
      run2 = [init_step(["0"], 0), ok_step(1, "Reset", 0, ["0"])]

      summary =
        cov
        |> Coverage.add_run(run1)
        |> Coverage.add_run(run2)
        |> Coverage.summary()

      assert summary.actions == %{reached: 2, total: 2, unreached: []}
    end
  end
end
