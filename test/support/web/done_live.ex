defmodule Outlaw.Fixtures.Web.DoneLive do
  @moduledoc false
  use Phoenix.LiveView, log: false

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <div><h1 id="page">Done</h1></div>
    """
  end
end
