defmodule Notary.Fixtures.Web.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  def teapot(conn, _params), do: send_resp(conn, 418, "short and stout")

  def plain(conn, _params) do
    html(conn, ~s(<h1 id="page">Plain</h1>))
  end
end
