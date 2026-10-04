defmodule Outlaw.Fixtures.WizardLive do
  @moduledoc false
  # session "variant": "correct" | "early_pay" (Pay shown on the address step
  # too) | "no_pay" (Pay never rendered) | "redirect" (Pay navigates to
  # /wizard/done). Routed at /wizard as "redirect".
  use Phoenix.LiveView, log: false

  def mount(_params, session, socket) do
    variant = session["variant"] || "redirect"
    {:ok, assign(socket, variant: variant, step: "address", address: false)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <span hidden data-outlaw-var="step" data-outlaw-json={JSON.encode!(@step)}></span>
      <span hidden data-outlaw-var="address" data-outlaw-json={JSON.encode!(@address)}></span>
      <form :if={@step == "address"} id="address-form" phx-submit="enter_address">
        <input name="address" value="" />
        <button type="submit">Save address</button>
      </form>
      <button :if={@step == "address"} id="continue" phx-click="continue" disabled={not @address}>
        Continue
      </button>
      <button :if={@step == "payment"} id="back" phx-click="back">Back</button>
      <button :if={show_pay?(@variant, @step)} id="pay" phx-click="pay">Pay</button>
      <button :if={@step == "done"} id="start-over" phx-click="start_over">Start over</button>
    </div>
    """
  end

  defp show_pay?("early_pay", step), do: step in ["address", "payment"]
  defp show_pay?("no_pay", _step), do: false
  defp show_pay?(_variant, step), do: step == "payment"

  def handle_event("enter_address", %{"address" => _}, socket),
    do: {:noreply, assign(socket, address: true)}

  def handle_event("continue", _, socket), do: {:noreply, assign(socket, step: "payment")}
  def handle_event("back", _, socket), do: {:noreply, assign(socket, step: "address")}

  def handle_event("start_over", _, socket),
    do: {:noreply, assign(socket, step: "address", address: false)}

  def handle_event("pay", _, %{assigns: %{variant: "redirect"}} = socket),
    do: {:noreply, push_navigate(socket, to: "/wizard/done")}

  def handle_event("pay", _, socket), do: {:noreply, assign(socket, step: "done")}
end

defmodule Outlaw.Fixtures.WizardDoneLive do
  @moduledoc false
  # The redirect variant's confirmation page: step "done", address TRUE.
  use Phoenix.LiveView, log: false

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <div>
      <span hidden data-outlaw-var="step" data-outlaw-json={JSON.encode!("done")}></span>
      <span hidden data-outlaw-var="address" data-outlaw-json={JSON.encode!(true)}></span>
      <button id="start-over" phx-click="start_over">Start over</button>
    </div>
    """
  end

  def handle_event("start_over", _, socket), do: {:noreply, push_navigate(socket, to: "/wizard")}
end
