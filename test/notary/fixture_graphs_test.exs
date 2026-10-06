defmodule Notary.FixtureGraphsTest do
  use ExUnit.Case, async: false

  @moduletag :tlc
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :work_dir, dir)
    on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
  end

  for name <- ~w(Counter Bank Workflow) do
    test "committed #{name}.dot matches what TLC produces now" do
      {:ok, spec} = Notary.Spec.fetch(unquote(name), "test/fixtures/specs")
      {:ok, fresh, _} = Notary.TLC.graph(spec, force: true)
      committed = Notary.Fixtures.graph(unquote(name))

      assert MapSet.new(Map.values(fresh.states)) == MapSet.new(Map.values(committed.states)),
             "test/fixtures/graphs/#{unquote(name)}.dot is stale: run mix run test/fixtures/regen_graphs.exs"
    end
  end
end
