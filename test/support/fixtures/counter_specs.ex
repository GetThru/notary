defmodule Notary.Fixtures.CounterSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla"
  alias Notary.Fixtures.Counter

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

defmodule Notary.Fixtures.CounterNoGuardSpec do
  @moduledoc false
  # Bug: Inc ignores the Max guard.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    Agent.update(pid, &(&1 + 1))
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadResetSpec do
  @moduledoc false
  # Bug: Reset goes to 1 instead of 0.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Reset" => StreamData.constant(%{})}

  def action("Reset", _, pid) do
    Agent.update(pid, fn _ -> 1 end)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadResetTeardownSpec do
  @moduledoc false
  # Same bug as CounterBadResetSpec, but also has a teardown/1 — regression
  # fixture for making sure teardown doesn't mislabel details.during on a
  # spec-level failure (controller ruling R12, fix round 1, item 1).
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Reset" => StreamData.constant(%{})}

  def action("Reset", _, pid) do
    Agent.update(pid, fn _ -> 1 end)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
  def teardown(pid), do: Agent.stop(pid)
end

defmodule Notary.Fixtures.CounterNamedSpec do
  @moduledoc false
  # Regression fixture (controller ruling R12, fix round 1, item 3): init
  # starts a *named* Agent and there's no teardown/1, so cleanup relies
  # entirely on the runner's process-exit handling. If the runner doesn't
  # guarantee the Agent is fully gone before the next run's init/0, a later
  # run's `Agent.start_link(..., name: ...)` races and fails with
  # `{:already_started, pid}`. Otherwise behaves exactly like CounterSpec.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> %{x: 0, max: 3} end, name: Notary.Fixtures.NamedCounter)
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Reset" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    case Agent.get_and_update(pid, fn
           %{x: x, max: max} = s when x < max -> {:ok, %{s | x: x + 1}}
           s -> {{:error, :at_max}, s}
         end) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:rejected, reason, pid}
    end
  end

  def action("Reset", _, pid) do
    Agent.update(pid, &%{&1 | x: 0})
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1.x)}
end

defmodule Notary.Fixtures.CounterSideEffectSpec do
  @moduledoc false
  # Bug: a rejected Inc still changes state.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

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

defmodule Notary.Fixtures.CounterBadInitSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 7 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadProjectionSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(_pid), do: %{"x" => 0, "extra" => 1}
end

defmodule Notary.Fixtures.CounterBadProjectionValueSpec do
  @moduledoc false
  # Bug: project/1 returns a value outside the Notary.Value representation
  # (regression fixture for the :invalid_projection value-validation finding).
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(_pid), do: %{"x" => nil}
end

defmodule Notary.Fixtures.CounterBadInitResultSpec do
  @moduledoc false
  # Bug: init/0 returns something other than {:ok, ctx} (regression fixture for
  # the :invalid_action_result finding on init/0's own contract).
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: :ok
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => pid}
end

defmodule Notary.Fixtures.CounterRaisingSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}
  def action("Inc", _, _pid), do: raise("boom")
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterSlowSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false
  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{})}

  def action("Inc", _, pid) do
    Process.sleep(1_000)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterUnknownActionSpec do
  @moduledoc false
  use Notary.Conformance,
    spec: "test/fixtures/specs/Counter.tla",
    observe: ["x", "nope"],
    discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Decrement" => StreamData.constant(%{})}
  def action(_, _, pid), do: {:ok, pid}
  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterUniformSpec do
  @moduledoc false
  # Same as CounterSpec, but keeps the Phase 1 uniform generator.
  use Notary.Conformance,
    spec: "test/fixtures/specs/Counter.tla",
    generation: :uniform,
    discover: false

  defdelegate init(), to: Notary.Fixtures.CounterSpec
  defdelegate actions(), to: Notary.Fixtures.CounterSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.CounterSpec
  defdelegate project(pid), to: Notary.Fixtures.CounterSpec
  defdelegate teardown(pid), to: Notary.Fixtures.CounterSpec
end

defmodule Notary.Fixtures.CounterNotOfferedSpec do
  @moduledoc false
  # Bug: the "UI" never offers Inc, although the spec allows it below Max.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Reset" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:rejected, {:not_available, "#inc"}, pid}

  def action("Reset", _, pid) do
    Agent.update(pid, fn _ -> 0 end)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end

defmodule Notary.Fixtures.CounterBadGenerationSpec do
  @moduledoc false
  # Invalid mapping: generation: must be :walk or :uniform.
  use Notary.Conformance,
    spec: "test/fixtures/specs/Counter.tla",
    generation: :nope,
    discover: false

  defdelegate init(), to: Notary.Fixtures.CounterSpec
  defdelegate actions(), to: Notary.Fixtures.CounterSpec
  defdelegate action(name, params, pid), to: Notary.Fixtures.CounterSpec
  defdelegate project(pid), to: Notary.Fixtures.CounterSpec
end
