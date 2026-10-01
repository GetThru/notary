defmodule Outlaw.Conformance.RunnerTest do
  use ExUnit.Case, async: true

  alias Outlaw.{Config, Conformance, Fixtures}
  alias Outlaw.Conformance.{Failure, Runner, Step}

  defp check(module, graph_name, opts \\ []) do
    Conformance.check(
      module,
      Fixtures.graph(graph_name),
      Keyword.merge([seed: 42, max_runs: 200], opts)
    )
  end

  describe "correct implementations pass" do
    test "Counter" do
      assert {:ok, %{runs: 200, seed: 42}} = check(Fixtures.CounterSpec, "Counter")
    end

    test "Bank with an unobserved variable" do
      assert {:ok, _} = check(Fixtures.BankSpec, "Bank")
    end

    test "Workflow with two actors and an external gateway" do
      assert {:ok, _} = check(Fixtures.WorkflowSpec, "Workflow")
    end

    test "Async: an internal action (Complete) fires on its own" do
      assert {:ok, %{runs: 200, seed: 42}} = check(Fixtures.AsyncSpec, "Async")
    end
  end

  describe "internal actions" do
    test "a wrong completion target fails (illegal_transition or rejected_with_side_effect)" do
      assert {:error, %Failure{kind: kind}} = check(Fixtures.AsyncWrongCompletionSpec, "Async")
      assert kind in [:illegal_transition, :rejected_with_side_effect]
    end

    test "a missing reaction stalls settle with the pending internal action" do
      assert {:error, %Failure{kind: :internal_action_stalled, details: details}} =
               check(Fixtures.AsyncStalledSpec, "Async", settle_timeout: 50)

      assert details.pending == ["Complete"]
      assert details.settle_timeout == 50
    end

    test "Config.get(:settle_timeout) defaults to 1_000" do
      assert Config.get(:settle_timeout) == 1_000
    end
  end

  describe "buggy implementations fail with a shrunk trace" do
    test "missing guard -> action_not_enabled after exactly Max+1 increments" do
      assert {:error, %Failure{kind: :action_not_enabled, seed: 42, steps: steps}} =
               check(Fixtures.CounterNoGuardSpec, "Counter")

      assert [%Step{index: 0, action: nil} | rest] = steps
      assert Enum.map(rest, & &1.action) == ["Inc", "Inc", "Inc", "Inc"]
      assert List.last(steps).projection == %{"x" => 4}
      assert List.last(steps).allowed == []
    end

    test "wrong transition -> illegal_transition with what the spec allowed" do
      assert {:error, %Failure{kind: :illegal_transition, steps: steps}} =
               check(Fixtures.CounterBadResetSpec, "Counter")

      last = List.last(steps)
      assert last.action == "Reset"
      assert last.projection == %{"x" => 1}
      assert last.allowed == [%{"x" => 0}]
      assert length(steps) == 2
    end

    test "rejected with side effect" do
      assert {:error, %Failure{kind: :rejected_with_side_effect, steps: steps}} =
               check(Fixtures.CounterSideEffectSpec, "Counter")

      assert List.last(steps).outcome == {:rejected, :at_max}
    end

    test "overdraft in Bank shrinks to a single withdrawal of 1" do
      assert {:error, %Failure{kind: :action_not_enabled, steps: [_init, step]}} =
               check(Fixtures.BankOverdraftSpec, "Bank")

      assert step.action == "Withdraw"
      assert step.params == %{a: 1}
    end

    test "Workflow paying while the gateway is down" do
      assert {:error, %Failure{kind: :action_not_enabled, steps: steps}} =
               check(Fixtures.WorkflowIgnoresGatewaySpec, "Workflow")

      assert Enum.map(steps, & &1.action) == [nil, "GatewayDown", "Pay"]
    end

    test "init mismatch" do
      assert {:error,
              %Failure{
                kind: :init_mismatch,
                steps: [%Step{projection: %{"x" => 7}, allowed: [%{"x" => 0}]}]
              }} =
               check(Fixtures.CounterBadInitSpec, "Counter")
    end

    test "invalid projection" do
      assert {:error,
              %Failure{
                kind: :invalid_projection,
                details: %{got: ["extra", "x"], expected: ["x"]}
              }} =
               check(Fixtures.CounterBadProjectionSpec, "Counter")
    end

    test "invalid projection value outside the Outlaw.Value representation" do
      assert {:error, %Failure{kind: :invalid_projection, details: details}} =
               check(Fixtures.CounterBadProjectionValueSpec, "Counter")

      assert details.variable == "x"
      assert details.value == nil
      assert details.message =~ ~S(value for "x" is nil)
      assert details.message =~ "use strings, model/1 for model values, or set/1 for sets"
    end

    test "init/0 not returning {:ok, ctx} is reported clearly" do
      assert {:error, %Failure{kind: :invalid_action_result, details: details}} =
               check(Fixtures.CounterBadInitResultSpec, "Counter")

      assert details.got == ":ok"
      assert details.message =~ "init/0 must return {:ok, ctx}"
    end

    test "exceptions are reported with the callback that raised" do
      assert {:error, %Failure{kind: :exception, details: details}} =
               check(Fixtures.CounterRaisingSpec, "Counter")

      assert details.exception =~ "boom"
      assert details.during =~ "action/3 Inc"
    end

    test "slow callbacks time out" do
      assert {:error, %Failure{kind: :timeout, details: %{during: during}}} =
               check(Fixtures.CounterSlowSpec, "Counter", action_timeout: 50, max_runs: 20)

      assert during =~ "Inc"

      # The many timeout-and-kill cycles above (one per shrink attempt) must
      # not leave stray tagged progress/done messages from killed workers
      # sitting in our mailbox.
      Process.sleep(50)
      assert {:message_queue_len, 0} = Process.info(self(), :message_queue_len)
    end

    test "teardown does not mislabel the failing step's details.during" do
      assert {:error, %Failure{kind: :illegal_transition, details: details}} =
               check(Fixtures.CounterBadResetTeardownSpec, "Counter")

      refute to_string(details[:during]) =~ "teardown"
    end
  end

  test "invalid mappings are rejected before running" do
    assert {:error, %Outlaw.Error{kind: :invalid_mapping}} =
             check(Fixtures.CounterUnknownActionSpec, "Counter")
  end

  test "a named process from init is released before the next run's init/0" do
    assert {:ok, _} = check(Fixtures.CounterNamedSpec, "Counter", max_runs: 50)
  end

  test "the generator emits only declared actions, up to max_steps" do
    gen = Runner.steps_generator(%{"Inc" => StreamData.constant(%{})}, 3)

    for steps <- Enum.take(gen, 50) do
      assert length(steps) <= 3
      assert Enum.all?(steps, &(&1 == {"Inc", %{}}))
    end
  end
end
