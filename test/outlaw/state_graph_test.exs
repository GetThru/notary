defmodule Outlaw.StateGraphTest do
  use ExUnit.Case, async: true

  alias Outlaw.{StateGraph, Value}

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

  test "unparseable state labels are reported as an Outlaw bug with the raw text" do
    dot = ~S"""
    1 [label="x = [oops",style = filled]
    """

    assert {:error, %Outlaw.Error{kind: :unparseable_state, details: %{raw: "x = [oops"}}} =
             StateGraph.parse_dot(dot)
  end
end
