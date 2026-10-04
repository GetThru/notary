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

  describe "coverage (Outlaw design spec §5.2)" do
    test "Counter: actions 2/2, observed states 4/4" do
      assert {:ok, %{coverage: coverage}} = check(Fixtures.CounterSpec, "Counter")
      assert coverage.actions == %{reached: 2, total: 2, unreached: []}
      assert coverage.states == %{reached: 4, total: 4, unreached: []}
      assert coverage.transitions.reached == coverage.transitions.total
    end

    test "Bank: observed states total 4 (balances 0..3), not 7 (balance x lastOp)" do
      assert {:ok, %{coverage: coverage}} = check(Fixtures.BankSpec, "Bank")
      assert coverage.states.total == 4
      assert coverage.states.reached == 4
    end

    test "Async: the internal action Complete is counted reached" do
      assert {:ok, %{coverage: coverage}} = check(Fixtures.AsyncSpec, "Async")
      assert coverage.actions.total == 2
      assert coverage.actions.reached == 2
      refute "Complete" in coverage.actions.unreached
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

    test "a declared internal action the spec does not mark fair is not required at settle" do
      # Bypasses Conformance.check (which computes :fair from the real spec
      # file) to call the runner directly with an empty fair set: even though
      # AsyncStalledSpec's "Complete" never fires, settle must not wait for it
      # or report it pending, since nothing says it's fair here.
      assert {:ok, %{runs: 5, seed: 42}} =
               Runner.check(Fixtures.AsyncStalledSpec, Fixtures.graph("Async"), ["status"],
                 seed: 42,
                 max_runs: 5,
                 fair: MapSet.new()
               )
    end
  end

  describe "mid-run :settle points (Runner.run/8 with explicit sequences)" do
    @request {"Request", %{}}

    test "a successful mid-run settle records a (settle) step and the run continues" do
      assert {:ok, steps} =
               Runner.run(
                 Fixtures.AsyncSpec,
                 Fixtures.graph("Async"),
                 ["status"],
                 ["Complete"],
                 MapSet.new(["Complete"]),
                 [@request, :settle, @request],
                 5_000,
                 1_000
               )

      # init, Request, mid-run (settle), Request, end-of-run (settle)
      assert Enum.map(steps, & &1.action) == [nil, "Request", "(settle)", "Request", "(settle)"]
      assert Enum.map(steps, & &1.index) == [0, 1, 2, 3, 4]

      mid = Enum.at(steps, 2)
      assert mid.params == nil
      assert mid.outcome == :ok
      assert mid.projection == %{"status" => "done"}
      assert mid.candidates != []
    end

    test "a mid-run settle that stalls fails at the (settle) step" do
      assert {:error, %Failure{kind: :internal_action_stalled, steps: steps, details: details}} =
               Runner.run(
                 Fixtures.AsyncStalledSpec,
                 Fixtures.graph("Async"),
                 ["status"],
                 ["Complete"],
                 MapSet.new(["Complete"]),
                 [@request, :settle, @request],
                 5_000,
                 50
               )

      last = List.last(steps)
      assert last.action == "(settle)"
      assert last.index == 2
      assert length(steps) == 3
      assert details.pending == ["Complete"]
      assert details.during == "settle"
    end

    test ":settle is a no-op when no fair internal action is declared" do
      assert {:ok, steps} =
               Runner.run(
                 Fixtures.CounterSpec,
                 Fixtures.graph("Counter"),
                 ["x"],
                 [],
                 MapSet.new(),
                 [{"Inc", %{}}, :settle, {"Inc", %{}}],
                 5_000,
                 1_000
               )

      assert Enum.map(steps, & &1.action) == [nil, "Inc", "Inc"]
      assert Enum.map(steps, & &1.index) == [0, 1, 2]
    end
  end

  describe "post-shrink minimization (Runner.minimize/4)" do
    # A fake replay: fails iff `pred` holds for the item list.
    defp fake_replay(pred) do
      fn items ->
        if pred.(items),
          do: {:error, Failure.new(:illegal_transition, [], %{items: items})},
          else: {:ok, []}
      end
    end

    test "a long failing list minimizes to exactly the one item that matters" do
      x = {"X", %{}}
      noise = for i <- 1..29, do: if(rem(i, 5) == 0, do: :settle, else: {"N", %{i: i}})
      items = Enum.take(noise, 17) ++ [x] ++ Enum.drop(noise, 17)
      replay = fake_replay(&(x in &1))
      {:error, failure} = replay.(items)

      assert {[^x], %Failure{details: %{items: [^x]}}, stats} =
               Runner.minimize(items, failure, replay, seed: 1)

      assert stats.removed == 29
      assert stats.replays <= 200
    end

    test "params are reduced to a smaller value from the action's own generator" do
      replay = fake_replay(&Enum.any?(&1, fn item -> match?({"W", %{a: _}}, item) end))
      items = [{"N", %{}}, {"W", %{a: 4}}]
      {:error, failure} = replay.(items)

      assert {[{"W", %{a: 1}}], _failure, stats} =
               Runner.minimize(items, failure, replay,
                 seed: 7,
                 actions: %{
                   "N" => StreamData.constant(%{}),
                   "W" => StreamData.fixed_map(%{a: StreamData.integer(1..5)})
                 }
               )

      assert stats.params == 1
    end

    # Items: setup "S", noise "N", trigger "X". Without X the run passes;
    # without S, `missing_setup` is what the replay returns instead.
    defp setup_replay(missing_setup) do
      fn items ->
        cond do
          {"X", %{}} not in items -> {:ok, []}
          {"S", %{}} not in items -> {:error, Failure.new(missing_setup, [], %{items: items})}
          true -> {:error, Failure.new(:illegal_transition, [], %{items: items})}
        end
      end
    end

    @setup_items [{"S", %{}}, {"N", %{}}, {"X", %{}}]

    for kind <- [:timeout, :exception, :crashed, :internal_action_stalled] do
      test "a candidate failing with #{kind} instead of a spec-level kind is rejected" do
        replay = setup_replay(unquote(kind))
        {:error, failure} = replay.(@setup_items)

        assert {[{"S", %{}}, {"X", %{}}], %Failure{kind: :illegal_transition}, _} =
                 Runner.minimize(@setup_items, failure, replay, seed: 1)
      end
    end

    test "a candidate failing with a different spec-level kind is kept" do
      replay = setup_replay(:action_not_enabled)
      {:error, failure} = replay.(@setup_items)

      assert {[{"X", %{}}], %Failure{kind: :action_not_enabled}, _} =
               Runner.minimize(@setup_items, failure, replay, seed: 1)
    end

    test "a non-spec-level original kind only accepts the same kind" do
      replay = fn items ->
        cond do
          {"X", %{}} not in items -> {:ok, []}
          {"S", %{}} not in items -> {:error, Failure.new(:illegal_transition, [], %{})}
          true -> {:error, Failure.new(:exception, [], %{})}
        end
      end

      {:error, failure} = replay.(@setup_items)

      assert {[{"S", %{}}, {"X", %{}}], %Failure{kind: :exception}, _} =
               Runner.minimize(@setup_items, failure, replay, seed: 1)
    end

    test "Conformance.check reports details.minimized with the seed unchanged" do
      assert {:error, %Failure{seed: 42, details: %{minimized: minimized}}} =
               check(Fixtures.BankOverdraftSpec, "Bank")

      assert minimized =~ ~r/^\d+ replays, \d+ items removed, \d+ params reduced$/
    end

    test "Runner.check passes :max_replays through to the minimization" do
      assert {:error, %Failure{seed: 42, details: %{minimized: minimized}}} =
               check(Fixtures.WorkflowIgnoresGatewaySpec, "Workflow", max_replays: 0)

      assert minimized == "0 replays, 0 items removed, 0 params reduced"
    end

    test "total replays are capped by :max_replays" do
      replay = fake_replay(&({"X", %{}} in &1))
      items = List.duplicate({"N", %{}}, 40) ++ [{"X", %{}}]
      {:error, failure} = replay.(items)

      assert {min_items, %Failure{}, %{replays: 5}} =
               Runner.minimize(items, failure, replay, seed: 1, max_replays: 5)

      assert {"X", %{}} in min_items
    end

    test "against the real runner: Inc past Max minimizes to exactly Max+1 Incs" do
      inc = {"Inc", %{}}
      items = [inc, :settle, inc, :settle, inc, inc, inc, inc, :settle, inc]

      replay = fn items ->
        Runner.run(
          Fixtures.CounterNoGuardSpec,
          Fixtures.graph("Counter"),
          ["x"],
          [],
          MapSet.new(),
          items,
          5_000,
          1_000
        )
      end

      {:error, failure} = replay.(items)

      assert {[^inc, ^inc, ^inc, ^inc], %Failure{kind: :action_not_enabled, steps: steps}, _} =
               Runner.minimize(items, failure, replay, seed: 42)

      assert Enum.map(steps, & &1.action) == [nil, "Inc", "Inc", "Inc", "Inc"]
    end
  end

  describe "settle edge cases (unit-level, synthetic graphs)" do
    defmodule FlipMapping do
      @moduledoc false
      use Outlaw.Conformance, spec: "unused.tla", internal: ["Flip"], discover: false

      @impl true
      def init, do: Agent.start_link(fn -> 0 end)

      @impl true
      def actions, do: %{"Noop" => StreamData.constant(%{})}

      @impl true
      def action("Noop", _params, ctx), do: {:ok, ctx}

      # Returns "a" (matching the only graph state) the first time (the
      # init-time projection), and an out-of-closure value on every call
      # after that (the first settle re-projection), so settle fails
      # deterministically on its very first iteration.
      @impl true
      def project(ctx) do
        n = Agent.get_and_update(ctx, &{&1, &1 + 1})
        %{"v" => if(n == 0, do: "a", else: "zzz")}
      end
    end

    defmodule SelfLoopMapping do
      @moduledoc false
      use Outlaw.Conformance, spec: "unused.tla", internal: ["Flip"], discover: false

      @impl true
      def init, do: {:ok, :ctx}

      @impl true
      def actions, do: %{"Noop" => StreamData.constant(%{})}

      @impl true
      def action("Noop", _params, ctx), do: {:ok, ctx}

      @impl true
      def project(_ctx), do: %{"v" => "a"}
    end

    defp self_loop_graph do
      %Outlaw.StateGraph{
        states: %{"0" => %{"v" => "a"}},
        edges: %{{"0", "Flip"} => ["0"]},
        initial: ["0"],
        actions: MapSet.new(["Flip", "Noop"]),
        variables: ["v"]
      }
    end

    test "settle finds a projection outside the closure: :illegal_transition, (settle) last" do
      assert {:error, %Failure{kind: :illegal_transition, steps: steps}} =
               Runner.run(
                 FlipMapping,
                 self_loop_graph(),
                 ["v"],
                 ["Flip"],
                 MapSet.new(["Flip"]),
                 [],
                 :infinity,
                 1_000
               )

      last = List.last(steps)
      assert last.action == "(settle)"
      assert last.params == nil
    end

    defmodule TwoInternalMapping do
      @moduledoc false
      use Outlaw.Conformance,
        spec: "unused.tla",
        internal: ["FairFlip", "UnfairFlip"],
        discover: false

      @impl true
      def init, do: {:ok, :ctx}

      @impl true
      def actions, do: %{"Noop" => StreamData.constant(%{})}

      @impl true
      def action("Noop", _params, ctx), do: {:ok, ctx}

      # Never actually fires either reaction: both stay enabled forever.
      @impl true
      def project(_ctx), do: %{"v" => "a"}
    end

    test "internal_action_stalled's pending list names only the fair internal action" do
      graph = %Outlaw.StateGraph{
        states: %{"0" => %{"v" => "a"}, "1" => %{"v" => "b"}, "2" => %{"v" => "c"}},
        edges: %{{"0", "FairFlip"} => ["1"], {"0", "UnfairFlip"} => ["2"]},
        initial: ["0"],
        actions: MapSet.new(["FairFlip", "UnfairFlip", "Noop"]),
        variables: ["v"]
      }

      assert {:error, %Failure{kind: :internal_action_stalled, details: details}} =
               Runner.run(
                 TwoInternalMapping,
                 graph,
                 ["v"],
                 ["FairFlip", "UnfairFlip"],
                 MapSet.new(["FairFlip"]),
                 [],
                 :infinity,
                 30
               )

      assert details.pending == ["FairFlip"]
    end

    test "an internal self-loop never blocks settle (ignored for quiescence)" do
      {time, result} =
        :timer.tc(fn ->
          Runner.run(
            SelfLoopMapping,
            self_loop_graph(),
            ["v"],
            ["Flip"],
            MapSet.new(["Flip"]),
            [],
            :infinity,
            2_000
          )
        end)

      assert {:ok, _steps} = result
      # Well under settle_timeout: proves it didn't wait it out.
      assert time < 500_000
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

  describe "action_not_offered (design spec §8.4)" do
    test "a :not_available rejection of an action the spec allows everywhere here fails" do
      assert {:error,
              %Failure{kind: :action_not_offered, details: details, steps: steps} = failure} =
               check(Fixtures.CounterNotOfferedSpec, "Counter")

      assert details.selector == "#inc"
      assert List.last(steps).action == "Inc"
      assert List.last(steps).outcome == {:rejected, {:not_available, "#inc"}}
      assert Outlaw.Report.format_failure("Counter", failure) =~ "selector: #inc"
    end

    test "other rejection reasons keep the old semantics" do
      assert {:ok, _} = check(Fixtures.CounterSpec, "Counter")
    end

    test "passes when only some candidates enable the action (hidden variable)" do
      assert {:ok, _} =
               Runner.check(Outlaw.Conformance.RunnerTest.HiddenGo, hidden_graph(), ["x"],
                 seed: 1,
                 max_runs: 30
               )
    end

    test "fails when every candidate enables it" do
      assert {:error, %Failure{kind: :action_not_offered}} =
               Runner.check(
                 Outlaw.Conformance.RunnerTest.HiddenGo,
                 hidden_graph(both_go: true),
                 ["x"],
                 seed: 1,
                 max_runs: 30
               )
    end
  end

  defp hidden_graph(opts \\ []) do
    extra =
      if opts[:both_go],
        do: ~s(2 -> 3 [label="Go",color="black",fontcolor="black"];\n),
        else: ""

    dot = """
    strict digraph DiskGraph {
    nodesep=0.35;
    subgraph cluster_graph {
    color="white";
    1 [label="/\\\\ h = 0\\n/\\\\ x = 0",style = filled]
    2 [label="/\\\\ h = 1\\n/\\\\ x = 0",style = filled]
    3 [label="/\\\\ h = 0\\n/\\\\ x = 1"]
    1 -> 3 [label="Go",color="black",fontcolor="black"];
    #{extra}}
    }
    """

    {:ok, graph} = Outlaw.StateGraph.parse_dot(dot)
    graph
  end
end

defmodule Outlaw.Conformance.RunnerTest.HiddenGo do
  @moduledoc false
  # Never offers Go. With observe: ["x"], x = 0 leaves candidates h = 0 (Go
  # enabled) and h = 1 (Go not enabled, unless both_go).
  use Outlaw.Conformance,
    spec: "unused.tla",
    observe: ["x"],
    discover: false,
    generation: :uniform

  def init, do: {:ok, nil}
  def actions, do: %{"Go" => StreamData.constant(%{})}
  def action("Go", _, ctx), do: {:rejected, {:not_available, "#go"}, ctx}
  def project(_), do: %{"x" => 0}
end
