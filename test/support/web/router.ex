defmodule Outlaw.Fixtures.Web.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
  end

  scope "/", log: false do
    pipe_through(:browser)

    live("/toggle", Outlaw.Fixtures.Web.ToggleLive)
    live("/done", Outlaw.Fixtures.Web.DoneLive)
    live("/async", Outlaw.Fixtures.Web.AsyncLive)
    get("/plain", Outlaw.Fixtures.Web.PageController, :plain)
    get("/teapot", Outlaw.Fixtures.Web.PageController, :teapot)
    live("/wizard", Outlaw.Fixtures.WizardLive)
    live("/wizard/done", Outlaw.Fixtures.WizardDoneLive)
  end
end
