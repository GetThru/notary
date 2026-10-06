defmodule Outlaw.ViewerTest do
  use ExUnit.Case, async: false

  alias Outlaw.{Fixtures, Viewer}
  alias Outlaw.Viewer.Mermaid
  alias Outlaw.Conformance.{Failure, Step}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:outlaw, :work_dir, dir)
    on_exit(fn -> Application.delete_env(:outlaw, :work_dir) end)
  end

  test "from_graph renders vars as TLA+ and keeps edges and initial states" do
    graph = Fixtures.graph("Counter")
    model = Viewer.from_graph(graph, title: "Counter", highlight: graph.initial)
    assert length(model.nodes) == 4
    assert Enum.count(model.nodes, & &1.initial) == 1
    assert Enum.all?(model.nodes, &match?(%{vars: %{"x" => x}} when is_binary(x), &1))
    assert length(model.edges) == length(Outlaw.StateGraph.edges(graph))
    assert model.highlight == graph.initial
  end

  test "html is self-contained and embeds the data safely" do
    model = %{
      title: "A <b> & </script>",
      note: "<!-- comment --> and </script>",
      nodes: [%{id: "1", vars: %{"s" => ~S("</script>")}, initial: true}],
      edges: [],
      highlight: []
    }

    html = Viewer.html(model)
    assert html =~ "<title>A &lt;b&gt; &amp; &lt;/script&gt;</title>"
    assert html =~ "cytoscape"
    refute html =~ ~r/<script[^>]+src=/
    refute html =~ ~r/<link[^>]+href=/

    [_, json] =
      Regex.run(~r{<script type="application/json" id="outlaw-data">(.*?)</script>}s, html)

    # Every `<` in the embedded JSON is escaped as < (valid JSON, since
    # `<` only occurs inside strings), so the block contains neither `</script`
    # nor `<!--`, and JSON.decode!/1 (which understands < natively)
    # recovers the original values without any manual unescaping.
    refute json =~ "</script"
    refute json =~ "<!--"
    assert json =~ "\\u003c"

    assert %{
             "note" => "<!-- comment --> and </script>",
             "nodes" => [%{"vars" => %{"s" => ~S("</script>")}}]
           } = JSON.decode!(json)
  end

  test "from_trace builds a linear path with loop and stutter edges" do
    v = %{
      kind: :liveness,
      name: nil,
      message: "Temporal properties were violated.",
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

    failure = %Failure{
      kind: :illegal_transition,
      seed: 1,
      steps: [%Step{index: 0, outcome: :ok, projection: %{"x" => 0}, candidates: [init]}]
    }

    path = Viewer.write_failure("Counter", graph, failure)
    assert Path.basename(path) == "Counter-failure.html"
    assert File.read!(path) =~ "conformance failure"
    assert Viewer.read_failure("Counter") == {:ok, failure}
    assert Viewer.read_failure("Nope") == :error
    assert Viewer.failure_model("Counter", graph, failure).highlight == [init]
  end

  test "failure_model warns when highlights no longer resolve (stale failure term)" do
    # State ids are TLC fingerprints; a failure recorded against an earlier
    # graph rebuild carries ids that no longer exist in the current one.
    model =
      Viewer.failure_model("Counter", Fixtures.graph("Counter"), %Failure{
        kind: :illegal_transition,
        seed: 1,
        steps: [
          %Step{index: 0, outcome: :ok, projection: %{"x" => 0}, candidates: ["dead-id"]},
          %Step{index: 1, outcome: :ok, projection: %{"x" => 1}, candidates: ["also-dead"]}
        ]
      })

    assert model.note =~ "WARNING: the recorded failure predates the current state graph"
    assert model.note =~ "2 of 2 highlights no longer resolve"
    assert model.highlight == ["dead-id", "also-dead"]

    # Fresh ids: no warning.
    graph = Fixtures.graph("Counter")
    [init | _] = graph.initial

    fresh =
      Viewer.failure_model("Counter", graph, %Failure{
        kind: :illegal_transition,
        seed: 1,
        steps: [%Step{index: 0, outcome: :ok, projection: %{"x" => 0}, candidates: [init]}]
      })

    refute fresh.note =~ "WARNING"
  end

  test "read_failure returns :error for corrupt bytes or a term that isn't a Failure" do
    corrupt_path = Path.join(Outlaw.Config.work_dir(), "Corrupt-failure.term")
    File.mkdir_p!(Outlaw.Config.work_dir())
    File.write!(corrupt_path, <<1, 2, 3, 255, 254>>)
    assert Viewer.read_failure("Corrupt") == :error

    wrong_shape_path = Path.join(Outlaw.Config.work_dir(), "NotAFailure-failure.term")
    File.write!(wrong_shape_path, :erlang.term_to_binary(%{a: 1}))
    assert Viewer.read_failure("NotAFailure") == :error
  end

  test "read_failure decodes a failure containing an atom unknown to this process" do
    # A recorded failure can legitimately contain atoms that exist only because of
    # the *user's* code (e.g. a `{:rejected, reason}` atom from their mapping's
    # action/3, or a raw value under `details.got`). The reading process (e.g.
    # `mix outlaw.graph`, which never compiles or starts the consumer app) has no
    # way to have that atom already registered in its atom table. Simulate this by
    # encoding a failure, then swapping a placeholder atom's name for a same-length
    # name we never turn into an atom ourselves, so the only way this test passes
    # is if `read_failure/1` can materialize a brand-new atom from the file.
    placeholder = "outlaw_placeholder_atom_x1"

    failure = %Failure{
      kind: :rejected_with_side_effect,
      seed: 1,
      steps: [
        %Step{index: 0, outcome: :ok, projection: %{"x" => 0}, candidates: ["s0"]},
        %Step{
          index: 1,
          action: "Inc",
          outcome: {:rejected, String.to_atom(placeholder)},
          projection: %{"x" => 0},
          candidates: ["s0"]
        }
      ]
    }

    new_name =
      placeholder
      |> byte_size()
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map(&(rem(&1, 26) + ?a))
      |> List.to_string()

    binary =
      failure
      |> :erlang.term_to_binary()
      |> :binary.replace(placeholder, new_name)

    path = Path.join(Outlaw.Config.work_dir(), "Unknown-failure.term")
    File.mkdir_p!(Outlaw.Config.work_dir())
    File.write!(path, binary)

    assert {:ok, %Failure{steps: [_init, %Step{outcome: {:rejected, reason}}]}} =
             Viewer.read_failure("Unknown")

    assert Atom.to_string(reason) == new_name
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

    test "lists states by content (initial first) and edges by source, then action" do
      text = Mermaid.render(Viewer.from_graph(Fixtures.graph("Counter")))

      states = Regex.scan(~r/^    state "([^"]*)" as (s\d+)$/m, text, capture: :all_but_first)
      assert Enum.map(states, &hd/1) == ["x = 0", "x = 1", "x = 2", "x = 3"]
      assert Enum.map(states, &List.last/1) == ["s0", "s1", "s2", "s3"]

      edges =
        Regex.scan(~r/^    s(\d+) --> s(\d+) : (\w+)$/m, text, capture: :all_but_first)
        |> Enum.map(fn [from, to, action] ->
          {String.to_integer(from), action, String.to_integer(to)}
        end)

      assert edges == Enum.sort(edges)
      assert {0, "Inc", 1} in edges
    end

    test "escapes quotes and angle brackets" do
      model = %{
        title: "t",
        note: nil,
        nodes: [%{id: "1", vars: %{"l" => ~S(<<"a">>)}, initial: true}],
        edges: [],
        highlight: []
      }

      assert Mermaid.render(model) =~ ~s(state "l = #lt;#lt;#quot;a#quot;#gt;#gt;" as s0)
    end

    test "escapes action labels and strips newlines from them" do
      model = %{
        title: "t",
        note: nil,
        nodes: [
          %{id: "1", vars: %{"x" => "0"}, initial: true},
          %{id: "2", vars: %{"x" => "1"}, initial: false}
        ],
        edges: [%{source: "1", target: "2", action: ~s(Weird"\n<action>)}],
        highlight: []
      }

      text = Mermaid.render(model)
      assert text =~ ~s(: Weird#quot; #lt;action#gt;)
      refute text =~ "\n<action>"
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
