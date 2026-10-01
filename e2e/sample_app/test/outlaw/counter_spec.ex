defmodule SampleApp.Specs.Counter do
  use Outlaw.Conformance, spec: "specs/Counter.tla"

  alias SampleApp.Counter

  @impl true
  def init, do: Counter.start_link()

  @impl true
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Reset" => StreamData.constant(%{})}

  @impl true
  def action("Inc", _, pid) do
    case Counter.inc(pid) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:rejected, reason, pid}
    end
  end

  def action("Reset", _, pid) do
    Counter.reset(pid)
    {:ok, pid}
  end

  @impl true
  def project(pid), do: %{"x" => Counter.value(pid)}
end
