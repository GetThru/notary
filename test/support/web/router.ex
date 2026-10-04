defmodule Outlaw.Fixtures.Web.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
  end

  scope "/" do
    pipe_through(:browser)

    live("/toggle", Outlaw.Fixtures.Web.ToggleLive)
    live("/done", Outlaw.Fixtures.Web.DoneLive)
    get("/plain", Outlaw.Fixtures.Web.PageController, :plain)
  end
end
