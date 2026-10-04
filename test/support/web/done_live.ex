defmodule Outlaw.Fixtures.Web.DoneLive do
  @moduledoc false
  use Phoenix.LiveView, log: false

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <div><span hidden data-outlaw-var="page" data-outlaw-json={JSON.encode!("done")}></span>Done</div>
    """
  end
end
