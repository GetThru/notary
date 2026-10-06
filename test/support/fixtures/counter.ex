defmodule Notary.Fixtures.Counter do
  @moduledoc false
  use Agent

  def start_link(max), do: Agent.start_link(fn -> %{x: 0, max: max} end)

  def inc(pid) do
    Agent.get_and_update(pid, fn
      %{x: x, max: max} = s when x < max -> {:ok, %{s | x: x + 1}}
      s -> {{:error, :at_max}, s}
    end)
  end

  def reset(pid), do: Agent.update(pid, &%{&1 | x: 0})
  def value(pid), do: Agent.get(pid, & &1.x)
end
