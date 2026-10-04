defmodule Outlaw.Fixtures.Web.ToggleLive do
  @moduledoc false
  use Phoenix.LiveView, log: false

  def mount(_params, _session, socket) do
    {:ok, assign(socket, on: false, name: "", locked: false, slow: "idle")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <span hidden data-outlaw-var="on" data-outlaw-json={JSON.encode!(@on)}></span>
      <span hidden data-outlaw-var="name" data-outlaw-json={JSON.encode!(@name)}></span>
      <span hidden data-outlaw-var="slow" data-outlaw-json={JSON.encode!(@slow)}></span>
      <button id="flip" phx-click="flip">Flip</button>
      <button id="off" phx-click="off" disabled={not @on}>Off</button>
      <button :if={@on} id="only-when-on" phx-click="off">Off (conditional)</button>
      <button class="dup" phx-click="flip">A</button>
      <button class="dup" phx-click="flip">B</button>
      <button id="lock" phx-click="lock">Lock</button>
      <form id="name-form" phx-submit="save" phx-change="typing">
        <input name="name" value={@name} />
        <button type="submit" disabled={@locked}>Save</button>
      </form>
      <form id="bare-form" phx-submit="save">
        <input name="name" value={@name} />
      </form>
      <button id="slow" phx-click="slow">Slow</button>
      <button id="go" phx-click="go">Go</button>
      <button id="leave" phx-click="leave">Leave</button>
      <button id="go-async" phx-click="go-async">Go async</button>
    </div>
    """
  end

  def handle_event("flip", _, socket), do: {:noreply, update(socket, :on, &(not &1))}
  def handle_event("off", _, socket), do: {:noreply, assign(socket, on: false)}
  def handle_event("lock", _, socket), do: {:noreply, assign(socket, locked: true)}
  def handle_event("save", %{"name" => name}, socket), do: {:noreply, assign(socket, name: name)}

  def handle_event("typing", %{"name" => name}, socket),
    do: {:noreply, assign(socket, name: "typing:" <> name)}

  def handle_event("go", _, socket), do: {:noreply, push_navigate(socket, to: "/done")}
  def handle_event("leave", _, socket), do: {:noreply, redirect(socket, to: "/plain")}
  def handle_event("go-async", _, socket), do: {:noreply, push_navigate(socket, to: "/async")}

  def handle_event("slow", _, socket) do
    {:noreply,
     socket
     |> assign(slow: "running")
     |> start_async(:slow, fn -> Process.sleep(50) && "finished" end)}
  end

  def handle_async(:slow, {:ok, result}, socket), do: {:noreply, assign(socket, slow: result)}
end
