defmodule Notary.Fixtures.LocateGuardedProjectSpec do
  @moduledoc false
  # Regression fixture for Notary.Mapping.Locate: a guarded def head
  # (`when`) must still be found.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(pid) when is_pid(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.LocateGuardedActionSpec do
  @moduledoc false
  # Regression fixture: a guarded action/3 clause with a string-literal first
  # argument must still record that action name.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", params, pid) when is_map(params), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.LocateGuardedCatchAllActionSpec do
  @moduledoc false
  # Regression fixture: a guarded action/3 catch-all clause (first argument
  # is a bound variable, not a string literal) must still record "*".
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action(name, _, pid) when is_binary(name), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.LocateMatchPatternActionSpec do
  @moduledoc false
  # Regression fixture: a `"Inc" = name` match pattern first argument still
  # records the literal action name, not "*".
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc" = name, _, pid) when is_binary(name), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.LocateSkippedPatternActionSpec do
  @moduledoc false
  # Regression fixture: a first argument pattern that is neither a literal
  # name, a `"Name" = var` match, nor a plain variable/`_` (here, a tuple) is
  # skipped entirely -- never recorded as "*".
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action({:inc, _} = tag, _, pid), do: {:ok, tag, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.LocateArityHelperSpec do
  @moduledoc false
  # Regression fixture: public helpers that share a callback's name but not
  # its arity (declared first) must not be picked over the real callback.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init(_opts), do: :not_this_one
  def actions(_extra), do: :not_this_one
  def project(_extra, _pid), do: :not_this_one

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end
