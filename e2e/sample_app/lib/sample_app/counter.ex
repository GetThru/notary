defmodule SampleApp.Counter do
  use Agent

  @max 3

  def start_link, do: Agent.start_link(fn -> 0 end)

  def inc(pid) do
    Agent.get_and_update(pid, fn
      x when x < @max -> {:ok, x + 1}
      x -> {{:error, :at_max}, x}
    end)
  end

  def reset(pid), do: Agent.update(pid, fn _ -> 0 end)
  def value(pid), do: Agent.get(pid, & &1)
end
