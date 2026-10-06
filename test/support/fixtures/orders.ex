defmodule Notary.Fixtures.FakeGateway do
  @moduledoc false
  use Agent
  def start_link, do: Agent.start_link(fn -> :up end)
  def set(pid, status), do: Agent.update(pid, fn _ -> status end)
  def status(pid), do: Agent.get(pid, & &1)
  def charge(pid), do: if(status(pid) == :up, do: :ok, else: {:error, :gateway_down})
end

defmodule Notary.Fixtures.Orders do
  @moduledoc false
  use GenServer
  alias Notary.Fixtures.FakeGateway

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def pay(pid, user), do: GenServer.call(pid, {:pay, user})
  def ship(pid, user), do: GenServer.call(pid, {:ship, user})
  def statuses(pid), do: GenServer.call(pid, :statuses)

  @impl true
  def init(opts) do
    {:ok,
     %{
       orders: Map.new(Keyword.fetch!(opts, :users), &{&1, :cart}),
       gateway: Keyword.fetch!(opts, :gateway),
       check_gateway: Keyword.get(opts, :check_gateway, true)
     }}
  end

  @impl true
  def handle_call({:pay, user}, _from, s) do
    cond do
      s.orders[user] != :cart -> {:reply, {:error, :not_in_cart}, s}
      s.check_gateway and FakeGateway.charge(s.gateway) != :ok -> {:reply, {:error, :declined}, s}
      true -> {:reply, :ok, put_in(s.orders[user], :paid)}
    end
  end

  def handle_call({:ship, user}, _from, s) do
    if s.orders[user] == :paid,
      do: {:reply, :ok, put_in(s.orders[user], :shipped)},
      else: {:reply, {:error, :not_paid}, s}
  end

  def handle_call(:statuses, _from, s), do: {:reply, s.orders, s}
end
