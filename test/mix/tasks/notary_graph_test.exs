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
    out =
      capture_io(fn -> Mix.Task.rerun("notary.graph", ["Workflow", "--format", "mermaid"]) end)

    assert out =~ "stateDiagram-v2"
    assert out =~ ": GatewayDown"
  end

  test "--trace failure without a recorded failure explains what to run" do
    assert_raise Mix.Error, ~r/mix notary.test Counter/, fn ->
      Mix.Task.rerun("notary.graph", ["Counter", "--trace", "failure"])
    end
  end

  test "--trace failure renders a recorded failure" do
    {:ok, graph, _} =
      Notary.TLC.graph(elem(Notary.Spec.fetch("Counter", "test/fixtures/specs"), 1))

    {:error, failure} =
      Notary.Conformance.check(Notary.Fixtures.CounterBadResetSpec, graph, seed: 1)

    Notary.Viewer.write_failure("Counter", graph, failure)

    out =
      capture_io(fn ->
        Mix.Task.rerun("notary.graph", ["Counter", "--trace", "failure", "--format", "mermaid"])
      end)

    assert out =~ "class "
  end

  test "--trace counterexample renders the TLC trace" do
    Application.put_env(:notary, :specs_dir, "test/fixtures/specs_bad")

    out =
      capture_io(fn ->
        Mix.Task.rerun("notary.graph", ["Inv", "--trace", "counterexample", "--format", "mermaid"])
      end)

    assert out =~ ~s(state "x = 2")
  end
end
