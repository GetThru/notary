defmodule Outlaw.Fixtures.BankSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Bank.tla", observe: ["balance"]
  alias Outlaw.Fixtures.Bank

  @impl true
  def init, do: Bank.start_link(max: 3)

  @impl true
  def actions do
    amount = StreamData.fixed_map(%{a: StreamData.integer(1..2)})
    %{"Deposit" => amount, "Withdraw" => amount}
  end

  @impl true
  def action("Deposit", %{a: a}, pid), do: reply(Bank.deposit(pid, a), pid)
  def action("Withdraw", %{a: a}, pid), do: reply(Bank.withdraw(pid, a), pid)

  @impl true
  def project(pid), do: %{"balance" => Bank.balance(pid)}

  defp reply(:ok, pid), do: {:ok, pid}
  defp reply({:error, reason}, pid), do: {:rejected, reason, pid}
end

defmodule Outlaw.Fixtures.BankOverdraftSpec do
  @moduledoc false
  # Bug: overdrafts allowed.
  use Outlaw.Conformance,
    spec: "test/fixtures/specs/Bank.tla",
    observe: ["balance"],
    discover: false

  alias Outlaw.Fixtures.Bank

  def init, do: Bank.start_link(max: 3, allow_overdraft: true)
  defdelegate actions(), to: Outlaw.Fixtures.BankSpec
  defdelegate action(name, params, pid), to: Outlaw.Fixtures.BankSpec
  defdelegate project(pid), to: Outlaw.Fixtures.BankSpec
end
