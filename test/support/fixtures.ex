defmodule Notary.Fixtures do
  @moduledoc false
  def graph(name) do
    {:ok, graph} =
      "test/fixtures/graphs/#{name}.dot" |> File.read!() |> Notary.StateGraph.parse_dot()

    graph
  end
end
