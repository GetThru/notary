defmodule Notary.Conformance.RunnerLeakTest do
  # Uses Process.list/0, which counts every process in the VM: it must not run
  # concurrently with other test modules (async: true) or unrelated test
  # processes can inflate or shrink the count and flake this test. See
  # controller review, final whole-branch review finding 7.
  use ExUnit.Case, async: false

  alias Notary.{Conformance, Fixtures}

  test "processes started by init are cleaned up after each run" do
    before = length(Process.list())

    assert {:ok, _} =
             Conformance.check(Fixtures.WorkflowSpec, Fixtures.graph("Workflow"),
               seed: 42,
               max_runs: 50
             )

    Process.sleep(50)
    assert length(Process.list()) - before < 5
  end
end
