defmodule Notary.Fixtures.AsyncSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Async.tla", internal: ["Complete"]
  alias Notary.Fixtures.AsyncJob

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

defmodule Notary.Fixtures.AsyncWrongCompletionSpec do
  @moduledoc false
  # Bug: Complete moves back to :idle instead of :done.
  use Notary.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Complete"],
    discover: false

  alias Notary.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link(complete_to: :idle)
  defdelegate actions(), to: Notary.Fixtures.AsyncSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.AsyncSpec
  defdelegate project(pid), to: Notary.Fixtures.AsyncSpec
end

defmodule Notary.Fixtures.AsyncStalledSpec do
  @moduledoc false
  # Bug: Complete never fires (models a missing reaction).
  use Notary.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Complete"],
    discover: false

  alias Notary.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link(never_complete: true)
  defdelegate actions(), to: Notary.Fixtures.AsyncSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.AsyncSpec
  defdelegate project(pid), to: Notary.Fixtures.AsyncSpec
end

defmodule Notary.Fixtures.AsyncInternalAlsoExternalSpec do
  @moduledoc false
  # Invalid mapping: "Complete" is declared both internal and in actions/0.
  use Notary.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Complete"],
    discover: false

  alias Notary.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link()

  def actions,
    do: %{"Request" => StreamData.constant(%{}), "Complete" => StreamData.constant(%{})}

  defdelegate action(name, params, pid), to: Notary.Fixtures.AsyncSpec
  defdelegate project(pid), to: Notary.Fixtures.AsyncSpec
end

defmodule Notary.Fixtures.AsyncUnknownInternalSpec do
  @moduledoc false
  # Invalid mapping: "Nope" is not an action in the spec's state graph.
  use Notary.Conformance,
    spec: "test/fixtures/specs/Async.tla",
    internal: ["Nope"],
    discover: false

  alias Notary.Fixtures.AsyncJob

  def init, do: AsyncJob.start_link()
  defdelegate actions(), to: Notary.Fixtures.AsyncSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.AsyncSpec
  defdelegate project(pid), to: Notary.Fixtures.AsyncSpec
end
