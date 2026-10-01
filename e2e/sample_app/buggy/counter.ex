defmodule SampleApp.Counter do
  use Agent

  def start_link, do: Agent.start_link(fn -> 0 end)

  # Bug: no upper bound.
  def inc(pid), do: Agent.update(pid, &(&1 + 1))

  def reset(pid), do: Agent.update(pid, fn _ -> 0 end)
  def value(pid), do: Agent.get(pid, & &1)
end
