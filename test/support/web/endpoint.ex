defmodule Outlaw.Fixtures.Web.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :outlaw

  @session [store: :cookie, key: "_outlaw_test", signing_salt: "outlaw-test-salt"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])

  plug(Plug.Session, @session)
  plug(Outlaw.Fixtures.Web.Router)
end

defmodule Outlaw.Fixtures.Web do
  @moduledoc false

  # Starts the test endpoint once per VM (test_helper.exs, measurement scripts).
  def start! do
    Application.put_env(:phoenix, :json_library, JSON)

    Application.put_env(:outlaw, Outlaw.Fixtures.Web.Endpoint,
      secret_key_base: String.duplicate("outlaw", 11),
      live_view: [signing_salt: "outlaw-live-salt"],
      render_errors: [formats: [html: Outlaw.Fixtures.Web.ErrorHTML], layout: false, log: false],
      server: false
    )

    case Outlaw.Fixtures.Web.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
