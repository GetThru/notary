defmodule Outlaw.Fixtures.Web.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  def teapot(conn, _params), do: send_resp(conn, 418, "short and stout")

  def plain(conn, _params) do
    html(
      conn,
      ~s(<p><span hidden data-outlaw-var="page" data-outlaw-json='"plain"'></span>Plain</p>)
    )
  end
end
