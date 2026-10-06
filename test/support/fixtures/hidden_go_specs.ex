defmodule Notary.Fixtures.HiddenGoSpec do
  @moduledoc false
  # Never offers Go. With observe: ["x"], x = 0 leaves candidates h = 0 (Go
  # enabled) and h = 1 (Go not enabled, unless both_go).
  use Notary.Conformance,
    spec: "unused.tla",
    observe: ["x"],
    discover: false,
    generation: :uniform

  def init, do: {:ok, nil}
  def actions, do: %{"Go" => StreamData.constant(%{})}
  def action("Go", _, ctx), do: {:rejected, {:not_available, "#go"}, ctx}
  def project(_), do: %{"x" => 0}
end
