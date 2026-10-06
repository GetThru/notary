defmodule Notary.Fixtures.Bank do
  @moduledoc false
  use Agent

  def start_link(opts) do
    Agent.start_link(fn ->
      %{balance: 0, max: opts[:max], allow_overdraft: Keyword.get(opts, :allow_overdraft, false)}
    end)
  end

  def deposit(pid, amount) do
    Agent.get_and_update(pid, fn
      %{balance: b, max: max} = s when b + amount <= max -> {:ok, %{s | balance: b + amount}}
      s -> {{:error, :over_limit}, s}
    end)
  end

  def withdraw(pid, amount) do
    Agent.get_and_update(pid, fn
      %{balance: b, allow_overdraft: o} = s when amount <= b or o ->
        {:ok, %{s | balance: b - amount}}

      s ->
        {{:error, :insufficient_funds}, s}
    end)
  end

  def balance(pid), do: Agent.get(pid, & &1.balance)
end
