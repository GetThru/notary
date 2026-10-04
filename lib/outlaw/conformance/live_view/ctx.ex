if Code.ensure_loaded?(Phoenix.LiveViewTest) and Code.ensure_loaded?(LazyHTML) do
  defmodule Outlaw.Conformance.LiveView.Ctx do
    @moduledoc """
    The context `Outlaw.Conformance.LiveView` helpers pass through a mapping's
    callbacks (design spec §8.2). `view` is the current LiveView, or `nil`
    after a redirect to a page that isn't a LiveView (then `html` is that
    page). `html` is only read when `view` is `nil`; while a view is set it
    may be stale (the helpers render the view instead). `assigns` is free
    space for the mapping (a stub's pid, ...).
    """
    defstruct [:conn, :view, :endpoint, html: "", assigns: %{}]

    @type t :: %__MODULE__{
            conn: Plug.Conn.t(),
            view: %Phoenix.LiveViewTest.View{} | nil,
            html: String.t(),
            endpoint: module(),
            assigns: map()
          }
  end
end
