defmodule Outlaw.Fixtures.CounterSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla"
  alias Outlaw.Fixtures.Counter

  @impl true
  def init, do: Counter.start_link(3)

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

  @impl true
  def teardown(pid), do: Agent.stop(pid)
end

defmodule Outlaw.Fixtures.CounterNoGuardSpec do
  @moduledoc false
  # Bug: Inc ignores the Max guard.
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    Agent.update(pid, &(&1 + 1))
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.Fixtures.CounterBadResetSpec do
  @moduledoc false
  # Bug: Reset goes to 1 instead of 0.
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Reset" => StreamData.constant(%{})}

  def action("Reset", _, pid) do
    Agent.update(pid, fn _ -> 1 end)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.Fixtures.CounterSideEffectSpec do
  @moduledoc false
  # Bug: a rejected Inc still changes state.
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    if Agent.get(pid, & &1) < 3 do
      Agent.update(pid, &(&1 + 1))
      {:ok, pid}
    else
      Agent.update(pid, fn _ -> 0 end)
      {:rejected, :at_max, pid}
    end
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.Fixtures.CounterBadInitSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 7 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.Fixtures.CounterBadProjectionSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(_pid), do: %{"x" => 0, "extra" => 1}
end

defmodule Outlaw.Fixtures.CounterRaisingSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, _pid), do: raise("boom")
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.Fixtures.CounterSlowSpec do
  @moduledoc false
  use Outlaw.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    Process.sleep(1_000)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Outlaw.Fixtures.CounterUnknownActionSpec do
  @moduledoc false
  use Outlaw.Conformance,
    spec: "test/fixtures/specs/Counter.tla",
    observe: ["x", "nope"],
    discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Decrement" => StreamData.constant(%{})}
  def action(_, _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end
