if Code.ensure_loaded?(Phoenix.LiveViewTest) and Code.ensure_loaded?(LazyHTML) do
  defmodule Outlaw.Conformance.LiveView.Ctx do
    @moduledoc """
    The context `Outlaw.Conformance.LiveView` helpers pass through a mapping's
    callbacks (design spec §8.2). `view` is the current LiveView, or `nil`
    after a redirect to a page that isn't a LiveView (then `html` is that
    page). `assigns` is free space for the mapping (a stub's pid, ...).
    """
    defstruct [:conn, :view, :endpoint, html: "", registered?: false, assigns: %{}]

    @type t :: %__MODULE__{
            conn: Plug.Conn.t(),
            view: Phoenix.LiveViewTest.View.t() | nil,
            html: String.t(),
            endpoint: module(),
            registered?: boolean(),
            assigns: map()
          }
  end
end
