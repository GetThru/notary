defmodule Notary.Fixtures.Web.ErrorHTML do
  @moduledoc false

  # Lets the endpoint render (and re-raise) router/controller errors such as
  # `Phoenix.Router.NoRouteError` the way a real app's endpoint does.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
