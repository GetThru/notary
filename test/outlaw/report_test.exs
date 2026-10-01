defmodule Outlaw.ReportTest do
  use ExUnit.Case, async: true

  alias Outlaw.{Error, Report, Value}
  alias Outlaw.Conformance.{Failure, Step}

  @failure %Failure{
    kind: :action_not_enabled,
    seed: 1234,
    steps: [
      %Step{index: 0, outcome: :ok, projection: %{"balance" => 0}, allowed: [%{"balance" => 0}]},
      %Step{
        index: 1,
        action: "Withdraw",
        params: %{a: 1},
        outcome: :ok,
        projection: %{"balance" => -1},
        allowed: []
      }
    ]
  }

  @violation %{
    kind: :invariant,
    name: "Small",
    message: "Invariant Small is violated.",
    trace: [
      %{index: 1, action: nil, state: %{"x" => 0}},
      %{index: 2, action: "Next", state: %{"x" => 1}}
    ]
  }

  defp report(stages, status \\ :fail),
    do: %{
      status: status,
      lock: %{stage: :lock, status: :pass, payload: :ok},
      specs: [%{spec: "Bank", status: status, stages: stages}]
    }

  test "format and to_json do not raise for mistyped projection values (nil/atom/tuple)" do
    failure = %Failure{
      kind: :invalid_projection,
      seed: 7,
      steps: [
        %Step{
          index: 0,
          outcome: :ok,
          projection: %{"status" => nil},
          allowed: [%{"status" => "open"}]
        },
        %Step{
          index: 1,
          action: "Go",
          params: %{},
          outcome: :ok,
          projection: %{"status" => :pending, "extra" => {:a, :b}},
          candidates: [],
          allowed: []
        }
      ],
      details: %{variable: "status", value: :pending, message: "bad value"}
    }

    report = %{
      status: :fail,
      lock: nil,
      specs: [
        %{
          spec: "Bank",
          status: :fail,
          stages: [%{stage: :conformance, status: :fail, payload: {:error, failure}}]
        }
      ]
    }

    text = Report.format(report)
    assert text =~ "status = nil"
    assert text =~ "status = :pending"
    assert text =~ "extra = {:a, :b}"

    json = Report.to_json(report)
    encoded = JSON.encode!(json)
    assert is_binary(encoded)
    assert %{"specs" => [_]} = JSON.decode!(encoded)
  end

  test "format_state uses TLA+ syntax" do
    assert Report.format_state(%{"b" => Value.set([1]), "a" => "x"}) == ~S(a = "x", b = {1})
  end

  test "format_failure explains, tabulates steps, marks divergence and gives next commands" do
    text = Report.format_failure("Bank", @failure)
    assert text =~ "Conformance failure in Bank: action_not_enabled (seed 1234)"
    assert text =~ "should have returned {:rejected, reason, ctx}"
    assert text =~ "(init)"
    assert text =~ "Withdraw %{a: 1}"
    assert text =~ "balance = -1"
    assert text =~ "<-- diverges here"
    assert text =~ "Spec allowed: (no Withdraw transition is enabled here)"
    assert text =~ "mix outlaw.test Bank --seed 1234"
    assert text =~ "mix outlaw.graph Bank --trace failure"
  end

  test "format_violation shows the counterexample" do
    text = Report.format_violation("Inv", @violation)
    assert text =~ "TLC found a violation in Inv: Invariant Small is violated. (invariant)"
    assert text =~ "1. (initial)  x = 0"
    assert text =~ "2. Next  x = 1"
  end

  test "format summarises all stages" do
    text =
      report([
        %{
          stage: :check,
          status: :pass,
          payload: {:ok, %{distinct_states: 8, states_generated: 20}}
        },
        %{stage: :conformance, status: :fail, payload: {:error, @failure}}
      ])
      |> Report.format()

    assert text =~ "lock: pass"
    assert text =~ "Bank: FAIL"
    assert text =~ "check: pass (8 distinct states)"
    assert text =~ "conformance: fail"
    assert text =~ "<-- diverges here"
  end

  test "to_json is encodable and structured for LLMs" do
    json =
      report([
        %{stage: :check, status: :fail, payload: {:violation, @violation}},
        %{stage: :conformance, status: :skipped, payload: :skipped}
      ])
      |> Report.to_json()

    encoded = JSON.encode!(json)

    assert %{"status" => "fail", "lock" => %{"status" => "pass"}, "specs" => [spec]} =
             JSON.decode!(encoded)

    assert [
             %{"stage" => "check", "violation" => v},
             %{"stage" => "conformance", "status" => "skipped"}
           ] = spec["stages"]

    assert v["kind"] == "invariant"
    assert [%{"index" => 1, "action" => nil, "state" => %{"x" => "0"}}, _] = v["trace"]
  end

  test "to_json renders failures and errors" do
    json =
      report([
        %{
          stage: :check,
          status: :pass,
          payload: {:ok, %{distinct_states: 8, states_generated: 20}}
        },
        %{stage: :conformance, status: :fail, payload: {:error, @failure}}
      ])
      |> Report.to_json()
      |> JSON.encode!()
      |> JSON.decode!()

    [_, conf] = hd(json["specs"])["stages"]
    f = conf["failure"]
    assert f["kind"] == "action_not_enabled"
    assert f["seed"] == 1234
    assert f["failed_step"] == 1
    assert f["explanation"] =~ "rejected"

    assert [
             %{"action" => nil},
             %{
               "action" => "Withdraw",
               "params" => "%{a: 1}",
               "state" => %{"balance" => "-1"},
               "spec_allowed" => []
             }
           ] = f["steps"]

    err =
      Report.to_json(
        report([
          %{
            stage: :check,
            status: :error,
            payload: {:error, Error.new(:spec_error, "bad", %{location: %{line: 3}})}
          }
        ])
      )

    assert %{
             "error" => %{
               "kind" => "spec_error",
               "message" => "bad",
               "details" => %{"location" => %{"line" => 3}}
             }
           } =
             err
             |> JSON.encode!()
             |> JSON.decode!()
             |> Map.fetch!("specs")
             |> hd()
             |> Map.fetch!("stages")
             |> hd()
  end
end
