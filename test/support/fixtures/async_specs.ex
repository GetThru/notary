defmodule Outlaw.Fixtures.AsyncSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Async.tla", internal: ["Complete"]
  alias Outlaw.Fixtures.AsyncJob

  @impl true
  def init, do: AsyncJob.start_link()

  @impl true
  def actions, do: %{"Request" => StreamData.constant(%{})}

  @impl true
  def action("Request", _, pid) do
    case AsyncJob.request(pid) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:rejected, reason, pid}
    end
  end

  @impl true
  def project(pid), do: %{"status" => Atom.to_string(AsyncJob.status(pid))}
end

defmodule Outlaw.Fixtures.AsyncWrongCompletionSpec do
  @moduledoc false
  # Bug: Complete moves back to :idle instead of :done.
  use Outlaw.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Complete"],
    discover: false

  alias Outlaw.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link(complete_to: :idle)
  defdelegate actions(), to: Outlaw.Fixtures.AsyncSpec
  defdelegate action(name, params, pid), to: Outlaw.Fixtures.AsyncSpec
  defdelegate project(pid), to: Outlaw.Fixtures.AsyncSpec
end

defmodule Outlaw.Fixtures.AsyncStalledSpec do
  @moduledoc false
  # Bug: Complete never fires (models a missing reaction).
  use Outlaw.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Complete"],
    discover: false

  alias Outlaw.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link(never_complete: true)
  defdelegate actions(), to: Outlaw.Fixtures.AsyncSpec
  defdelegate action(name, params, pid), to: Outlaw.Fixtures.AsyncSpec
  defdelegate project(pid), to: Outlaw.Fixtures.AsyncSpec
end

defmodule Outlaw.Fixtures.AsyncInternalAlsoExternalSpec do
  @moduledoc false
  # Invalid mapping: "Complete" is declared both internal and in actions/0.
  use Outlaw.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Complete"],
    discover: false

  alias Outlaw.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link()

  def actions,
    do: %{"Request" => StreamData.constant(%{}), "Complete" => StreamData.constant(%{})}

  defdelegate action(name, params, pid), to: Outlaw.Fixtures.AsyncSpec
  defdelegate project(pid), to: Outlaw.Fixtures.AsyncSpec
end

defmodule Outlaw.Fixtures.AsyncUnknownInternalSpec do
  @moduledoc false
  # Invalid mapping: "Nope" is not an action in the spec's state graph.
  use Outlaw.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Nope"],
    discover: false

  alias Outlaw.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link()
  defdelegate actions(), to: Outlaw.Fixtures.AsyncSpec
  defdelegate action(name, params, pid), to: Outlaw.Fixtures.AsyncSpec
  defdelegate project(pid), to: Outlaw.Fixtures.AsyncSpec
end
