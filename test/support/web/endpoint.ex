defmodule Notary.Fixtures.Web.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :notary

  @session [store: :cookie, key: "_notary_test", signing_salt: "notary-test-salt"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])

  plug(Plug.Session, @session)
  plug(Notary.Fixtures.Web.Router)
end

defmodule Notary.Fixtures.Web do
  @moduledoc false

  # Starts the test endpoint once per VM (test_helper.exs, measurement scripts).
  def start! do
    Application.put_env(:phoenix, :json_library, JSON)

    Application.put_env(:notary, Notary.Fixtures.Web.Endpoint,
      secret_key_base: String.duplicate("notary", 11),
      live_view: [signing_salt: "notary-live-salt"],
      render_errors: [formats: [html: Notary.Fixtures.Web.ErrorHTML], layout: false, log: false],
      server: false
    )

    case Notary.Fixtures.Web.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
