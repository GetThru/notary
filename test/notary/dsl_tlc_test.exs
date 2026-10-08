defmodule Notary.DSL.TLCTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Notary.DSL.Description

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :specs_dir, Path.join(dir, "specs"))
    Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Enum.each([:specs_dir, :work_dir], &Application.delete_env(:notary, &1)) end)
    :ok
  end

  defp write_spec(mod) do
    specs = Notary.Config.specs_dir()
    File.mkdir_p!(specs)
    d = mod.__notary_description__()
    File.write!(Path.join(specs, "#{d.name}.tla"), Description.tla(d))
    File.write!(Path.join(specs, "#{d.name}.cfg"), Description.cfg(d))
    d.name
  end

  @tag :tlc
  test "counter spec model-checks (4 distinct states)" do
    defmodule TLCCounter do
      use Notary.DSL, name: "TLCCounter"
      constant(max: 3)
      variable(x: 0..max)
      initial(x: 0)

      action Inc do
        guard(x < max)
        assign(x: x + 1)
      end

      action Reset do
        assign(x: 0)
      end
    end

    {:ok, spec} = TLCCounter |> write_spec() |> Notary.Spec.fetch()
    assert {:ok, %{distinct_states: 4}} = Notary.TLC.check(spec)
  end

  @tag :tlc
  test "greeter spec model-checks with deadlock check disabled" do
    defmodule TLCGreeter do
      use Notary.DSL, name: "TLCGreeter"
      variable(greeted: boolean())
      initial(greeted: false)

      action Greet do
        guard(greeted == false)
        assign(greeted: true)
      end
    end

    {:ok, spec} = TLCGreeter |> write_spec() |> Notary.Spec.fetch()
    assert {:ok, %{distinct_states: 2}} = Notary.TLC.check(spec)

    # The generated .cfg disables the deadlock check: after greeting, no
    # action is enabled (both actions are guarded), which TLC would call a
    # deadlock.
    assert File.read!(spec.cfg_path) =~ "CHECK_DEADLOCK FALSE"
  end

  @tag :tlc
  test "wizard spec model-checks (4 states, enum + boolean vars)" do
    defmodule TLCWizard do
      use Notary.DSL, name: "TLCWizard"
      variable(step: ["address", "payment", "done"])
      variable(address: boolean())
      initial(step: "address", address: false)

      action EnterAddress do
        guard(step == "address")
        assign(address: true)
      end

      action Continue do
        guard(step == "address" and address)
        assign(step: "payment")
      end

      action Back do
        guard(step == "payment")
        assign(step: "address")
      end

      action Pay do
        guard(step == "payment" and address)
        assign(step: "done")
      end

      action StartOver do
        guard(step == "done")
        assign(step: "address", address: false)
      end
    end

    {:ok, spec} = TLCWizard |> write_spec() |> Notary.Spec.fetch()
    assert {:ok, %{distinct_states: 4}} = Notary.TLC.check(spec)
  end

  @tag :tlc
  test "bank spec model-checks (parameterized actions with \\E)" do
    defmodule TLCBank do
      use Notary.DSL, name: "TLCBank"

      constant(max_bal: 4)

      variable(balance: 0..max_bal)
      variable(last_op: ["none", "deposit", "withdraw"])

      initial(balance: 0, last_op: "none")

      action Deposit, param: 1..2, doc: "Deposit an amount; the caller picks 1 or 2." do
        guard(balance + param <= max_bal)
        assign(balance: balance + param, last_op: "deposit")
      end

      action Withdraw, param: 1..2 do
        guard(param <= balance)
        assign(balance: balance - param, last_op: "withdraw")
      end
    end

    {:ok, spec} = TLCBank |> write_spec() |> Notary.Spec.fetch()
    assert {:ok, %{distinct_states: states}} = Notary.TLC.check(spec)
    # balance 0..4 x last_op 3 states, minus unreachable — sanity floor.
    assert states >= 8

    # Parameterized actions appear stripped in the state graph (TLC labels
    # the edge `Deposit`, not `Deposit(1)`).
    {:ok, graph, _stats} = Notary.TLC.graph(spec)
    assert MapSet.member?(graph.actions, "Deposit")
    assert MapSet.member?(graph.actions, "Withdraw")
  end

  @tag :tlc
  test "watchdog spec model-checks with fairness and liveness" do
    defmodule TLCWatchdog do
      use Notary.DSL, name: "TLCWatchdog"

      variable(caller: ["alive", "dead"])
      variable(os: ["none", "alive", "exited", "killed"])

      initial(caller: "alive", os: "none")

      action Start do
        guard(caller == "alive" and os == "none")
        assign(os: "alive")
      end

      action Reap, doc: "The watchdog notices the dead caller and kills TLC." do
        guard(caller == "dead" and os == "alive")
        assign(os: "killed")
      end

      fair(Reap)

      property(NoOrphans,
        doc: "A dead caller never leaves TLC running forever.",
        do: leads_to(caller == "dead", os != "alive")
      )
    end

    {:ok, spec} = TLCWatchdog |> write_spec() |> Notary.Spec.fetch()
    assert {:ok, %{distinct_states: _}} = Notary.TLC.check(spec)

    # Fairness is parsed from the generated text by the existing machinery.
    {:ok, fair} = Notary.Spec.fair_actions(spec)
    assert MapSet.equal?(fair, MapSet.new(["Reap"]))

    text = File.read!(spec.tla_path)
    assert text =~ "Spec =="
    assert text =~ "/\\ Init /\\ [][Next]_<<"
    assert text =~ "WF_vars(Reap)"
    assert text =~ "vars == <<os, caller>>"
  end

  @tag :tlc
  test "raw defs and temporal property from the rate-limiter guide" do
    defmodule TLCLimiter do
      use Notary.DSL, name: "TLCLimiter"
      constant(limit: 3)
      variable(count: 0..limit)
      initial(count: 0)

      action Request do
        guard(count < limit)
        assign(count: count + 1)
      end

      action Tick do
        assign(count: 0)
      end
    end

    {:ok, spec} = TLCLimiter |> write_spec() |> Notary.Spec.fetch()
    assert {:ok, %{distinct_states: 4}} = Notary.TLC.check(spec)
  end
end
