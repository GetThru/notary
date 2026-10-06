defmodule Notary.Fixtures.WorkflowSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Workflow.tla"
  alias Notary.Fixtures.{FakeGateway, Orders}

  @users ["u1", "u2"]

  @impl true
  def init do
    {:ok, gateway} = FakeGateway.start_link()
    {:ok, orders} = Orders.start_link(users: @users, gateway: gateway)
    {:ok, %{orders: orders, gateway: gateway}}
  end

  @impl true
  def actions do
    user = StreamData.fixed_map(%{u: StreamData.member_of(@users)})
    none = StreamData.constant(%{})
    %{"Pay" => user, "Ship" => user, "GatewayDown" => none, "GatewayUp" => none}
  end

  @impl true
  def action("Pay", %{u: u}, ctx), do: reply(Orders.pay(ctx.orders, u), ctx)
  def action("Ship", %{u: u}, ctx), do: reply(Orders.ship(ctx.orders, u), ctx)
  # External effects: the mapping drives the fake gateway.
  def action("GatewayDown", _, ctx), do: flip(ctx, :up, :down)
  def action("GatewayUp", _, ctx), do: flip(ctx, :down, :up)

  @impl true
  def project(ctx) do
    status = Map.new(Orders.statuses(ctx.orders), fn {u, s} -> {model(u), Atom.to_string(s)} end)
    %{"status" => status, "gateway" => Atom.to_string(FakeGateway.status(ctx.gateway))}
  end

  defp flip(ctx, from, to) do
    if FakeGateway.status(ctx.gateway) == from do
      FakeGateway.set(ctx.gateway, to)
      {:ok, ctx}
    else
      {:rejected, :already, ctx}
    end
  end

  defp reply(:ok, ctx), do: {:ok, ctx}
  defp reply({:error, reason}, ctx), do: {:rejected, reason, ctx}
end

defmodule Notary.Fixtures.WorkflowIgnoresGatewaySpec do
  @moduledoc false
  # Bug: payments succeed while the gateway is down.
  use Notary.Conformance, spec: "test/fixtures/specs/Workflow.tla", discover: false
  alias Notary.Fixtures.{FakeGateway, Orders}

  def init do
    {:ok, gateway} = FakeGateway.start_link()
    {:ok, orders} = Orders.start_link(users: ["u1", "u2"], gateway: gateway, check_gateway: false)
    {:ok, %{orders: orders, gateway: gateway}}
  end

  defdelegate actions(), to: Notary.Fixtures.WorkflowSpec
  defdelegate action(name, params, ctx), to: Notary.Fixtures.WorkflowSpec
  defdelegate project(ctx), to: Notary.Fixtures.WorkflowSpec
end
