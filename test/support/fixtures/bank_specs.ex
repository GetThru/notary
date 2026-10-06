defmodule Notary.Fixtures.BankSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Bank.tla", observe: ["balance"]
  alias Notary.Fixtures.Bank

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

defmodule Notary.Fixtures.BankOverdraftSpec do
  @moduledoc false
  # Bug: overdrafts allowed.
  use Notary.Conformance,
    spec: "test/fixtures/specs/Bank.tla",
    observe: ["balance"],
    discover: false

  alias Notary.Fixtures.Bank

  def init, do: Bank.start_link(max: 3, allow_overdraft: true)
  defdelegate actions(), to: Notary.Fixtures.BankSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.BankSpec
  defdelegate project(pid), to: Notary.Fixtures.BankSpec
end
