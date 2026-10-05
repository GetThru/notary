defmodule Outlaw.Fixtures.Web.AsyncLive do
  @moduledoc false
  use Phoenix.LiveView, log: false

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(status: "loading")
     |> start_async(:settle, fn -> Process.sleep(50) && "loaded" end)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <p id="status">{@status}</p>
    </div>
    """
  end

  def handle_async(:settle, {:ok, result}, socket), do: {:noreply, assign(socket, status: result)}
end
