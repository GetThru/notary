defmodule Notary.Fixtures.Web.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
  end

  scope "/", log: false do
    pipe_through(:browser)

    live("/toggle", Notary.Fixtures.Web.ToggleLive)
    live("/done", Notary.Fixtures.Web.DoneLive)
    live("/async", Notary.Fixtures.Web.AsyncLive)
    get("/plain", Notary.Fixtures.Web.PageController, :plain)
    get("/teapot", Notary.Fixtures.Web.PageController, :teapot)
    live("/wizard", Notary.Fixtures.WizardLive)
    live("/wizard/done", Notary.Fixtures.WizardDoneLive)
  end
end
